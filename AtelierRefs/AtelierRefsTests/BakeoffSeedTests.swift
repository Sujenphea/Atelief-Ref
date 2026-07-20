//
//  BakeoffSeedTests.swift
//  AtelierRefsTests
//
//  A reproducible seeder for the grid-performance bake-off: N real JPEGs with
//  varied aspect ratios, ingested through the PRODUCTION pipeline
//  (`IngestPipeline` / `IngestCoordinator`) so blobs, all three thumbnail tiers,
//  and the asset rows are byte-identical to what a real capture produces.
//
//  This is NOT part of the normal suite run. It is `.enabled(if:)` on
//  `ATELIER_SEED_BAKEOFF` being set, so `xcodebuild test` skips it.
//
//  Two hard safety rails, because this writes a lot of data:
//    1. it REFUSES to run unless the library-root override is set — seeding can
//       never land in the user's real `<Application Support>/ref-atelier/`;
//    2. the images are generated from a SEEDED RNG, so a given (N, seed) always
//       produces the same library — reproducible across bake-off runs.
//
//  Invocation (from the repo root). Two details are load-bearing:
//    • the `TEST_RUNNER_` prefix — xcodebuild does NOT forward the shell
//      environment to the test host, so a bare `ATELIER_…=` is silently ignored
//      and the test just skips;
//    • `-parallel-testing-enabled NO` — xcodebuild otherwise spawns two runner
//      PROCESSES that both seed the same SQLite library and race (observed: one
//      item lost to write contention). Swift Testing's `.serialized` cannot help
//      here, as the contention is cross-process.
//
//      TEST_RUNNER_ATELIER_LIBRARY_ROOT=bakeoff-library \
//      TEST_RUNNER_ATELIER_SEED_BAKEOFF=2000 \
//      xcodebuild test -project AtelierRefs/AtelierRefs.xcodeproj \
//        -scheme AtelierRefs -destination 'platform=macOS' \
//        -only-testing:AtelierRefsTests/BakeoffSeedTests \
//        -parallel-testing-enabled NO
//
//  Re-running tops up the SAME Bakeoff collection. Because the RNG is seeded,
//  a re-run regenerates identical bytes, which the pipeline correctly dedups —
//  so delete the library root first for a clean, full-size seed.
//
//  Then launch the app against the same throwaway library:
//
//      AtelierRefs.app/Contents/MacOS/AtelierRefs -library-root bakeoff-library
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AtelierRefs

/// Set to the desired item count to enable the seeder, e.g. `ATELIER_SEED_BAKEOFF=2000`.
private let seedCountKey = "ATELIER_SEED_BAKEOFF"

/// The requested item count, or `nil` when the seeder is not enabled.
private var requestedSeedCount: Int? {
    ProcessInfo.processInfo.environment[seedCountKey].flatMap(Int.init).map { max(0, $0) }
}

@Suite("Bake-off library seeder (manual)")
struct BakeoffSeedTests {

    /// The collection every seeded asset lands in.
    static let collectionName = "Bakeoff"

    @Test(
        "seed N real JPEGs into the Bakeoff collection",
        .enabled(if: requestedSeedCount != nil, "set \(seedCountKey)=<N> to run"),
        .timeLimit(.minutes(60)))
    func seedBakeoffLibrary() async throws {
        let count = try #require(requestedSeedCount)

        // RAIL 1 — never touch the real library. The override must be explicit.
        let override = try #require(
            LibraryLocation.overrideValue(),
            """
            Refusing to seed: no library-root override. Re-run with \
            ATELIER_LIBRARY_ROOT=<name> (a directory name under Application \
            Support) so seeding lands in a throwaway library, never the user's.
            """)

        let root = try LibraryLocation.resolvedRoot()
        #expect(root.lastPathComponent != "ref-atelier", "override must not resolve to the real library")

        let layout = LibraryLayout(root: root)
        let store = MediaStore(layout: layout)
        let services = try AppServices(
            databasePath: layout.root.appendingPathComponent("library.sqlite").path)
        let pipeline = IngestPipeline(store: store, services: services)
        let coordinator = IngestCoordinator(pipeline: pipeline)

