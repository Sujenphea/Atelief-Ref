//
//  InboxDrainExportIntegrationTests.swift
//  AtelierRefsTests
//
//  098 · finding 11 — the exclusion, against the real thing on both sides.
//
//  `InboxDrainPolicy` decides that an export takes the phone's inbox to itself: it waits
//  out a drain pass, holds the inbox for the duration, and lets a deferred activation
//  through afterwards. `InboxDrainPolicyTests` proves that rule 39 times, and every one of
//  those runs it over `Outcome == Int` with an export body that appends a string. Both
//  stand-ins are deliberate — the policy is generic over what a pass returns precisely so
//  `AtelierBrowse` never names `DrainSummary` — and together they mean the rule has never
//  once been run over what it is FOR:
//
//  > a real `.retainForExport` drain moving records out of the inbox top level while a real
//  > `InboxArchive.write` resolves each record's payload from whichever of the two sites it
//  > is in.
//
//  That is the failure the exclusion exists to prevent, and it needs a host that links
//  `AtelierBrowse` (the policy), `AtelierIngestion` (the drain) and `AtelierArchive` (the
//  export) at once. The packages cannot see each other by design — the phone app can, and
//  has no unit-test bundle; the Mac's test bundle is the only place in the program where
//  all three are on one link line. So the phone's integration test lives on the Mac, and
//  nothing in this file is a Mac behaviour.
//
//  **Nothing here waits on a schedule.** The pass is held mid-flight by the pipeline's own
//  `timing` sink — called once per successful byte ingest, from inside the ingest — which
//  opens a ``Gate`` the test parks on. So "the export was requested while a pass was
//  running" is a fact this file establishes rather than a race it hopes for, and there is
//  no `Task.sleep` anywhere in it. Every assertion afterwards is an invariant over the
//  inbox and the archive, not an ordering: they are the assertions that hold no matter how
//  the two interleave, which is the only kind worth making about a concurrency rule.
//

import AtelierArchive
import AtelierBrowse
import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore
import AtelierIngestion
import AtelierLibraryPaths
import Foundation
import Synchronization
import Testing

@testable import AtelierRefs

// MARK: - Rig

/// A count bumped from off the main actor and read back on it.
///
/// A class around a `Mutex` rather than the `Mutex` itself, because `Mutex` is
/// non-copyable and a `@Sendable` closure cannot capture one. `nonisolated` because the
/// pipeline's `timing` sink runs wherever the ingest is, which is not the main actor.
private nonisolated final class IngestCounter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// A phone: an inbox, a library, a retaining drain at width 2, and the policy that decides
/// when either of them may touch the inbox.
///
/// Everything is the shipped type. The only thing this rig adds is the `timing` sink, which
/// is a production seam `IngestPipeline` already has and the drain's own suite already uses
/// for the same purpose.
@MainActor
private final class PhoneRig {
    let base: URL
    let root: URL
    let layout: InboxLayout
    let writer: InboxWriter
    let services: AppServices
    let store: MediaStore
    let drain: InboxDrain
    private(set) var policy: InboxDrainPolicy<DrainSummary>!

    /// Opened by the pipeline the first time a capture's bytes are ingested — so a test
    /// that has awaited it knows a pass is genuinely in the middle of moving records.
    let firstIngest = Gate()

    /// How many byte ingests the pipeline has reported, across every pass. Bumped from
    /// off the main actor by the sink; read back on it once everything has settled.
    private let ingests = IngestCounter()
    var ingestCount: Int { ingests.value }

    /// Every summary the policy reported, in order. One per completed pass.
    private(set) var summaries: [DrainSummary] = []
    /// Every activation that did not become a pass.
    private(set) var events: [InboxDrainEvent] = []

    static func make(width: Int) throws -> PhoneRig { try PhoneRig(width: width) }

