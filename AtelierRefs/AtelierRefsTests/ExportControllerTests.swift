//
//  ExportControllerTests.swift
//  AtelierRefsTests
//
//  The window's export orchestrator, driven against real temp directories. Four
//  entry points shared this controller with no tests at all, which was fine while
//  each was a copy of the last and became untenable the moment the copies were to
//  be collapsed — so these cover the INVARIANTS a refactor must preserve rather
//  than the shape of any one export:
//
//   • a cancelled run reports `.cancelled`, NEVER `.failed` (301) — the rule that
//     stops "you pressed Stop" from being shown as "your export broke";
//   • the destination folder is removed only when THIS run created it;
//   • `reportSeq` strictly increments, so two identical back-to-back reports still
//     trip the toast's `.onChange`;
//   • an empty plan is refused before any panel or filesystem work.
//
//  The panel is skipped by calling `startSite` / `startAssets` directly (both take
//  an explicit destination); `requestAssetExport`'s empty guard runs BEFORE it
//  raises a panel, so that path is driven through the public API. `settle` polls
//  `isExporting`, the `BackupControllerTests` house pattern — the controller's
//  `task` stays private.
//

import AtelierCore
import AtelierExport
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("ExportController")
struct ExportControllerTests {

    // MARK: - Rig

    private struct Rig {
        let controller: ExportController
        /// Where source "blobs" live.
        let sources: URL
        /// The parent the export destination is created inside.
        let root: URL

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// A destination that does NOT exist yet — the normal case, and the one the
        /// cleanup rule is about.
        func freshDestination(_ name: String = "out") -> URL {
            root.appendingPathComponent(name, isDirectory: true)
        }
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        return Rig(controller: ExportController(), sources: sources, root: root)
    }