        print("[seed] library root: \(root.path)  (override: \(override))")
        print("[seed] seeding \(count) images…")

        // Reuse the Bakeoff collection across runs so re-seeding tops up rather
        // than accumulating duplicate collections.
        let existing = try await services.listCollections().first { $0.name == Self.collectionName }
        let collection: Collection
        if let existing {
            collection = existing
        } else {
            collection = try await services.createCollection(name: Self.collectionName)
        }

        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        var generator = SplitMix64(seed: 0xBA1E_0FF0)

        let started = Date()
        var ingested = 0
        var deduplicated = 0
        var failed = 0
        var totalBytes = 0

        // Generate + ingest in chunks so peak memory stays bounded: a 3000×2000
        // RGBA canvas is ~24 MB while drawing, and we only hold one chunk of
        // encoded JPEGs at a time.
        let chunkSize = 25
        var index = 0
        while index < count {
            let upper = min(index + chunkSize, count)
            var inputs: [IngestInput] = []
            inputs.reserveCapacity(upper - index)

            for i in index..<upper {
                let data = try Self.makeJPEG(index: i, using: &generator)
                totalBytes += data.count
                inputs.append(IngestInput(
                    source: .data(data),
                    provenance: source,
                    collectionID: collection.id))
            }

            let outcomes = await coordinator.ingest(inputs)
            for outcome in outcomes {
                switch outcome {
                case .ingested(_, let wasDeduplicated):
                    ingested += 1
                    if wasDeduplicated { deduplicated += 1 }
                case .failed(let error):
                    failed += 1
                    if failed <= 5 { print("[seed] FAILED: \(error)") }
                case .cancelled:
                    failed += 1
                }
            }

            index = upper
            let elapsed = Date().timeIntervalSince(started)
            let rate = Double(index) / max(elapsed, 0.001)
            let remaining = Double(count - index) / max(rate, 0.001)
            print(String(
                format: "[seed] %d/%d  %.1f img/s  elapsed %.0fs  eta %.0fs",
                index, count, rate, elapsed, remaining))
        }

        let elapsed = Date().timeIntervalSince(started)

        // Report real, measured evidence rather than assumptions.
        let members = try await services.collectionItems(in: collection.id)
        let blobCount = store.enumerateBlobFiles().count
        let onDisk = Self.directorySize(layout.root)

        print("""

            [seed] ── done ─────────────────────────────────────────────
            [seed] root            \(root.path)
            [seed] collection      \(Self.collectionName) (\(collection.id))
            [seed] requested       \(count)
            [seed] ingested        \(ingested)  (deduplicated: \(deduplicated))
            [seed] failed          \(failed)
            [seed] collection rows \(members.count)
            [seed] blobs on disk   \(blobCount)
            [seed] source JPEG     \(Self.mb(totalBytes)) MB generated
            [seed] library on disk \(Self.mb(onDisk)) MB
            [seed] wall clock      \(String(format: "%.1f", elapsed))s \
            (\(String(format: "%.1f", Double(count) / max(elapsed, 0.001))) img/s)
            [seed] ────────────────────────────────────────────────────

            """)

        #expect(failed == 0, "no item should fail to ingest")
        #expect(deduplicated == 0, "generated images must be visually distinct — none should dedup")
        #expect(members.count >= count, "every seeded image should be a member of \(Self.collectionName)")

