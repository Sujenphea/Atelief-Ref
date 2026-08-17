//
//  ShareMenuProbeTests.swift
//  AtelierRefsTests
//
//  011 · A3 — how long the `Share ▸` payload takes to resolve, measured rather
//  than guessed.
//
//  The concern (raised in review): `MasonryGridCoordinator.addOutFlowItems` resolves
//  the WHOLE share payload during menu construction, just to decide whether to add
//  the item. That means one `FileManager.fileExists` per selected asset plus an
//  N-item `NSSharingServicePicker`, synchronously, on a right-click — and 036 §4 /
//  038 §3.3 are precisely the documents about menu-construction cost.
//
//  The proposed fix was a lazy `menuNeedsUpdate` resolve, which is fiddly around a
//  system-built submenu. It was NOT taken, because `.change-log/383` exists to
//  record what happens when an obvious-looking optimization is measured: the
//  suspect there cost 1.1 ms and the real cost was elsewhere. So this measures
//  first. The threshold that would justify the refactor is one frame — ~16 ms — at
//  a selection size anyone plausibly right-clicks.
//
//  OPT-IN, like `VideoOpenProbeTests`: it creates thousands of real files and its
//  numbers are machine-specific, so it has no business in a normal run.
//
//      ATELIER_SHARE_PROBE=1 xcodebuild ... -only-testing:AtelierRefsTests/ShareMenuProbeTests
//

import AppKit
import AtelierArchive
import AtelierCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

@MainActor
@Suite(
    "Share menu payload probe",
    .enabled(if: ProcessInfo.processInfo.environment["ATELIER_SHARE_PROBE"] == "1")
)
struct ShareMenuProbeTests {

    /// One frame at 60 Hz — the bar a right-click has to clear to feel instant.
    private static let frameBudget = Duration.milliseconds(16)

    private func makeFixture(count: Int, in root: URL) -> [(asset: Asset, source: Source?)] {
        (0 ..< count).map { index in
            let url = root.appendingPathComponent("blob-\(index).png")
            FileManager.default.createFile(
                atPath: url.path, contents: Data(repeating: 0x41, count: 16))
            let sourceID = UUID()
            return (
                asset: Asset(
                    id: UUID(), kind: .image, blobHash: String(format: "%016x", index),
                    mimeType: "image/png", width: 100, height: 100, duration: nil,
                    fileSize: 16, downloadState: .downloaded, createdAt: Date(),
                    name: nil, sourceId: sourceID, payload: nil),
                source: Source(
                    id: sourceID, platform: .web, originalURL: "https://example.com/\(index)",
                    title: "Ref \(index)", capturedAt: Date())
            )
        }
    }

    @Test("Resolving the share payload stays inside a frame at realistic selections")
    func payloadResolutionCost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = ContinuousClock()
        var lines: [String] = [
            "selection   resolve(stat/asset)   items()    picker()    total"
        ]

        for count in [100, 1_000, 5_000] {
            let pairs = makeFixture(count: count, in: root)
            let blobURL: (Asset) -> URL? = { asset in
                guard let hash = asset.blobHash else { return nil }
                return root.appendingPathComponent("blob-\(Int(hash, radix: 16) ?? 0).png")
            }

            // 1 — the N-stat pass, the part the review flagged.
            var selection = ExportSelection(entries: [], skipped: 0)
            let resolve = clock.measure {
                selection = AssetExport.exportSelection(assets: pairs, blobURL: blobURL)
            }
            #expect(selection.entries.count == count)

            // 2 — mapping entries to the AppKit payload.
            var payload: [Any] = []
            let items = clock.measure { payload = AssetShare.items(for: selection) }

            // 3 — the picker, which asks the system to enumerate services for N items.
            let picker = clock.measure { _ = AssetShare.picker(for: selection) }

            let total = resolve + items + picker
            let row = String(
                format: "%7d   %17.2f ms   %6.2f ms   %6.2f ms   %6.2f ms",
                count, resolve.ms, items.ms, picker.ms, total.ms)
            lines.append(row)
            // Recorded, not printed: this target is sandboxed (no writing to an
            // arbitrary path) and `xcodebuild` swallows stdout, so the xcresult is
            // the only place a number reliably survives.
            Issue.record(Comment(rawValue: "[share-probe] \(row)"))

            #expect(payload.count == count)

            // 4 — what the MENU actually pays now: the cheap predicate, which stops
            // at the first shareable ref. This is the number that has to stay under
            // a frame; `resolve` above is now paid on the click instead.
            var shareable = false
            let cheap = clock.measure {
                shareable = pairs.contains { AssetShare.canShare($0.asset) }
            }
            #expect(shareable)
            Issue.record(Comment(rawValue: String(
                format: "[share-cheap] n=%d  canShareAny %.4f ms  (was %.2f ms)",
                count, cheap.ms, total.ms)))

            // The verdict, on the path a right-click takes.
            let message: Comment = """
                the menu's cheap predicate took \(cheap.ms) ms for \(count) refs — \
                over one frame; something in `AssetShare.canShare` is touching disk
                """
            #expect(cheap < Self.frameBudget, message)
        }

        // The table IS the deliverable, so it is written where it can be read back:
        // `xcodebuild` swallows a test's stdout, and the numbers go in the changelog.
        let table = lines.joined(separator: "\n")
        if let out = ProcessInfo.processInfo.environment["ATELIER_SHARE_PROBE_OUT"] {
            try? Data(table.utf8).write(to: URL(fileURLWithPath: out))
        }
        print("\n[share-probe]\n" + table + "\n")
    }

    /// WHERE the per-asset cost goes. `exportItem` does four things per asset, and
    /// at ~66 µs each the total is far above what a `stat` costs — so this splits it
    /// before anyone optimizes the wrong one.
    @Test("The per-asset resolve cost is attributed to a specific call")
    func perAssetCostAttribution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-probe-parts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let count = 1_000
        let pairs = makeFixture(count: count, in: root)
        let urls = (0 ..< count).map { root.appendingPathComponent("blob-\($0).png") }
        let clock = ContinuousClock()

        let building = clock.measure {
            for index in 0 ..< count {
                _ = root.appendingPathComponent("blob-\(index).png")
            }
        }
        let stating = clock.measure {
            for url in urls { _ = FileManager.default.fileExists(atPath: url.path) }
        }
        let typing = clock.measure {
            for url in urls { _ = UTType(filenameExtension: url.pathExtension) }
        }
        let naming = clock.measure {
            for pair in pairs {
                _ = AssetExport.filename(
                    base: AssetExport.baseName(
                        title: pair.source?.title, authorHandle: nil,
                        sourceURL: pair.source?.originalURL),
                    blobHash: pair.asset.blobHash ?? "", ext: "png")
            }
        }

        Issue.record(Comment(rawValue: String(
            format: "[share-parts n=%d] urlBuild %.2f ms · fileExists %.2f ms · "
                + "UTType %.2f ms · naming %.2f ms",
            count, building.ms, stating.ms, typing.ms, naming.ms)))
    }
}

private extension Duration {
    /// Milliseconds as a `Double`, for printing and comparing.
    var ms: Double {
        let parts = components
        return Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