    /// A real source file, so the writer's existence check passes.
    @discardableResult
    private func makeBlob(_ rig: Rig, _ name: String, bytes: Int = 8) -> URL {
        let url = rig.sources.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: url.path, contents: Data(repeating: 0x41, count: bytes))
        return url
    }

    private func assetPlan(_ files: [ExportFile], skipped: Int = 0) -> AssetFolderExport.Plan {
        AssetFolderExport.Plan(files: files, skipped: skipped)
    }

    private func sitePlan(_ files: [ExportFile], skipped: Int = 0) -> CollectionSiteExport.Plan {
        CollectionSiteExport.Plan(
            gallery: SiteGallery(
                title: "Refs",
                items: files.map {
                    SiteItem(media: .image(file: $0.filename, pixelWidth: 2, pixelHeight: 1))
                }),
            assets: files,
            skipped: skipped)
    }

    /// Wait for the run to settle — the `BackupControllerTests` poll, not a fixed
    /// sleep, so a fast machine does not wait and a slow one does not flake.
    private func settle(_ controller: ExportController) async throws {
        for _ in 0 ..< 400 where controller.isExporting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isExporting)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Empty plan (refused before any panel or write)

    @Test("An empty originals plan is refused, and reports its mapping skips")
    func emptyAssetPlanRefused() throws {
        let rig = try makeRig()
        defer { rig.cleanup() }

        // Through the PUBLIC entry point: the empty guard runs before the panel,
        // so no UI is involved.
        rig.controller.requestAssetExport(plan: assetPlan([], skipped: 3), suggestedName: "Refs")

        let report = try #require(rig.controller.lastReport)
        #expect(report.outcome == .failed("Nothing to export"))
        // The refusal still tells the truth about what could not be exported, and
        // says WHY — these were byte-less refs, not files that failed to write.
        #expect(report.skipped.notExportable == 3)
        #expect(report.skipped.total == 3)
        #expect(report.skipped.writeFailed == 0)
        #expect(!rig.controller.isExporting)
    }

    // MARK: - A clean run

    @Test("A clean originals run reports success, full progress, and the destination")
    func cleanAssetRun() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let a = makeBlob(rig, "a")
        let b = makeBlob(rig, "b")
        let out = rig.freshDestination()

        rig.controller.startAssets(
            plan: assetPlan([
                ExportFile(source: a, filename: "a.png"),
                ExportFile(source: b, filename: "b.png"),
            ]),
            to: out)
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.outcome == .success)
        #expect(report.url == out)
        #expect(report.skipped.isEmpty)
        #expect(rig.controller.progress == 1)
        #expect(exists(out.appendingPathComponent("a.png")))
        #expect(exists(out.appendingPathComponent("b.png")))
    }

    // MARK: - Partial success is not success (.incomplete)

    @Test("Mapping skips and write skips land in their own buckets, summed by total")
    func skipsAreBucketed() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let present = makeBlob(rig, "present")
        let out = rig.freshDestination()

        // 2 mapping skips (byte-less refs) + 1 write skip (source reaped).
        rig.controller.startAssets(
            plan: assetPlan([
                ExportFile(source: present, filename: "here.png"),
                ExportFile(source: rig.sources.appendingPathComponent("gone"),
                           filename: "gone.png"),
            ], skipped: 2),
            to: out)
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.skipped.notExportable == 2)
        #expect(report.skipped.missingSource == 1)
        #expect(report.skipped.writeFailed == 0)
        #expect(report.skipped.total == 3)
    }

    @Test("A run that left anything out reports .incomplete, never .success")
    func partialRunIsIncomplete() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let present = makeBlob(rig, "present")
        let out = rig.freshDestination()

        rig.controller.startAssets(
            plan: assetPlan([
                ExportFile(source: present, filename: "here.png"),
                ExportFile(source: rig.sources.appendingPathComponent("gone"),
                           filename: "gone.png"),
            ]),
            to: out)
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        // 37-of-40 files in Finder look complete; the report must not agree.
        #expect(report.outcome == .incomplete)
        #expect(report.didWrite)          // it DID write — the checkmark is earned
        #expect(report.url == out)
        #expect(rig.controller.progress == 1)
    }

    @Test("Mapping skips alone are enough to make a run incomplete")
    func mappingSkipsAloneAreIncomplete() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let a = makeBlob(rig, "a")

        rig.controller.startAssets(
            plan: assetPlan([ExportFile(source: a, filename: "a.png")], skipped: 1),
            to: rig.freshDestination())
        try await settle(rig.controller)

        #expect(try #require(rig.controller.lastReport).outcome == .incomplete)
    }

    @Test("An unsafe name is reported in its own bucket, not as a missing file")
    func unsafeNameHasItsOwnBucket() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let a = makeBlob(rig, "a")
        let out = rig.freshDestination()

        rig.controller.startAssets(
            plan: assetPlan([
                ExportFile(source: a, filename: "a.png"),
                ExportFile(source: a, filename: "../escape.png"),
            ]),
            to: out)
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.skipped.unsafeName == 1)
        #expect(report.skipped.missingSource == 0)
        #expect(report.outcome == .incomplete)
    }

    @Test("A fully clean run is .success with an empty breakdown")
    func cleanRunHasEmptyBreakdown() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let a = makeBlob(rig, "a")

        rig.controller.startAssets(
            plan: assetPlan([ExportFile(source: a, filename: "a.png")]),
            to: rig.freshDestination())
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.outcome == .success)
        #expect(report.skipped.isEmpty)
    }

    @Test("A clean site run reports success and writes index.html")
    func cleanSiteRun() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let a = makeBlob(rig, "a")
        let out = rig.freshDestination()

        rig.controller.startSite(
            plan: sitePlan([ExportFile(source: a, filename: "a.png")]), to: out)
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.outcome == .success)
        #expect(exists(out.appendingPathComponent("index.html")))
        #expect(exists(out.appendingPathComponent("assets/a.png")))
    }

    // MARK: - Cancellation (301: ask the flag, never the error)

    @Test("A cancelled originals run reports .cancelled, never .failed")
    func cancelledAssetRunIsNotAFailure() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")
        let out = rig.freshDestination()

        // Enough files that the cancel lands mid-run rather than after it.
        rig.controller.startAssets(
            plan: assetPlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: out)
        rig.controller.cancel()
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.outcome == .cancelled)
        // The distinction this test exists for: work in flight throws on the way
        // out of a cancel, and that throw must not surface as a failure.
        if case .failed = report.outcome { Issue.record("a cancel was reported as a failure") }
        #expect(report.url == nil)
    }

    @Test("A cancelled site run reports .cancelled, never .failed")
    func cancelledSiteRunIsNotAFailure() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")
        let out = rig.freshDestination()

        rig.controller.startSite(
            plan: sitePlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: out)
        rig.controller.cancel()
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.outcome == .cancelled)
    }

    // MARK: - Destination cleanup (only what this run created)

    @Test("A cancelled run removes a destination folder IT created")
    func cancelRemovesOwnFolder() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")
        let out = rig.freshDestination()
        #expect(!exists(out))

        rig.controller.startAssets(
            plan: assetPlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: out)
        rig.controller.cancel()
        try await settle(rig.controller)

        #expect(!exists(out))
    }

    @Test("A cancelled run leaves a PRE-EXISTING destination folder alone")
    func cancelKeepsPreexistingFolder() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")
        let out = rig.freshDestination()
        // The user's own folder, with the user's own file in it.
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bystander = out.appendingPathComponent("my-taxes.pdf")
        FileManager.default.createFile(atPath: bystander.path, contents: Data([9]))

        rig.controller.startAssets(
            plan: assetPlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: out)
        rig.controller.cancel()
        try await settle(rig.controller)

        // A cancelled export must never delete a folder the user already had.
        #expect(exists(out))
        #expect(exists(bystander))
    }

    // MARK: - Report sequencing

    @Test("reportSeq strictly increments, so identical reports still trip .onChange")
    func reportSeqIncrements() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let a = makeBlob(rig, "a")

        var seqs: [Int] = []
        for run in 0 ..< 3 {
            rig.controller.startAssets(
                plan: assetPlan([ExportFile(source: a, filename: "a.png")]),
                to: rig.freshDestination("out-\(run)"))
            try await settle(rig.controller)
            seqs.append(try #require(rig.controller.lastReport).seq)
        }

        #expect(seqs == [1, 2, 3])
        #expect(zip(seqs, seqs.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("Two identical back-to-back reports differ only by seq")
    func identicalReportsStillDiffer() throws {
        let rig = try makeRig()
        defer { rig.cleanup() }

        rig.controller.requestAssetExport(plan: assetPlan([]), suggestedName: "Refs")
        let first = try #require(rig.controller.lastReport)
        rig.controller.requestAssetExport(plan: assetPlan([]), suggestedName: "Refs")
        let second = try #require(rig.controller.lastReport)

        #expect(first.outcome == second.outcome)
        #expect(first != second)        // the whole point of the monotonic stamp
        #expect(second.seq == first.seq + 1)
    }

    // MARK: - Running state

    // MARK: - Concurrent requests are declined OUT LOUD

    @Test("A second request mid-run is refused with a report, not silently dropped")
    func concurrentRequestIsReported() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")

        rig.controller.startAssets(
            plan: assetPlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: rig.freshDestination("first"))
        #expect(rig.controller.isExporting)

        let a = makeBlob(rig, "second")
        rig.controller.requestAssetExport(
            plan: assetPlan([ExportFile(source: a, filename: "a.png")]),
            suggestedName: "Refs")

        // The refusal is VISIBLE — the File-menu and context-menu paths cannot grey
        // themselves out, so they used to click and do nothing at all.
        let refusal = try #require(rig.controller.lastReport)
        #expect(refusal.outcome == .failed("An export is already running"))

        try await settle(rig.controller)
    }

    @Test("Refusing a second request does NOT orphan the run already in flight")
    func refusalDoesNotTearDownTheRunningExport() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")
        let out = rig.freshDestination("first")

        rig.controller.startAssets(
            plan: assetPlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: out)

        rig.controller.requestAssetExport(plan: assetPlan([]), suggestedName: "Refs")

        // The subtle half: reporting the refusal must not reset `isExporting` /
        // `cancelFlag` / `task`, or the ring would stop, Stop would no longer
        // cancel, and the real export would finish invisibly.
        #expect(rig.controller.isExporting)
        try await settle(rig.controller)

        // ...and the first run still completed and still reported its own outcome.
        let final = try #require(rig.controller.lastReport)
        #expect(final.didWrite)
        #expect(final.url == out)
        #expect(exists(out.appendingPathComponent("f-0.png")))
    }

    @Test("An empty plan mid-run is refused for being concurrent, not for being empty")
    func busyBeatsEmpty() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")

        rig.controller.startAssets(
            plan: assetPlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: rig.freshDestination())
        rig.controller.requestAssetExport(plan: assetPlan([]), suggestedName: "Refs")

        #expect(try #require(rig.controller.lastReport).outcome
            == .failed("An export is already running"))
        try await settle(rig.controller)
    }

    // MARK: - Progress coalescing

    @Test("Progress still reaches exactly 1 with coalescing on")
    func progressReachesOneWhenCoalesced() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")

        // 400 files ⇒ ~1/400 per tick, far below the 1% publish threshold, so most
        // ticks are dropped. The ring must still land on full.
        rig.controller.startAssets(
            plan: assetPlan((0 ..< 400).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: rig.freshDestination())
        try await settle(rig.controller)

        #expect(rig.controller.progress == 1)
    }

    @Test("The gate lets the first tick through, then ~1% steps, then always 1")
    func progressGateThresholds() {
        let gate = ProgressGate()

        // The FIRST tick always publishes, however small — the ring should start
        // moving as soon as there is anything to show.
        #expect(gate.shouldPublish(0.005))
        #expect(gate.shouldPublish(0.009) == false)   // +0.004, invisible
        #expect(gate.shouldPublish(0.02))             // +0.015, a visible step
        #expect(gate.shouldPublish(0.025) == false)   // +0.005, invisible again
        #expect(gate.shouldPublish(0.9))
        #expect(gate.shouldPublish(1))                // completion always lands
        #expect(gate.shouldPublish(1))                // ...even repeated
    }

    @Test("A 5,000-file export publishes ~1% of the progress updates, not all of them")
    func progressIsCoalescedNotFlooded() {
        let gate = ProgressGate()
        let total = 5_000
        let published = (1 ... total).filter {
            gate.shouldPublish(Double($0) / Double(total))
        }.count

        // The point of the gate: a ring with ~100 distinguishable states should not
        // cost 5,000 Task hops and 5,000 SwiftUI invalidations. Bounded loosely on
        // purpose — the exact count depends on where the first tick lands, and
        // pinning it would make this a test about floating-point, not about flooding.
        #expect(published >= 95)
        #expect(published <= 105)
        #expect(published < total / 40)
    }

    @Test("isExporting is false before, true during, and false after a run")
    func isExportingLifecycle() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let source = makeBlob(rig, "blob")

        #expect(!rig.controller.isExporting)
        rig.controller.startAssets(
            plan: assetPlan((0 ..< 200).map {
                ExportFile(source: source, filename: "f-\($0).png")
            }),
            to: rig.freshDestination())
        #expect(rig.controller.isExporting)
        try await settle(rig.controller)
        #expect(!rig.controller.isExporting)
    }
}