        // Every asset must carry all three tiers, or the bake-off would measure
        // thumbnail GENERATION instead of thumbnail DECODE.
        var missingTiers = 0
        for item in members.prefix(count) {
            guard case .image(let hash) = item.asset.content else {
                missingTiers += 1
                continue
            }
            for tier in ThumbnailTier.allCases
            where !store.hasThumbnail(hash: hash, size: tier.rawValue, fileExtension: "jpg") {
                missingTiers += 1
            }
        }
        #expect(missingTiers == 0, "every asset needs all \(ThumbnailTier.allCases.count) tiers")
    }

    // MARK: - Image generation

    /// The dimension pool — portrait / landscape / square across ~800×600 to
    /// ~3000×2000, so the masonry layout sees real aspect-ratio variety.
    private static let dimensions: [(w: Int, h: Int)] = [
        (800, 600), (1024, 768), (1600, 1200), (2048, 1536), (3000, 2000),  // landscape
        (600, 800), (768, 1024), (1200, 1600), (1536, 2048), (1400, 2100),  // portrait
        (900, 900), (1200, 1200), (2000, 2000),                             // square
        (2400, 1000), (1000, 2400),                                         // extreme
    ]

    /// One visually distinct JPEG: a hue-rotated gradient plus random shapes and
    /// per-pixel noise, so neither content hashing nor perceptual hashing can
    /// collapse two of them into a single asset.
    static func makeJPEG(index: Int, using generator: inout SplitMix64) throws -> Data {
        let size = dimensions[index % dimensions.count]
        let width = size.w
        let height = size.h

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SeedError.contextFailed(width: width, height: height) }

        // A hue that walks the wheel by a non-repeating step, so adjacent items
        // never share a base colour.
        let baseHue = (Double(index) * 0.137).truncatingRemainder(dividingBy: 1.0)

        // Background: a two-stop linear gradient across complementary hues.
        let start = rgb(hue: baseHue, saturation: 0.65, brightness: 0.85)
        let end = rgb(hue: (baseHue + 0.35).truncatingRemainder(dividingBy: 1.0),
                      saturation: 0.75, brightness: 0.45)
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(red: start.r, green: start.g, blue: start.b, alpha: 1),
                CGColor(red: end.r, green: end.g, blue: end.b, alpha: 1),
            ] as CFArray,
            locations: [0, 1])
        {
            context.drawLinearGradient(
                gradient,
                start: .zero, end: CGPoint(x: width, y: height),
                options: [])
        }

        // Random shapes — 12…24 translucent circles and rectangles.
        let shapeCount = 12 + Int(generator.next() % 13)
        for _ in 0..<shapeCount {
            let hue = Double(generator.next() % 1000) / 1000.0
            let c = rgb(hue: hue, saturation: 0.8, brightness: 0.9)
            context.setFillColor(
                CGColor(red: c.r, green: c.g, blue: c.b, alpha: 0.15 + Double(generator.next() % 40) / 100.0))
            let w = Double(generator.next() % UInt64(width / 2)) + 20
            let h = Double(generator.next() % UInt64(height / 2)) + 20
            let x = Double(generator.next() % UInt64(width))
            let y = Double(generator.next() % UInt64(height))
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if generator.next() % 2 == 0 {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        }

        // Coarse noise blocks — defeats perceptual hashing collapsing similar
        // gradients, and makes the JPEG a realistic size rather than trivially
        // compressible.
        let block = 16
        for by in stride(from: 0, to: height, by: block) {
            for bx in stride(from: 0, to: width, by: block) {
                guard generator.next() % 3 == 0 else { continue }
                let v = Double(generator.next() % 100) / 100.0
                context.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 0.12))
                context.fill(CGRect(x: bx, y: by, width: block, height: block))
            }
        }

        guard let image = context.makeImage() else {
            throw SeedError.imageFailed(index: index)
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw SeedError.destinationFailed(index: index) }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.7,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SeedError.encodeFailed(index: index)
        }
        return output as Data
    }

    /// HSB → RGB, so a hue sweep produces evenly distributed, saturated colours
    /// without pulling in AppKit.
    private static func rgb(
        hue: Double, saturation: Double, brightness: Double
    ) -> (r: Double, g: Double, b: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1.0) + 1.0)
            .truncatingRemainder(dividingBy: 1.0) * 6.0
        let i = Int(h)
        let f = h - Double(i)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch i % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }

    // MARK: - Reporting helpers

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    /// Total bytes under `url`, for the on-disk evidence line.
    private static func directorySize(_ url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: keys)
            total += values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
        }
        return total
    }

    enum SeedError: Error {
        case contextFailed(width: Int, height: Int)
        case imageFailed(index: Int)
        case destinationFailed(index: Int)
        case encodeFailed(index: Int)
    }
}

/// A tiny deterministic PRNG (SplitMix64) so a given seed reproduces the exact
/// same library — `SystemRandomNumberGenerator` would make each run different.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