    private init(width: Int) throws {
        base = try InboxFixtures.temporaryLibraryRoot(suite: "InboxDrainExportIntegration")
        root = base.appendingPathComponent("phone", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        layout = InboxLayout(libraryRoot: root)
        writer = InboxWriter(layout: layout)
        services = try AppServices(
            databasePath: root.appendingPathComponent("library.sqlite").path)
        store = MediaStore(root: root)

        let gate = firstIngest
        let counter = ingests
        let pipeline = IngestPipeline(
            store: store,
            services: services,
            // The phone's two tiers (454), so this rig decodes what the phone decodes.
            tiers: [.medium, .large],
            timing: { _ in
                counter.bump()
                gate.open()
            })
        drain = InboxDrain(
            libraryRoot: root,
            // Width 2 — `MobileIngest.maxConcurrent`, and the width the drain chunks at,
            // so the pass under test has the head-of-line shape the phone's does.
            coordinator: IngestCoordinator(pipeline: pipeline, maxConcurrent: width),
            // The whole point: the record survives the ingest so the export can still
            // send it, which is what puts two writers on one directory.
            retention: .retainForExport)

        policy = InboxDrainPolicy(
            pass: { [drain] in await drain.drainOnce() },
            report: { [weak self] summary in self?.summaries.append(summary) },
            observe: { [weak self] event in self?.events.append(event) })
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    // MARK: The inbox

    /// One share, written by the real `InboxWriter` exactly as the share extension writes
    /// it. Distinct bytes per index, so 18A dedup cannot collapse two of them into one
    /// asset and quietly make this a test of 12 captures.
    @discardableResult
    func share(_ index: Int) throws -> InboxRecord {
        try writer.write(
            CaptureRequest(
                provenance: ProvenanceDTO(
                    platform: "web",
                    originalURL: "https://example.com/capture/\(index)",
                    authorName: "A Designer",
                    title: "Capture \(index)")),
            payload: try FixtureImages.solidImage(
                width: 24 + index, height: 16 + index, format: .jpeg),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
    }

    func pendingCount() throws -> Int { try layout.pendingRecordURLs().count }
    func ingestedCount() throws -> Int { try layout.ingestedRecordURLs().count }

    // MARK: The export, exactly as the phone runs it

    /// `CaptureExportController`'s two calls, and nothing else: read what is pending
    /// across BOTH sites, and write it. The Caches directory and the folder name are the
    /// app's; what crosses the wire is these.
    func exportNow(named name: String) throws -> (root: URL, summary: InboxArchive.Summary) {
        let target = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let pending = try InboxArchive.pendingRecords(in: layout)
        let summary = try InboxArchive.write(
            records: pending, layout: layout, to: target,
            appVersion: "1.0-test",
            exportedAt: Date(timeIntervalSince1970: 1_700_010_000))
        return (target, summary)
    }

    /// Every membership entry in a written archive's manifest.
    func manifestItems(in archive: URL) throws -> [ArchiveManifest.MembershipEntry] {
        let manifest = try ArchiveManifest.makeDecoder().decode(
            ArchiveManifest.self,
            from: Data(contentsOf: archive.appendingPathComponent(
                ArchiveLayout.manifestFilename)))
        return manifest.collections.flatMap(\.items)
    }

    /// Wait out whatever the policy currently holds, including the report that follows it.
    func settle() async {
        while let holder = policy.inFlight { await holder.value }
    }
}

// MARK: - The integration

@MainActor
@Suite("A real export against a real drain (098 · finding 11)")
struct InboxDrainExportIntegrationTests {

    /// How many captures the inbox is seeded with. Thirty because it has to outlast the
    /// gate: the export is requested after the FIRST ingest is reported, and with a width
    /// of 2 there have to be enough left that the pass is unambiguously still running.
    private static let captures = 30

    @Test("an export fired mid-drain sends every capture, and skips none")
    func exportMidDrainSkipsNothing() async throws {
        let rig = try PhoneRig.make(width: 2)
        defer { rig.cleanup() }

        for index in 0 ..< Self.captures { try rig.share(index) }
        #expect(try rig.pendingCount() == Self.captures)
        #expect(try rig.ingestedCount() == 0)

        // The pass starts, and we do not proceed until it is demonstrably inside an
        // ingest — the sink that opens this gate runs from within the pipeline.
        rig.policy.drain()
        await rig.firstIngest.wait()
        #expect(rig.policy.isDraining)

        // The export, requested while the drain is moving records. `exclusively` claims
        // the inbox before it waits, waits the pass out, and only then runs the body.
        var exported: Result<(root: URL, summary: InboxArchive.Summary), any Error>?
        await rig.policy.exclusively {
            // Inside the export body the inbox is held, so an activation arriving here
            // must be REMEMBERED rather than dropped: there is no pass in flight to
            // inherit it. This is the case the policy's guard order was fixed for (455),
            // asserted here against a real export rather than a closure that appends.
            #expect(rig.policy.exportsHolding == 1)
            rig.policy.drain()

            exported = Result { try rig.exportNow(named: "export-1") }
        }

        let (archive, summary) = try #require(try exported?.get())

        // 1. Nothing was left behind. A record read from a site it had just left is
        //    exactly what shows up here — as a skip, by name.
        #expect(summary.skipped == 0)
        #expect(summary.skippedIDs.isEmpty)
        #expect(summary.unreadable == 0)
        #expect(summary.captures == Self.captures)
        #expect(summary.files == Self.captures)

        // 2. Every file the manifest promises is on disk. `write` resolves each payload
        //    from the inbox top level or from `ingested/`; a copy that raced a move would
        //    leave a manifest entry pointing at nothing, which no summary count reports.
        let items = try rig.manifestItems(in: archive)
        #expect(items.count == Self.captures)
        for item in items {
            let file = try #require(item.file, "a capture reached the manifest with no file")
            #expect(
                FileManager.default.fileExists(
                    atPath: archive.appendingPathComponent(file).path),
                "manifest names \(file), which is not on disk")
        }

        // 3. The inbox let go. A count stuck above zero silently stops the phone draining
        //    for the rest of the launch and nothing anywhere reports it.
        #expect(rig.policy.exportsHolding == 0)

        // 4. The deferred activation was remembered and became a pass.
        #expect(rig.events == [.activationDeferredDuringExport])
        await rig.settle()

        // 5. Every capture is still accounted for, on the retaining side of the drain.
        //    Thirty in, thirty out; none quarantined, none lost between two directories.
        #expect(try rig.pendingCount() == 0)
        #expect(try rig.ingestedCount() == Self.captures)
        #expect(try rig.pendingCount() + rig.ingestedCount() == Self.captures)

        // 6. And the passes themselves: one that ingested everything, one that found an
        //    empty inbox. `DrainSummary` is `Equatable`, so a pass that quietly did a
        //    fourth thing fails this.
        #expect(rig.summaries == [
            DrainSummary(ingested: Self.captures),
            DrainSummary(),
        ])
        // The second pass decoded nothing: the retained records are out of the pending
        // set, so a retaining drain does not re-ingest what it already ingested.
        #expect(rig.ingestCount == Self.captures)
    }

    /// The same inbox, exported with no drain anywhere near it.
    ///
    /// The control. Every assertion above would also pass if `exclusively` did nothing at
    /// all and the two happened not to collide, so this pins what the archive looks like
    /// when there is provably no race — and the two results being identical is the claim.
    @Test("the same inbox exported with no pass running produces the same archive")
    func exportWithNoDrainIsTheSame() async throws {
        let rig = try PhoneRig.make(width: 2)
        defer { rig.cleanup() }

        for index in 0 ..< Self.captures { try rig.share(index) }

        // Drain to completion first, then export. Nothing overlaps.
        rig.policy.drain()
        await rig.settle()
        #expect(rig.summaries == [DrainSummary(ingested: Self.captures)])
        #expect(try rig.pendingCount() == 0)
        #expect(try rig.ingestedCount() == Self.captures)

        var exported: Result<(root: URL, summary: InboxArchive.Summary), any Error>?
        await rig.policy.exclusively {
            exported = Result { try rig.exportNow(named: "export-quiet") }
        }
        let (archive, summary) = try #require(try exported?.get())

        #expect(summary.skipped == 0)
        #expect(summary.captures == Self.captures)
        #expect(summary.files == Self.captures)
        #expect(try rig.manifestItems(in: archive).allSatisfy { $0.file != nil })
        #expect(rig.policy.exportsHolding == 0)
        // No activation arrived, so nothing was deferred and no second pass ran.
        #expect(rig.events.isEmpty)
        #expect(rig.summaries.count == 1)
    }

    /// An export requested BEFORE the inbox has ever been drained — the phone's first
    /// send, on a device whose app has just been installed.
    ///
    /// The records are all in the inbox top level here, none in `ingested/`, which is the
    /// other half of the two-site resolution `InboxArchive.write` does. A pass fired while
    /// the export holds the inbox must not start, or it would move every one of those
    /// records out from under the copy.
    @Test("an export before any drain sends the pending set, and blocks the pass behind it")
    func exportBeforeAnyDrain() async throws {
        let rig = try PhoneRig.make(width: 2)
        defer { rig.cleanup() }

        for index in 0 ..< Self.captures { try rig.share(index) }
        #expect(try rig.pendingCount() == Self.captures)

        var exported: Result<(root: URL, summary: InboxArchive.Summary), any Error>?
        await rig.policy.exclusively {
            // Everything is still pending: this is the export reading the top level.
            #expect(try! rig.pendingCount() == Self.captures)
            #expect(try! rig.ingestedCount() == 0)

            rig.policy.drain()
            // The pass did not start. If it had, it would be moving the very records the
            // export is about to copy — so the assertion is over the DIRECTORY, not over
            // `isDraining`, which is deliberately true here: the export is what holds the
            // inbox, and one flag for both kinds of holder is the policy's own design.
            #expect(rig.events == [.activationDeferredDuringExport])
            #expect(try! rig.ingestedCount() == 0)

            exported = Result { try rig.exportNow(named: "export-first") }

            // Still nothing moved, and no pass has completed: the deferral holds for the
            // whole body, which is the property the guard order fixed in 455 provides.
            #expect(try! rig.pendingCount() == Self.captures)
            #expect(try! rig.ingestedCount() == 0)
            #expect(rig.summaries.isEmpty)
        }

        let (archive, summary) = try #require(try exported?.get())
        #expect(summary.skipped == 0)
        #expect(summary.captures == Self.captures)
        #expect(summary.files == Self.captures)
        for item in try rig.manifestItems(in: archive) {
            let file = try #require(item.file)
            #expect(FileManager.default.fileExists(
                atPath: archive.appendingPathComponent(file).path))
        }

        // The deferred pass then ran, and found all thirty still pending. Nothing else
        // was deferred or dropped on the way out.
        #expect(rig.events == [.activationDeferredDuringExport])
        await rig.settle()
        #expect(rig.summaries == [DrainSummary(ingested: Self.captures)])
        #expect(rig.policy.exportsHolding == 0)
        #expect(try rig.pendingCount() == 0)
        #expect(try rig.ingestedCount() == Self.captures)
    }
}
