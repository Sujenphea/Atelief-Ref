// AtelierIngestion — draining the capture inbox (092 · S3).
//
// The whole capture-to-library path, end to end, with no iOS target and no device:
// the real `InboxWriter` puts records in a fixture inbox, the real coordinator runs
// them into a real migrated SQLite library, and the assertions are about what is
// left on disk afterwards. Nothing here is a fake — the producer half comes from
// `AtelierCapture`, which is exactly what the share extension will link, so a drift
// between the two sides of the handoff fails a test rather than a share sheet.
//
// Three properties carry the design and get direct tests rather than being inferred:
// the bytes reach the pipeline as a `.fileURL` and are never read into memory; a
// record whose payload has not landed is EARLY, not corrupt, and survives the pass
// untouched; and re-draining a capture that already ingested resolves to the same
// asset instead of a second one, which is what makes a crash mid-drain cheap.
//
// `DrainSummary` is asserted as a value throughout. A pass that quietly did a
// fourth thing fails the comparison, which is the point of it being `Equatable`.
//
// **Where R2's tests stand from.** Order, chunking and cancellation are properties of
// a pass while it is running, and a pass returns one value at the end. The seam used
// to observe the middle of one is `IngestPipeline`'s existing `timing` sink: it is
// called once per successful byte ingest, from inside the ingest, carrying the content
// hash — so a test can record the order records actually ran in, look at the disk at
// that instant, and cancel the surrounding task from within a live pass. Nothing is
// stubbed and no production seam was added for it; the pipeline, the coordinator and
// the drain are the real ones throughout. The single exception is
// `InboxDrain.resolve(_:outcome:into:)`, called directly with `.cancelled` — see the
// test for why that outcome cannot be produced from outside on purpose.
//
// **And where R6's race test stands from.** Everything above proves the drain's
// REACTION to a torn inbox by hand-building one: a record whose payload has been
// deleted, a `.json` that was never valid. That is the right way to pin a reaction,
// and it never once ran the writer that the two-phase design says can only produce
// states the drain survives. The last test in this file does: a real `InboxWriter`
// committing captures while a real `InboxDrain` passes over the same directory, with
// the assertions written so that no interleaving can change any of them.

import Foundation
import Testing

import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore
@testable import AtelierIngestion

@Suite("InboxDrain (092 S3)")
struct InboxDrainTests {
    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Harness

    /// The inbox belonging to a `TempPipeline`'s library — the same path
    /// `LibraryLayout.inbox` resolves, reached through `InboxLayout` because that is
    /// how the writing process reaches it.
    private func inbox(_ env: TempPipeline) -> InboxLayout {
        InboxLayout(libraryRoot: env.root)
    }

    /// The Mac's drain: the library at the end of it is the destination, so an ingested
    /// record is deleted. Stated here rather than defaulted, exactly as the app states it.
    private func drain(_ env: TempPipeline) -> InboxDrain {
        InboxDrain(
            libraryRoot: env.root, coordinator: env.coordinator,
            retention: .discardWhenIngested)
    }

    /// The phone's drain over the same environment — same library, same coordinator, one
    /// different policy. Everything the retention tests assert is the difference between
    /// this and ``drain(_:)``.
    private func retainingDrain(_ env: TempPipeline) -> InboxDrain {
        InboxDrain(
            libraryRoot: env.root, coordinator: env.coordinator,
            retention: .retainForExport)
    }

    /// A drain over a coordinator of a chosen width whose pipeline reports every
    /// ingest to `watcher` as it happens. The store and the library are the
    /// environment's own — only the timing sink and the width differ from `drain(_:)`.
    private func drain(
        _ env: TempPipeline, width: Int, watching watcher: IngestWatcher
    ) -> InboxDrain {
        let pipeline = IngestPipeline(
            store: env.store, services: env.services,
            timing: { [watcher] timing in watcher.observed(timing) })
        return InboxDrain(
            libraryRoot: env.root,
            coordinator: IngestCoordinator(pipeline: pipeline, maxConcurrent: width),
            retention: .discardWhenIngested)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func readRecord(at url: URL) throws -> InboxRecord {
        try InboxRecord.makeDecoder().decode(InboxRecord.self, from: Data(contentsOf: url))
    }

    /// A media-less capture per kind, with a payload the content funnel will accept.
    /// `CaptureFixtures.sampleContent` defaults to a link payload for every kind,
    /// which is fine for a writer test and useless for one that actually ingests.
    private static func contentRequest(
        kind: String, collectionId: UUID? = nil
    ) -> CaptureRequest {
        let payload: AssetPayload =
            switch kind {
            case "color": AssetPayload(color: ColorPayload(hex: "#4488cc"))
            case "tweet":
                AssetPayload(
                    tweet: TweetPayload(
                        tweetID: "42", text: "a reference", authorHandle: "@designer"))
            default: AssetPayload(link: LinkPayload(url: "https://ex.com/p", title: "P"))
            }
        return .sampleContent(kind: kind, payload: payload, collectionId: collectionId)
    }

    // MARK: - The happy path

    @Test("a record with bytes ingests into its collection and leaves the inbox empty")
    func recordWithBytesDrains() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let bytes = CaptureFixtures.png(width: 40, height: 30)
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: bytes, id: id, capturedAt: Self.capturedAt)

        let summary = await drain(env).drainOnce()
        #expect(summary == DrainSummary(ingested: 1))

        // The asset landed in the target collection, with the bytes it was given.
        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        let asset = try #require(items.first?.asset)
        #expect(asset.kind == .image)
        #expect(asset.width == 40)
        #expect(asset.height == 30)
        #expect(asset.fileSize == bytes.count)
        #expect(env.blobFiles().count == 1)

        // Both files are gone, and nothing is left pending.
        #expect(!exists(layout.recordURL(for: id)))
        #expect(!exists(layout.payloadURL(for: id)))
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    @Test("the capture time is the record's, not the moment of the drain")
    func capturedAtSurvivesTheWait() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        let source = try #require(items.first?.source)
        #expect(source.capturedAt == Self.capturedAt)
    }

    // MARK: - The property the slice exists for

    @Test("bytes on disk reach the pipeline as .fileURL, never as .data")
    func bytesArriveAsAFileURL() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let record = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        let input = try drain(env).makeInput(
            for: record, payload: layout.payloadURL(for: record))

        guard case .bytes(let source) = input.source else {
            Issue.record("expected a byte-backed source, got \(input.source)")
            return
        }
        guard case .fileURL(let url) = source else {
            Issue.record("the inbox handed the pipeline in-memory bytes: \(source)")
            return
        }
        #expect(url == layout.payloadURL(for: id))
    }

    @Test("a media-less capture with a card image also keeps its bytes on disk")
    func cardImageArrivesAsAFileURL() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let record = try InboxWriter(libraryRoot: env.root).write(
            Self.contentRequest(kind: "tweet", collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        let input = try drain(env).makeInput(
            for: record, payload: layout.payloadURL(for: record))

        guard case .contentWithBytes(let draft, let image) = input.source else {
            Issue.record("expected a content-with-bytes source, got \(input.source)")
            return
        }
        #expect(draft.kind == .tweet)
        guard case .fileURL(let url) = image else {
            Issue.record("the card image was read into memory: \(image)")
            return
        }
        #expect(url == layout.payloadURL(for: id))
    }

    // MARK: - Media-less records

    @Test(
        "a media-less record ingests with no payload file",
        arguments: ["tweet", "link", "color"])
    func mediaLessRecordDrains(kind: String) async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let record = try InboxWriter(libraryRoot: env.root).write(
            Self.contentRequest(kind: kind, collectionId: env.collectionID),
            id: id, capturedAt: Self.capturedAt)
        #expect(record.payloadFile == nil)

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        #expect(items.first?.asset.kind == AssetKind(rawValue: kind))
        // Media-less means media-less: nothing was written to the blob store.
        #expect(env.blobFiles().isEmpty)
        #expect(!exists(layout.recordURL(for: id)))
    }

    // MARK: - The target collection (092 · S3, settling 091's open question 2)

    @Test("a record with no collection lands in Unsorted, like an untargeted capture")
    func noCollectionLandsInUnsorted() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: nil),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        let unsorted = try await env.services.collectionItems(
            in: Collection.unsortedID, includeArchived: false)
        #expect(unsorted.count == 1)
        // And NOT in the test collection — there is no inbox collection concept.
        let target = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(target.isEmpty)
    }

    @Test("a record naming a collection lands in that collection")
    func namedCollectionIsHonored() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        let target = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(target.count == 1)
        let unsorted = try await env.services.collectionItems(
            in: Collection.unsortedID, includeArchived: false)
        #expect(unsorted.isEmpty)
    }

    // MARK: - Early, not corrupt

    @Test("a record whose payload has not landed is skipped, then drains once it does")
    func incompleteRecordIsSkippedNotFailed() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let bytes = CaptureFixtures.png()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: bytes, id: id, capturedAt: Self.capturedAt)
        // Rewind to the instant between the writer's two phases: the record is
        // committed, its payload has not appeared yet.
        try FileManager.default.removeItem(at: layout.payloadURL(for: id))

        let first = await drain(env).drainOnce()
        #expect(first == DrainSummary(skippedIncomplete: 1))

        // Untouched: still pending, and no attempt was spent on being young.
        #expect(exists(layout.recordURL(for: id)))
        #expect(try layout.pendingRecordURLs().count == 1)
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 0)
        #expect(try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false).isEmpty)

        // The writer's second phase completes; the next pass ingests it.
        try bytes.write(to: layout.payloadURL(for: id))
        let second = await drain(env).drainOnce()
        #expect(second == DrainSummary(ingested: 1))
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    // MARK: - Malformed, not transient (092 · S3 · D-a)

    @Test("a payloadFile that escapes the inbox quarantines at once, attempts unspent")
    func pathTraversalQuarantinesImmediately() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        // Hand-written, because `InboxWriter` cannot produce this — the name is
        // always derived from the id. This is the hostile-record case: a `.json` that
        // crossed a process boundary naming a path outside the directory.
        let id = UUID()
        let record = InboxRecord(
            id: id, capturedAt: Self.capturedAt,
            request: .sample(collectionId: env.collectionID),
            payloadFile: "../escape.bin")
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try InboxRecord.makeEncoder().encode(record).write(to: layout.recordURL(for: id))

        #expect(await drain(env).drainOnce() == DrainSummary(quarantined: 1))

        // Out of the inbox on the first pass, with the counter untouched: a rejected
        // name will never become valid, so retrying it three times is waste.
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(!exists(layout.recordURL(for: id)))
        let quarantined = layout.failed.appendingPathComponent("\(id.uuidString).json")
        #expect(exists(quarantined))
        #expect(try readRecord(at: quarantined).attempts == 0)
    }

    @Test("a record naming a sibling's file quarantines, and the sibling survives")
    func aRecordCannotTakeASiblingWithIt() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        // The victim: a real capture whose payload has not landed yet, so it is merely
        // EARLY and survives this pass untouched no matter which order the two records
        // are enumerated in.
        let victimID = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: victimID, capturedAt: Self.capturedAt)
        try FileManager.default.removeItem(at: layout.payloadURL(for: victimID))

        // The hostile record: a `payloadFile` that is a perfectly plain component,
        // inside the inbox, and is the victim's record. Resolving it would hand the
        // pipeline someone else's `.json` as media and then — on either the success or
        // the quarantine path — delete or carry off the capture it belongs to.
        let hostileID = UUID()
        let hostile = InboxRecord(
            id: hostileID, capturedAt: Self.capturedAt,
            request: .sample(collectionId: env.collectionID),
            payloadFile: InboxLayout.recordFileName(for: victimID))
        try InboxRecord.makeEncoder().encode(hostile)
            .write(to: layout.recordURL(for: hostileID))

        #expect(
            await drain(env).drainOnce()
                == DrainSummary(skippedIncomplete: 1, quarantined: 1))

        // The whole point: the victim is still in the inbox, still enumerable, and
        // still has its attempts.
        #expect(exists(layout.recordURL(for: victimID)))
        #expect(try readRecord(at: layout.recordURL(for: victimID)).attempts == 0)
        #expect(try layout.pendingRecordURLs().map(\.lastPathComponent)
            == ["\(victimID.uuidString).json"])
        // And it was not carried into `failed/` either — quarantining the hostile
        // record must move the hostile record and nothing else.
        #expect(!exists(layout.failed.appendingPathComponent("\(victimID.uuidString).json")))

        // The hostile record is out of the way on the first pass, attempts unspent.
        let quarantined = layout.failed.appendingPathComponent("\(hostileID.uuidString).json")
        #expect(exists(quarantined))
        #expect(try readRecord(at: quarantined).attempts == 0)
        #expect(try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false).isEmpty)
    }

    @Test("a record that will not parse is quarantined with its bytes")
    func unparsableRecordIsQuarantined() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(to: layout.recordURL(for: id))
        try CaptureFixtures.png().write(to: layout.payloadURL(for: id))

        #expect(await drain(env).drainOnce() == DrainSummary(quarantined: 1))

        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).json")))
        // The orphaned sidecar goes with it rather than leaking.
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).bin")))
        #expect(!exists(layout.payloadURL(for: id)))
    }

    // MARK: - Three attempts, then out of the way

    @Test("a failing capture retries twice and quarantines on the third pass")
    func transientFailureQuarantinesOnTheThirdAttempt() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        // Bytes the pipeline recognizes as nothing it ingests → `.unsupportedType`,
        // a deterministic failure that repeats on every pass.
        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: Data("not an image".utf8), id: id, capturedAt: Self.capturedAt)

        let drain = drain(env)

        #expect(await drain.drainOnce() == DrainSummary(retrying: 1))
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 1)
        #expect(exists(layout.payloadURL(for: id)))

        #expect(await drain.drainOnce() == DrainSummary(retrying: 1))
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 2)

        #expect(await drain.drainOnce() == DrainSummary(quarantined: 1))

        // Both halves of the capture are in `failed/`, and the quarantined record
        // carries the count that actually exhausted.
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(!exists(layout.recordURL(for: id)))
        #expect(!exists(layout.payloadURL(for: id)))
        let quarantined = layout.failed.appendingPathComponent("\(id.uuidString).json")
        #expect(exists(quarantined))
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).bin")))
        #expect(try readRecord(at: quarantined).attempts == InboxDrain.maxAttempts)

        // A fourth pass has nothing to do — quarantine is terminal, not a pause.
        #expect(await drain.drainOnce() == DrainSummary())
    }

    @Test("a rewritten record keeps everything but its attempt count")
    func rewriteOnlyChangesTheCounter() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let written = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: Data("not an image".utf8), id: id, capturedAt: Self.capturedAt)

        #expect(await drain(env).drainOnce() == DrainSummary(retrying: 1))

        var expected = written
        expected.attempts = 1
        #expect(try readRecord(at: layout.recordURL(for: id)) == expected)
        // The rewrite stages and moves like every other commit here: nothing is left
        // behind in `.staging/`.
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    // MARK: - The stamp lands before the run (098 · finding 1a)
    //
    // The counter used to be written only when the coordinator REPORTED a failure, which
    // counts every failure a Mac has and none of the ones a phone has: jetsam takes the
    // process mid-decode, the record is still pending at `attempts: 0`, and the same
    // capture is re-run at every launch and every foreground forever. A test cannot kill
    // its own process, so the two halves are asserted separately — the first proves what
    // the drain leaves on disk WHILE a record is running (which is exactly what a kill
    // would leave), and the rest replay that residue.

    /// The state a jetsam kill leaves behind, read at the only instant it exists: from
    /// inside the ingest, before any outcome has been resolved.
    @Test("a crash mid-ingest has already spent the attempt")
    func theStampIsCommittedBeforeTheCoordinatorRuns() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let watcher = IngestWatcher()
        let observed = ObservedRecord()

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 20, height: 20), id: id,
            capturedAt: Self.capturedAt)

        watcher.onFirstIngest {
            observed.record(
                try? InboxRecord.makeDecoder().decode(
                    InboxRecord.self,
                    from: Data(contentsOf: layout.recordURL(for: id))))
        }
        #expect(await drain(env, width: 1, watching: watcher).drainOnce()
            == DrainSummary(ingested: 1))

        // One attempt, committed, while the capture was still being ingested.
        #expect(try #require(observed.recorded).attempts == 1)
        // And the record it was read from is a whole record, not a torn one: the stamp
        // goes through `InboxWriter.rewrite`, which stages and replaces atomically.
        #expect(try #require(observed.recorded).id == id)
    }

    /// The residue replayed. Each pass in the sequence writes what the pass above
    /// proves an interrupted one leaves, and the fourth is where the budget is gone —
    /// with no failure ever reported by anyone, which is the point: three crashes and
    /// three reported failures cost a capture the same three attempts.
    @Test(
        "three interrupted passes reach the terminal fate",
        arguments: [InboxDrain.Retention.discardWhenIngested, .retainForExport])
    func threeInterruptedPassesReachTheTerminalFate(
        retention: InboxDrain.Retention
    ) async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)

        let id = UUID()
        var record = try writer.write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 20, height: 20), id: id,
            capturedAt: Self.capturedAt)
        for attempt in 1...InboxDrain.maxAttempts {
            record.attempts = attempt
            try writer.rewrite(record)
        }

        let drain = InboxDrain(
            libraryRoot: env.root, coordinator: env.coordinator, retention: retention)
        let summary = await drain.drainOnce()

        switch retention {
        case .discardWhenIngested:
            #expect(summary == DrainSummary(quarantined: 1))
            #expect(!exists(layout.recordURL(for: id)))
            #expect(exists(layout.failedRecordURL(for: id)))
            #expect(try readRecord(at: layout.failedRecordURL(for: id)).attempts
                == InboxDrain.maxAttempts)
        case .retainForExport:
            #expect(summary == DrainSummary(skippedExhausted: 1))
            #expect(exists(layout.recordURL(for: id)))
            #expect(!exists(layout.failed))
        }
        // Neither host ingested it: the budget was gone before the payload was read.
        #expect(env.blobFiles().isEmpty)
    }

    /// A record left mid-flight by a crash is picked up at the count it carries, not at
    /// zero — the property that makes three crashes cost three attempts rather than
    /// infinitely many.
    @Test("a crash residue resumes at its stamped count")
    func crashResidueResumesAtItsCount() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)

        let id = UUID()
        var record = try writer.write(
            .sample(collectionId: env.collectionID),
            payload: Data("not an image".utf8), id: id, capturedAt: Self.capturedAt)
        record.attempts = 1
        try writer.rewrite(record)

        // The second attempt is spent on this pass, not the first.
        #expect(await drain(env).drainOnce() == DrainSummary(retrying: 1))
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 2)
        // Which leaves exactly one, and the pass after it is terminal.
        #expect(await drain(env).drainOnce() == DrainSummary(quarantined: 1))
    }

    /// The rule the stamp must not have broken: backgrounding a phone cancels the pass,
    /// and a cancelled record must come back to the count it had. Driven through
    /// `resolve` for the reason the cancellation section below gives at length — the
    /// coordinator produces `.cancelled` only in a window a test cannot open — with the
    /// stamp written by hand first, because that is what the pass would have committed.
    @Test("a cancelled record gives back the attempt the stamp spent")
    func cancelledRecordSpendsNothingAfterTheStamp() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)

        let id = UUID()
        var stamped = try writer.write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        stamped.attempts = 1
        try writer.rewrite(stamped)

        var pass = InboxDrain.Pass(layout: layout)
        drain(env).resolve(stamped, outcome: .cancelled, into: &pass, restoringTo: 0)

        #expect(pass.summary == DrainSummary())
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 0)
        #expect(exists(layout.payloadURL(for: id)))
        #expect(try layout.pendingRecordURLs().count == 1)
    }

    /// And the restore is not a blanket rewrite: an outcome that arrived for a record
    /// whose count was never moved touches nothing at all.
    @Test("a restore with nothing to give back writes nothing")
    func restoringAnUnstampedRecordIsANoOp() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let written = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        var pass = InboxDrain.Pass(layout: layout)
        drain(env).resolve(written, outcome: nil, into: &pass, restoringTo: 0)

        #expect(try readRecord(at: layout.recordURL(for: id)) == written)
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    // MARK: - The dedup property that makes a crash cheap

    @Test("re-draining a capture that already ingested is a no-op, not a duplicate")
    func reDrainingIsANoOp() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let id = UUID()
        let request = CaptureRequest.sample(collectionId: env.collectionID)
        let bytes = CaptureFixtures.png(width: 64, height: 64)
        let writer = InboxWriter(libraryRoot: env.root)

        try writer.write(request, payload: bytes, id: id, capturedAt: Self.capturedAt)
        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        let after = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(after.count == 1)

        // The exact state a crash between "ingested" and "deleted" leaves: the same
        // record, byte for byte, still sitting in the inbox.
        try writer.write(request, payload: bytes, id: id, capturedAt: Self.capturedAt)
        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        // 18A dedup resolved the retry onto the asset that is already there.
        let again = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(again.count == 1)
        #expect(again.first?.asset.id == after.first?.asset.id)
        #expect(env.blobFiles().count == 1)
    }

    // MARK: - What enumeration must not see (092 · S3 · requirement 7)

    @Test(".staging/ and failed/ are never enumerated as pending")
    func stagingAndFailedAreInvisible() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let fileManager = FileManager.default

        // One real, drainable capture.
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)

        // A record mid-write, and a record already given up on. Both are `*.json`
        // and both are one directory below the enumeration.
        try fileManager.createDirectory(at: layout.failed, withIntermediateDirectories: true)
        let stagedID = UUID()
        let failedID = UUID()
        let decoy = try InboxRecord.makeEncoder().encode(
            InboxRecord(
                id: stagedID, capturedAt: Self.capturedAt,
                request: .sample(collectionId: env.collectionID)))
        try decoy.write(to: layout.stagedRecordURL(for: stagedID))
        let quarantined = layout.failed.appendingPathComponent("\(failedID.uuidString).json")
        try decoy.write(to: quarantined)

        #expect(try layout.pendingRecordURLs().count == 1)
        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        // The decoys are exactly where they were — a drain neither ingests nor
        // cleans up what it cannot see.
        #expect(exists(layout.stagedRecordURL(for: stagedID)))
        #expect(exists(quarantined))
        #expect(try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false).count == 1)
    }

    // MARK: - Nothing to do

    @Test("an inbox that was never written to drains to an empty summary")
    func absentInboxIsAnEmptyPass() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        #expect(!exists(inbox(env).directory))
        #expect(await drain(env).drainOnce() == DrainSummary())
    }

    @Test("a mixed pass reports every fate at once")
    func mixedPassIsAccountedFor() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)

        // One that ingests.
        try writer.write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)
        // One that fails and will be retried.
        try writer.write(
            .sample(collectionId: env.collectionID),
            payload: Data("not an image".utf8), capturedAt: Self.capturedAt)
        // One whose payload has not landed.
        let incompleteID = UUID()
        try writer.write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: incompleteID, capturedAt: Self.capturedAt)
        try FileManager.default.removeItem(at: layout.payloadURL(for: incompleteID))
        // One that can never be read.
        let hostileID = UUID()
        try InboxRecord.makeEncoder().encode(
            InboxRecord(
                id: hostileID, capturedAt: Self.capturedAt,
                request: .sample(collectionId: env.collectionID),
                payloadFile: "../escape.bin")
        ).write(to: layout.recordURL(for: hostileID))

        let summary = await drain(env).drainOnce()
        #expect(
            summary
                == DrainSummary(
                    ingested: 1, skippedIncomplete: 1, quarantined: 1, retrying: 1))

        // Two records survive the pass: the one being retried and the one that was
        // merely early.
        #expect(try layout.pendingRecordURLs().count == 2)
    }

    // MARK: - Capture order, not file order (R2 · issues 3A / 16A)

    /// `count` ids whose file-name order is the exact REVERSE of the order they are
    /// returned in. Written to in the returned order with an increasing `capturedAt`,
    /// they make "sorted by name" and "sorted by capture time" opposite orderings —
    /// so a drain that still used the enumeration's order fails by the width of the
    /// batch rather than by luck. (A UUIDv4 has no order worth relying on; this
    /// imposes one.)
    private static func idsReversingNameOrder(_ count: Int) -> [UUID] {
        (0 ..< count).map { _ in UUID() }
            .sorted { $0.uuidString < $1.uuidString }
            .reversed()
    }

    @Test("records drain oldest-capture-first, not in the order their names sort")
    func recordsDrainInCaptureOrder() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let writer = InboxWriter(libraryRoot: env.root)
        let watcher = IngestWatcher()

        // Distinct bytes per record so the ingest reports a distinct hash, and a
        // capture time that increases with a name that decreases.
        let ids = Self.idsReversingNameOrder(4)
        var expected: [String] = []
        for (offset, id) in ids.enumerated() {
            let bytes = CaptureFixtures.png(width: 40 + offset, height: 30)
            expected.append(ContentHasher.hash(bytes))
            try writer.write(
                .sample(collectionId: env.collectionID),
                payload: bytes, id: id,
                capturedAt: Self.capturedAt.addingTimeInterval(Double(offset)))
        }

        // Width 1: a chunk holds one record, so the order ingests are reported in IS
        // the order the pass walked. (Inside a wider chunk the order is deliberately
        // unspecified — see the chunk tests below.)
        let summary = await drain(env, width: 1, watching: watcher).drainOnce()
        #expect(summary == DrainSummary(ingested: 4))
        #expect(watcher.ingestOrder == expected)
    }

    @Test("two records captured in the same instant still have one order")
    func capturedAtTiesBreakOnID() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let writer = InboxWriter(libraryRoot: env.root)
        let watcher = IngestWatcher()

        // Same timestamp to the millisecond — a plausible pair from one multi-select
        // share. The id is what decides, and it decides the same way every run.
        let ids = Self.idsReversingNameOrder(2)
        var bytes: [UUID: Data] = [:]
        for (offset, id) in ids.enumerated() {
            let payload = CaptureFixtures.png(width: 60 + offset, height: 20)
            bytes[id] = payload
            try writer.write(
                .sample(collectionId: env.collectionID),
                payload: payload, id: id, capturedAt: Self.capturedAt)
        }

        #expect(await drain(env, width: 1, watching: watcher).drainOnce()
            == DrainSummary(ingested: 2))

        let byID = ids.sorted { $0.uuidString < $1.uuidString }
        #expect(watcher.ingestOrder == byID.map { ContentHasher.hash(bytes[$0]!) })
    }

    @Test("a record that will not decode is quarantined before any ingest begins")
    func unparsableRecordsAreResolvedFirst() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)
        let watcher = IngestWatcher()

        // The garbage has no `capturedAt` to be ordered by — that is what "will not
        // decode" means — so it takes the defined position the drain gives it: the
        // front, ahead of every record with a capture time.
        let brokenID = UUID()
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(to: layout.recordURL(for: brokenID))

        for offset in 0 ..< 2 {
            try writer.write(
                .sample(collectionId: env.collectionID),
                payload: CaptureFixtures.png(width: 40 + offset, height: 30),
                capturedAt: Self.capturedAt.addingTimeInterval(Double(offset)))
        }

        // Asked from inside the first ingest: by then the quarantine has to have
        // happened already, which is a claim about ORDER that the end state cannot
        // make (both fates are visible either way once the pass returns).
        let quarantinedByFirstIngest = Latch()
        let failed = layout.failed.appendingPathComponent("\(brokenID.uuidString).json")
        watcher.onFirstIngest { [self] in
            quarantinedByFirstIngest.set(exists(failed))
        }

        let summary = await drain(env, width: 1, watching: watcher).drainOnce()
        #expect(summary == DrainSummary(ingested: 2, quarantined: 1))
        #expect(quarantinedByFirstIngest.isSet)
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    // MARK: - An unreadable inbox is not an empty one (R2 · issue 6A)

    @Test("an inbox that cannot be enumerated reports itself, and still never throws")
    func unreadableInboxIsFlagged() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        // A regular file where the inbox directory belongs: the container is present
        // (so this is not "nothing was ever shared") and enumerating it fails. The
        // App Group cases this stands in for — a container that has gone away, a
        // protected-data denial — are not reachable from a unit test, and they arrive
        // here as the same throw.
        try Data("not a directory".utf8).write(to: inbox(env).directory)

        #expect(await drain(env).drainOnce() == DrainSummary(inboxUnreadable: true))
    }

    @Test("an empty inbox and an unreadable one are different values")
    func emptyAndUnreadableAreDistinguishable() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        // Never written to: nothing has been shared, which is the normal case on
        // every launch and must not look like a failure.
        let absent = await drain(env).drainOnce()
        #expect(absent.inboxUnreadable == false)

        // Written to and drained empty: also not a failure.
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        let empty = await drain(env).drainOnce()
        #expect(empty == DrainSummary())

        // The whole point of the flag: this one is.
        try FileManager.default.removeItem(at: layout.directory)
        try Data("not a directory".utf8).write(to: layout.directory)
        #expect(await drain(env).drainOnce().inboxUnreadable)
    }

    // MARK: - Chunked at the coordinator's width (R2 · issue 13A)

    @Test("a backlog larger than the chunk width drains completely")
    func backlogDrainsAcrossChunks() async throws {
        // Five records at width two: two full chunks and a tail of one.
        let env = try await makeTempPipeline(maxConcurrent: 2)
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)

        for offset in 0 ..< 5 {
            try writer.write(
                .sample(collectionId: env.collectionID),
                payload: CaptureFixtures.png(width: 40 + offset, height: 30),
                capturedAt: Self.capturedAt.addingTimeInterval(Double(offset)))
        }

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 5))

        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(env.blobFiles().count == 5)
        #expect(try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false).count == 5)
    }

    @Test("the drain chunks at the coordinator's own width, not a width of its own")
    func chunkWidthComesFromTheCoordinator() async throws {
        let env = try await makeTempPipeline(maxConcurrent: 3)
        defer { env.cleanup() }
        // The number the drain reads. If this ever stops being reachable, the drain
        // has grown a second constant meaning the same thing.
        #expect(env.coordinator.maxConcurrent == 3)
    }

    @Test("every record in a chunk gets its own fate, matched by index")
    func chunkOutcomesResolveByIndex() async throws {
        let env = try await makeTempPipeline(maxConcurrent: 2)
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)

        // Two chunks of two, alternating good and bad so a mis-alignment by one index
        // would delete a record that failed and stamp one that succeeded — which the
        // summary alone would not catch, since the counts would be the same.
        var good: [UUID] = []
        var bad: [UUID] = []
        for offset in 0 ..< 4 {
            let id = UUID()
            let ingests = offset.isMultiple(of: 2)
            try writer.write(
                .sample(collectionId: env.collectionID),
                payload: ingests
                    ? CaptureFixtures.png(width: 40 + offset, height: 30)
                    : Data("not an image".utf8),
                id: id, capturedAt: Self.capturedAt.addingTimeInterval(Double(offset)))
            if ingests { good.append(id) } else { bad.append(id) }
        }

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 2, retrying: 2))

        for id in good {
            #expect(!exists(layout.recordURL(for: id)))
            #expect(!exists(layout.payloadURL(for: id)))
        }
        for id in bad {
            #expect(exists(layout.payloadURL(for: id)))
            #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 1)
        }
        #expect(env.blobFiles().count == 2)
    }

    @Test("a chunk mixing every fate resolves each of them")
    func chunkMixesEveryFate() async throws {
        let env = try await makeTempPipeline(maxConcurrent: 4)
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)

        // Four records that would fill one chunk if they all reached it. Two never
        // do: one is quarantined and one is skipped before the chunk is filled, which
        // is the case a chunk built from "every pending record" would get wrong.
        try writer.write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)
        try writer.write(
            .sample(collectionId: env.collectionID),
            payload: Data("not an image".utf8),
            capturedAt: Self.capturedAt.addingTimeInterval(1))
        let incompleteID = UUID()
        try writer.write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 12, height: 12), id: incompleteID,
            capturedAt: Self.capturedAt.addingTimeInterval(2))
        try FileManager.default.removeItem(at: layout.payloadURL(for: incompleteID))
        let hostileID = UUID()
        try InboxRecord.makeEncoder().encode(
            InboxRecord(
                id: hostileID, capturedAt: Self.capturedAt.addingTimeInterval(3),
                request: .sample(collectionId: env.collectionID),
                payloadFile: "../escape.bin")
        ).write(to: layout.recordURL(for: hostileID))

        #expect(
            await drain(env).drainOnce()
                == DrainSummary(
                    ingested: 1, skippedIncomplete: 1, quarantined: 1, retrying: 1))
        #expect(try layout.pendingRecordURLs().count == 2)
    }

    // MARK: - `failed/` is created once a pass, and only if needed

    @Test("a pass that quarantines nothing leaves no failed/ behind")
    func cleanPassCreatesNoFailedDirectory() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))
        // `failed/` existing is how a human finds out something went wrong, so a pass
        // that went fine must not create it. (The directory is made once per pass, on
        // the first quarantine, rather than once per quarantined record.)
        #expect(!exists(layout.failed))
    }

    @Test("two records quarantined in one pass both land in failed/")
    func twoQuarantinesInOnePass() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        // One that will not parse and one whose `payloadFile` is refused: the two
        // quarantine call sites, in a single pass, sharing one directory create.
        let brokenID = UUID()
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(to: layout.recordURL(for: brokenID))
        let hostileID = UUID()
        try InboxRecord.makeEncoder().encode(
            InboxRecord(
                id: hostileID, capturedAt: Self.capturedAt,
                request: .sample(collectionId: env.collectionID),
                payloadFile: "../escape.bin")
        ).write(to: layout.recordURL(for: hostileID))

        #expect(await drain(env).drainOnce() == DrainSummary(quarantined: 2))
        #expect(exists(layout.failed.appendingPathComponent("\(brokenID.uuidString).json")))
        #expect(exists(layout.failed.appendingPathComponent("\(hostileID.uuidString).json")))
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    // MARK: - Who owns the library at the end of the drain (096 · 4)

    /// The phone's half. Ingestion is a waypoint there — the capture is in the local grid
    /// and still owed to the Mac — so the record survives it, and the two assertions that
    /// matter are that it is OUT of the pending set and still ON disk.
    @Test("under .retainForExport an ingested record moves to ingested/ rather than dying")
    func retainedRecordSurvivesIngestion() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let bytes = CaptureFixtures.png(width: 24, height: 18)
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: bytes, id: id, capturedAt: Self.capturedAt)

        #expect(await retainingDrain(env).drainOnce() == DrainSummary(ingested: 1))

        // It really ingested: the asset is in the library with its bytes.
        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        #expect(items.first?.asset.width == 24)
        #expect(env.blobFiles().count == 1)

        // And it really survived, in the one place that is neither pending nor `sent/`.
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(!exists(layout.recordURL(for: id)))
        #expect(!exists(layout.payloadURL(for: id)))
        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(exists(layout.ingested.appendingPathComponent("\(id.uuidString).bin")))
        #expect(try layout.ingestedRecordURLs().count == 1)
        // `sent/` is the user's assertion that the Mac has it, and nothing has asserted
        // that. Folding the two together would make the next export skip a capture the
        // phone never sent.
        #expect(!exists(layout.sent))
    }

    /// The Mac's half, asserted against the same fixture so the pair reads as one
    /// difference. This is the behaviour 092 · S3 shipped and it must not have moved.
    @Test("under .discardWhenIngested the record is deleted and no ingested/ appears")
    func discardedRecordIsDeleted() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 24, height: 18), id: id,
            capturedAt: Self.capturedAt)

        #expect(await drain(env).drainOnce() == DrainSummary(ingested: 1))

        #expect(!exists(layout.recordURL(for: id)))
        #expect(!exists(layout.payloadURL(for: id)))
        #expect(!exists(layout.ingestedRecordURL(for: id)))
        // A Mac drains with this policy forever and must never grow a directory that
        // describes a policy it does not have.
        #expect(!exists(layout.ingested))
        #expect(try layout.ingestedRecordURLs().isEmpty)
    }

    /// The reason the record leaves the pending set at all. Retaining it in `inbox/` would
    /// have been simpler and would have re-ingested every capture the phone ever made, once
    /// per pass, for the life of the device.
    @Test("a second retaining pass does not re-ingest what the first one kept")
    func retainedRecordIsNotDrainedTwice() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)

        let drain = retainingDrain(env)
        #expect(await drain.drainOnce() == DrainSummary(ingested: 1))
        // Nothing to do — not "ingested again and deduped", which would also leave one
        // asset behind and would hide a pass doing work on every launch forever.
        #expect(await drain.drainOnce() == DrainSummary())
        #expect(await drain.drainOnce() == DrainSummary())

        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        #expect(try layout.ingestedRecordURLs().count == 1)
    }

    @Test("a retained media-less record moves with no payload to carry")
    func retainedMediaLessRecordMoves() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            Self.contentRequest(kind: "link", collectionId: env.collectionID),
            payload: PayloadSource?.none, id: id, capturedAt: Self.capturedAt)

        #expect(await retainingDrain(env).drainOnce() == DrainSummary(ingested: 1))

        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(!exists(layout.ingested.appendingPathComponent("\(id.uuidString).bin")))
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    /// `ingested/` is lazy for the reason `failed/` is: a directory that exists is a fact
    /// about what has happened, and a pass that retained nothing has nothing to say.
    @Test("a retaining pass that ingests nothing leaves no ingested/ behind")
    func retainingPassWithNoIngestCreatesNoDirectory() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(to: layout.recordURL(for: id))

        #expect(await retainingDrain(env).drainOnce() == DrainSummary(quarantined: 1))
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).json")))
        #expect(!exists(layout.ingested))
    }

    /// Retention is about SUCCESS, and a capture that exhausts its attempts never
    /// reaches `ingested/` — but on a phone it does not reach `failed/` either (098 ·
    /// finding 1b). `InboxArchive` reads the pending set and `ingested/`, so a
    /// quarantine here would take the capture out of every future export, on a device
    /// with no screen that shows `failed/`, for bytes the Mac may well decode. It stays
    /// pending, out of the drain's way and in front of the export.
    @Test("under .retainForExport an exhausted capture stays exportable")
    func exhaustedCaptureStaysExportableUnderRetention() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: Data("not an image".utf8), id: id, capturedAt: Self.capturedAt)

        let drain = retainingDrain(env)
        #expect(await drain.drainOnce() == DrainSummary(retrying: 1))
        // A retry leaves the record pending, exactly as before — retention has no opinion
        // about a capture that has not succeeded yet.
        #expect(exists(layout.recordURL(for: id)))
        #expect(!exists(layout.ingested))

        #expect(await drain.drainOnce() == DrainSummary(retrying: 1))
        // The third run is the last one, and it is where the two policies part.
        #expect(await drain.drainOnce() == DrainSummary(skippedExhausted: 1))

        #expect(exists(layout.recordURL(for: id)))
        #expect(exists(layout.payloadURL(for: id)))
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts
            == InboxDrain.maxAttempts)
        #expect(!exists(layout.failed))
        #expect(!exists(layout.ingested))

        // And it stays that way, for nothing: no ingest, no move, no fourth attempt.
        #expect(await drain.drainOnce() == DrainSummary(skippedExhausted: 1))
        #expect(try layout.pendingRecordURLs().count == 1)
        #expect(env.blobFiles().isEmpty)
    }

    /// The Mac's half of the same fixture, so the pair reads as one difference. This is
    /// the behaviour 092 · S3 shipped and it must not have moved: there is no consumer
    /// downstream of a Mac's inbox, so a capture that will never ingest is only in the
    /// way, and `failed/` is where a human goes to find it.
    @Test("under .discardWhenIngested an exhausted capture still quarantines")
    func exhaustedCaptureQuarantinesUnderDiscard() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: Data("not an image".utf8), id: id, capturedAt: Self.capturedAt)

        let drain = drain(env)
        #expect(await drain.drainOnce() == DrainSummary(retrying: 1))
        #expect(await drain.drainOnce() == DrainSummary(retrying: 1))
        #expect(await drain.drainOnce() == DrainSummary(quarantined: 1))

        #expect(!exists(layout.recordURL(for: id)))
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).json")))
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).bin")))
        #expect(!exists(layout.ingested))
    }

    /// A malformed record is malformed under both policies: there is nothing for an
    /// export to send either, so the retaining host quarantines it too. The two rules
    /// have to be told apart — "out of attempts" is kept, "will never be a capture" is
    /// not — and this is the pair that says which is which.
    @Test("a retaining drain still quarantines a record that will never be a capture")
    func retainingDrainQuarantinesTheMalformed() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try InboxRecord.makeEncoder().encode(
            InboxRecord(
                id: id, capturedAt: Self.capturedAt,
                request: .sample(collectionId: env.collectionID),
                payloadFile: "../escape.bin")
        ).write(to: layout.recordURL(for: id))

        #expect(await retainingDrain(env).drainOnce() == DrainSummary(quarantined: 1))
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).json")))
        #expect(!exists(layout.recordURL(for: id)))
    }

    /// The cost claim in ``DrainSummary/skippedExhausted``'s own doc, asserted: a record
    /// the drain has given up on is skipped BEFORE anything reads its payload or asks
    /// the coordinator for a slot. The fixture is a perfectly good capture — it would
    /// ingest on sight — so the only thing that can be stopping it is the count.
    @Test("a skipped-exhausted record costs no coordinator run")
    func skippedExhaustedRecordIsNeverRun() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let watcher = IngestWatcher()

        let id = UUID()
        var record = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 30, height: 20), id: id,
            capturedAt: Self.capturedAt)
        // The residue of three interrupted passes — the shape
        // `theStampIsCommittedBeforeTheCoordinatorRuns` proves the drain writes.
        record.attempts = InboxDrain.maxAttempts
        try InboxWriter(libraryRoot: env.root).rewrite(record)

        let drain = InboxDrain(
            layout: layout,
            coordinator: IngestCoordinator(
                pipeline: IngestPipeline(
                    store: env.store, services: env.services,
                    timing: { [watcher] timing in watcher.observed(timing) }),
                maxConcurrent: 1),
            retention: .retainForExport)

        #expect(await drain.drainOnce() == DrainSummary(skippedExhausted: 1))

        // Nothing ran: no ingest was observed, no blob was written, no asset exists.
        #expect(watcher.ingestOrder.isEmpty)
        #expect(env.blobFiles().isEmpty)
        #expect(try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false).isEmpty)
        // And the capture is still whole, still pending, still exportable.
        #expect(exists(layout.recordURL(for: id)))
        #expect(exists(layout.payloadURL(for: id)))
    }

    /// The interrupted-move contract, forced rather than raced. `inbox/ingested` is made a
    /// regular FILE, so `createDirectory` fails and so does every move into it — the same
    /// shape as a container that has gone read-only mid-pass.
    ///
    /// What must hold: the payload is NOT moved after the record fails to move. That order
    /// is the whole argument — a pending record whose bytes have gone is skipped as
    /// "incomplete, come back later" on every pass forever, and there is no writer coming
    /// back. Leaving both is a re-ingest, which 18A dedup makes free.
    @Test("a retention that cannot move the record leaves the payload beside it")
    func failedRetentionLeavesTheCaptureWhole() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 16, height: 16), id: id,
            capturedAt: Self.capturedAt)
        // Not a directory, and it cannot become one.
        try Data("in the way".utf8).write(to: layout.ingested)

        // The capture DID ingest — the summary reports the fate, not the bookkeeping.
        #expect(await retainingDrain(env).drainOnce() == DrainSummary(ingested: 1))
        #expect(env.blobFiles().count == 1)

        // And it is still a whole capture in the pending set: record and payload together,
        // which is the only state a later pass can do anything with.
        #expect(exists(layout.recordURL(for: id)))
        #expect(exists(layout.payloadURL(for: id)))
        #expect(try layout.pendingRecordURLs().count == 1)

        // Clear the obstruction and the next pass finishes the job, resolving onto the
        // asset that is already there rather than a second one.
        try FileManager.default.removeItem(at: layout.ingested)
        #expect(await retainingDrain(env).drainOnce() == DrainSummary(ingested: 1))
        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(try layout.pendingRecordURLs().isEmpty)
        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        #expect(env.blobFiles().count == 1)
    }

    /// The residue of a crash between the record's move and the payload's — reachable in
    /// production, and it must not wedge the drain. The record is no longer pending, so no
    /// pass reconsiders it; the stray `.bin` is invisible to the enumeration, which is what
    /// makes it a leak rather than a wedge. (`InboxRetirement` reclaims it; that half is
    /// asserted in `AtelierCapture`.)
    @Test("a half-finished retention is inert on the next pass")
    func halfFinishedRetentionIsInert() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let fileManager = FileManager.default

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        try fileManager.createDirectory(
            at: layout.ingested, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: layout.recordURL(for: id), to: layout.ingestedRecordURL(for: id))

        #expect(await retainingDrain(env).drainOnce() == DrainSummary())
        // Untouched, both halves, and nothing ingested — the pass did not see it at all.
        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(exists(layout.payloadURL(for: id)))
        #expect(env.blobFiles().isEmpty)
    }

    /// A retained record naming somebody else's sidecar must not have that name honoured on
    /// the way out, for the reason the quarantine path gives: everything downstream resolves
    /// `payloadFile` into a file it will read, delete or MOVE. `prepare` refuses such a
    /// record before it reaches the coordinator, so this asserts the guard where it lives —
    /// `ingestedURL(named:)` — rather than through an ingest that cannot happen.
    @Test("a retained capture's destination is composed from its own id")
    func retentionComposesNamesFromTheID() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let hostileID = UUID()
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try InboxRecord.makeEncoder().encode(
            InboxRecord(
                id: hostileID, capturedAt: Self.capturedAt,
                request: .sample(collectionId: env.collectionID),
                payloadFile: "../escape.bin")
        ).write(to: layout.recordURL(for: hostileID))

        // Quarantined on sight, and never near `ingested/`.
        #expect(await retainingDrain(env).drainOnce() == DrainSummary(quarantined: 1))
        #expect(!exists(layout.ingested))
        #expect(layout.ingestedURL(named: "../escape.bin") == nil)
    }

    // MARK: - The ingested site is swept once a pass (098 · finding 8)
    //
    // Nothing had ever looked at `inbox/ingested/` after the move that created it. Two
    // states there are permanent: a record that will not decode, and a record whose
    // payload is gone from both sites. `InboxArchive` reads that directory on every
    // export, so either one is a wrong count and a skipped capture for the life of the
    // device, with no control anywhere that can clear it.

    @Test("an ingested record that will not decode is quarantined")
    func corruptIngestedRecordIsQuarantined() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let fileManager = FileManager.default

        let id = UUID()
        try fileManager.createDirectory(
            at: layout.ingested, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(to: layout.ingestedRecordURL(for: id))
        try Data("bytes nobody can name".utf8).write(
            to: layout.ingested.appendingPathComponent(
                InboxLayout.payloadFileName(for: id)))

        #expect(await retainingDrain(env).drainOnce() == DrainSummary(quarantined: 1))

        // Both halves left `ingested/`, so the export stops seeing it — and they are in
        // `failed/`, which is where a whole capture a human might want goes.
        #expect(try layout.ingestedRecordURLs().isEmpty)
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).json")))
        #expect(exists(layout.failed.appendingPathComponent("\(id.uuidString).bin")))
    }

    @Test("an ingested record whose payload is gone from both sites is quarantined")
    func ingestedRecordWithoutBytesIsQuarantined() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let record = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        try InboxFixtures.retain(record, in: layout)
        try FileManager.default.removeItem(at: layout.ingestedPayloadURL(for: id))

        #expect(await retainingDrain(env).drainOnce() == DrainSummary(quarantined: 1))

        #expect(try layout.ingestedRecordURLs().isEmpty)
        #expect(exists(layout.failedRecordURL(for: id)))
        // The record is re-encoded at the destination, so what is in `failed/` is the
        // record that was swept and not a stale copy of it.
        #expect(try readRecord(at: layout.failedRecordURL(for: id)).id == id)
    }

    @Test("a good ingested record is left alone, pass after pass")
    func goodIngestedRecordSurvivesTheSweep() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 24, height: 18), id: id,
            capturedAt: Self.capturedAt)

        let drain = retainingDrain(env)
        #expect(await drain.drainOnce() == DrainSummary(ingested: 1))
        #expect(await drain.drainOnce() == DrainSummary())
        #expect(await drain.drainOnce() == DrainSummary())

        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(exists(layout.ingestedPayloadURL(for: id)))
        #expect(!exists(layout.failed))
    }

    /// A media-less capture is complete without bytes — a shared link is the link — so
    /// "no payload" must not be read as "payload missing".
    @Test("an ingested media-less record is not swept")
    func ingestedMediaLessRecordSurvivesTheSweep() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            Self.contentRequest(kind: "link", collectionId: env.collectionID),
            payload: PayloadSource?.none, id: id, capturedAt: Self.capturedAt)

        let drain = retainingDrain(env)
        #expect(await drain.drainOnce() == DrainSummary(ingested: 1))
        #expect(await drain.drainOnce() == DrainSummary())
        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(!exists(layout.failed))
    }

    /// The residue of a crash between the retention's two moves: the record has moved,
    /// the bytes have not. `InboxArchive` reads that as a whole capture, so the sweep
    /// must not take it away — the payload is present, at the OTHER site.
    @Test("a half-finished retention is not swept away")
    func halfFinishedRetentionSurvivesTheSweep() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let record = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        try InboxFixtures.retain(record, in: layout, movingPayload: false)

        #expect(await retainingDrain(env).drainOnce() == DrainSummary())
        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(exists(layout.payloadURL(for: id)))
        #expect(!exists(layout.failed))
    }

    /// A Mac deletes an ingested record and never grows the directory, so it has no
    /// business walking one — a `ingested/` on a discarding host is somebody else's
    /// inbox mounted in the same place, or a leftover from a policy this host does not
    /// have, and either way it is not this drain's to tidy.
    @Test("a discarding drain never looks in ingested/")
    func discardingDrainDoesNotSweep() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        try FileManager.default.createDirectory(
            at: layout.ingested, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(to: layout.ingestedRecordURL(for: id))

        #expect(await drain(env).drainOnce() == DrainSummary())
        #expect(exists(layout.ingestedRecordURL(for: id)))
        #expect(!exists(layout.failed))
    }

    /// The sweep runs after the pending set, so a capture retained by THIS pass is seen
    /// by it — and survives, because it is whole. The case exists because it is the
    /// common one: every successful pass on a phone ends with the sweep reading the
    /// records it has just written.
    @Test("a record retained by this pass survives the sweep it lands in")
    func retainedThisPassSurvivesItsOwnSweep() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        for offset in 0..<3 {
            try InboxWriter(libraryRoot: env.root).write(
                .sample(collectionId: env.collectionID),
                payload: CaptureFixtures.png(width: 20 + offset, height: 20),
                capturedAt: Self.capturedAt.addingTimeInterval(Double(offset)))
        }

        #expect(await retainingDrain(env).drainOnce() == DrainSummary(ingested: 3))
        #expect(try layout.ingestedRecordURLs().count == 3)
        #expect(!exists(layout.failed))
    }

    // MARK: - Cancellation (R2 · issue 9A)

    @Test("a cancelled outcome spends no attempt, moves no counter, and keeps the record")
    func cancelledOutcomeLeavesTheRecordAlone() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let written = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        // Driven through `resolve` rather than through a pass. `IngestCoordinator` is
        // a concrete actor over a concrete pipeline with nothing to stub, and it only
        // returns `.cancelled` for a slot it never launched — which, now that a chunk
        // is never wider than the coordinator, means only when cancellation lands in
        // the window between the drain's own check and the batch being primed. A test
        // cannot open that window from outside, so the rule is asserted where it is
        // implemented instead of being approximated by a sleep.
        var pass = InboxDrain.Pass(layout: layout)
        drain(env).resolve(written, outcome: .cancelled, into: &pass)

        #expect(pass.summary == DrainSummary())
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 0)
        #expect(exists(layout.payloadURL(for: id)))
        #expect(try layout.pendingRecordURLs().count == 1)
        #expect(try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false).isEmpty)
    }

    @Test("an outcome that never arrived is treated exactly like a cancelled one")
    func missingOutcomeLeavesTheRecordAlone() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)

        let id = UUID()
        let written = try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        // The impossible case — the coordinator returning fewer outcomes than inputs.
        // "We were told nothing about this record" and "this record was not
        // attempted" have the same correct response, and it is not to guess.
        var pass = InboxDrain.Pass(layout: layout)
        drain(env).resolve(written, outcome: nil, into: &pass)

        #expect(pass.summary == DrainSummary())
        #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 0)
        #expect(try layout.pendingRecordURLs().count == 1)
    }

    @Test("cancelling mid-pass leaves every record it had not reached untouched")
    func cancellingMidPassStopsBetweenChunks() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let writer = InboxWriter(libraryRoot: env.root)
        let watcher = IngestWatcher()

        // Three drainable records, oldest first, at width 1 — so the pass is three
        // chunks and cancellation between the first and the second is observable as
        // "one done, two untouched".
        var ids: [UUID] = []
        for offset in 0 ..< 3 {
            let id = UUID()
            ids.append(id)
            try writer.write(
                .sample(collectionId: env.collectionID),
                payload: CaptureFixtures.png(width: 40 + offset, height: 30), id: id,
                capturedAt: Self.capturedAt.addingTimeInterval(Double(offset)))
        }

        // The cancel is fired from INSIDE the first ingest, so it is already set by
        // the time that chunk resolves — no sleeping, no polling, no window where the
        // pass could have finished first.
        let drain = drain(env, width: 1, watching: watcher)
        let box = TaskBox()
        let gate = Gate()
        watcher.onFirstIngest { box.cancel() }
        let pass = Task { () -> DrainSummary in
            await gate.wait()
            return await drain.drainOnce()
        }
        box.arm(pass)
        gate.open()
        let summary = await pass.value

        // The record that was in flight is finished and counted: cancellation stops
        // the pass, it does not un-ingest what already landed.
        #expect(summary == DrainSummary(ingested: 1))
        #expect(!exists(layout.recordURL(for: ids[0])))
        #expect(try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false).count == 1)

        // The two the pass never reached are exactly as they were — still pending,
        // still at zero attempts, nothing quarantined, `failed/` never created.
        #expect(try layout.pendingRecordURLs().count == 2)
        for id in ids.dropFirst() {
            #expect(try readRecord(at: layout.recordURL(for: id)).attempts == 0)
            #expect(exists(layout.payloadURL(for: id)))
        }
        #expect(!exists(layout.failed))

        // And the inbox is the accounting that survives: a fresh, uncancelled pass
        // finishes the job.
        #expect(await self.drain(env).drainOnce() == DrainSummary(ingested: 2))
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    // MARK: - The writer and the drain, actually running at once (R6 · issue 10)

    /// The shapes one round of the race writes, cycled so all three are in flight
    /// throughout rather than grouped.
    ///
    /// Twenty-four of them: enough that the writer is still committing captures
    /// while the drain is enumerating — which is the entire window this test exists
    /// to open — and few enough that four rounds of it stay cheap. Nothing below
    /// spells the number again; the plan built from this is what every count is
    /// taken from.
    private static let raceShapes: [RaceShape] = (0 ..< 24).map {
        RaceShape.allCases[$0 % RaceShape.allCases.count]
    }

    /// The captures one round will write, in order — identities and shapes only.
    ///
    /// **What is NOT here is the point.** The bytes and the provider's temporary file
    /// are produced inside the write loop rather than hoisted into this plan, and the
    /// difference is not stylistic: hoisted, the writer commits twenty-four captures
    /// in a few milliseconds and finishes before the drain has completed a single
    /// pass, so the two never overlap and the race is a race in name only (measured:
    /// one drain pass per round, against seven hundred with the work left in place).
    /// A share extension does not commit captures back to back either — it encodes an
    /// image between them — and it is that gap that puts the two tasks in the same
    /// time domain.
    ///
    /// **Every capture is distinct in every way identity is decided**, because a test
    /// about duplication cannot afford captures that legitimately collapse: the bytes
    /// differ by index (18A dedups a byte asset on its blob hash), the link URLs
    /// differ (a content asset dedups on `(kind, dedupKey)`, and a link's key is its
    /// canonical URL), and the capture times differ by a whole second each — the last
    /// being what identifies a capture on the library side once its id has been left
    /// behind.
    private static func racePlan() -> [RaceCapture] {
        raceShapes.enumerated().map { index, shape in
            RaceCapture(
                id: UUID(),
                capturedAt: capturedAt.addingTimeInterval(Double(index)),
                index: index,
                shape: shape)
        }
    }

    /// The bytes and the request for one planned capture, produced at the moment the
    /// writer is about to commit it — the share extension's own order of work.
    private static func raceRequest(
        for capture: RaceCapture, collectionID: UUID, scratch: URL
    ) throws -> (CaptureRequest, PayloadSource?) {
        switch capture.shape {
        case .inlineBytes:
            return (
                .sample(collectionId: collectionID),
                .data(CaptureFixtures.png(width: 40 + capture.index, height: 30))
            )
        case .fileBytes:
            // A provider's temporary file, which the writer COPIES into `.staging/`
            // rather than loading — the second of its two staging paths, sharing one
            // ordering and therefore owing the same guarantee.
            let file = scratch.appendingPathComponent(
                "\(capture.index).png", isDirectory: false)
            try CaptureFixtures.png(width: 40 + capture.index, height: 30).write(to: file)
            return (.sample(collectionId: collectionID), .fileURL(file))
        case .mediaLess:
            return (
                .sampleContent(
                    kind: "link",
                    payload: AssetPayload(
                        link: LinkPayload(
                            url: "https://ex.com/race/\(capture.index)",
                            title: "R\(capture.index)")),
                    collectionId: collectionID),
                nil
            )
        }
    }

    /// The claim `InboxWriter`'s header makes, run rather than argued: a writer and a
    /// drain with no lock between them, going at the same inbox at the same time,
    /// cannot between them lose a capture, ingest one twice, or turn one into a
    /// quarantined file.
    ///
    /// **Every assertion is an invariant, never a sequence and never a schedule.**
    /// How many captures a given pass ingested, how many passes ran, which task got
    /// there first — none of that is asserted anywhere, because all of it is a fact
    /// about one machine on one afternoon. What is asserted holds at every possible
    /// interleaving: the counts that must be zero are zero, the total that must be
    /// `plan.count` is, and the set of captures in the library is the set that was
    /// written. There is no `sleep`, no deadline, no wall clock and no retry-until-
    /// green anywhere in it; the writer finishing is what ends the race, and the
    /// final accounting happens when nothing is running.
    ///
    /// **`round` is read by nothing.** It exists so the race runs four times in one
    /// execution with four different interleavings, which is the only way a test of
    /// this shape gets any coverage of the schedule space at all.
    ///
    /// **What this does NOT prove**, and the distance matters. It is two tasks in one
    /// process against one filesystem — not an extension and an app, which is what
    /// ships. There is no jetsam here, no data-protection class, no App Group
    /// container, and no second address space; what is genuinely exercised is that
    /// `rename(2)` within a volume publishes a file whole and in order, and that the
    /// drain's reaction to what that produces is correct. iOS's own ordering
    /// guarantees are not what this runs.
    @Test(
        "a live writer and a live drain never lose, duplicate or corrupt a capture",
        arguments: 1 ... 4)
    func writerAndDrainRaceHoldsTheInvariant(round: Int) async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = inbox(env)
        let racingDrain = drain(env)

        // The provider's temporary files for the `.fileURL` shape. Outside the
        // library root, because a scratch file inside it is a thing a later reader
        // has to rule out of every count below.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("InboxRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let plan = Self.racePlan()
        let log = RaceLog()

        async let writing: Void = Self.runRaceWriter(
            plan, libraryRoot: env.root, collectionID: env.collectionID,
            scratch: scratch, log: log)
        async let observing: RaceObservations = Self.runRaceDrain(
            racingDrain, services: env.services, collectionID: env.collectionID,
            layout: layout, log: log)

        try await writing
        let observed = await observing

        // Nothing is running now — the writer returned and the drain loop saw it
        // finish — so one last pass takes whatever the race left in the inbox, and
        // from here the accounting is arithmetic rather than a race.
        let final = await drain(env).drainOnce()

        // 1. Nothing is corrupt. A quarantine would mean the drain read a
        //    half-written record as MALFORMED; a retry would mean it read one as
        //    FAILED rather than as early. The atomic moves exist to make both
        //    unreachable, so neither is a matter of timing: there is no interleaving
        //    of these two tasks that is allowed to produce either.
        #expect(observed.quarantined == 0)
        #expect(observed.retrying == 0)
        #expect(observed.unreadable == 0)
        #expect(final.quarantined == 0 && final.retrying == 0)
        #expect(!exists(layout.failed))

        // 2. Nothing was ever seen HALF-COMMITTED, which is the ordering claim
        //    itself. `skippedIncomplete` counts records the drain found without their
        //    payload — the state the writer's phase order says it cannot leave behind
        //    except by dying between the two, which nothing here does. Hundreds of
        //    enumerations per round land inside a live write and not one of them may
        //    see it. It is also the assertion that bites: reversing the writer's two
        //    phases fails this line, in all four rounds, and nothing else in the test
        //    notices.
        #expect(observed.skippedIncomplete == 0)

        // 3. Nothing was lost at any moment DURING the race: every capture the
        //    writer had committed was in the inbox or in the library each time the
        //    question was asked, mid-flight.
        #expect(
            observed.violations.isEmpty,
            "captures in neither place: \(observed.violations)")

        // 4. Nothing was lost or duplicated in the end. How many captures any ONE
        //    pass ingested is timing-dependent and is asserted nowhere; the sum over
        //    every pass is not, because each capture ingests exactly once. Anything
        //    but `plan.count` is a capture the race dropped or one it ran twice.
        #expect(observed.ingested + final.ingested == plan.count)

        // And the library agrees, by identity rather than by count: `capturedAt` is
        // distinct per capture and survives into `source.capturedAt`, so this is the
        // set of captures that arrived, not merely how many did.
        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == plan.count)
        #expect(Set(items.map(\.source.capturedAt)) == Set(plan.map(\.capturedAt)))
        #expect(env.blobFiles().count == plan.filter { $0.shape != .mediaLess }.count)

        // 5. And the inbox is empty of everything the race put in it: no record, no
        //    orphaned sidecar, nothing left behind in `.staging/`.
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: layout.directory, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent) == [InboxLayout.stagingDirectoryName])
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: layout.staging, includingPropertiesForKeys: nil).isEmpty)
    }

    /// The producer half: every capture in `plan` through the real ``InboxWriter``,
    /// into an inbox a real ``InboxDrain`` is passing over the whole time.
    ///
    /// `Task.yield()` between captures is not a delay and nothing is asserted about
    /// what it achieves. It is the one line that gives the drain task a chance at the
    /// CPU between two writes on a machine that would otherwise run them back to
    /// back; the test is correct with or without it, and interleaves far more with.
    private static func runRaceWriter(
        _ plan: [RaceCapture], libraryRoot: URL, collectionID: UUID,
        scratch: URL, log: RaceLog
    ) async throws {
        // The drain loop ends when the log says the producer has stopped producing,
        // so that has to happen on EVERY exit from here — a throw included, which
        // would otherwise hang the race instead of failing it.
        defer { log.finish() }

        let writer = InboxWriter(libraryRoot: libraryRoot)
        for capture in plan {
            let (request, payload) = try raceRequest(
                for: capture, collectionID: collectionID, scratch: scratch)
            try writer.write(
                request, payload: payload,
                id: capture.id, capturedAt: capture.capturedAt)
            // Logged only after the write RETURNS, so the log never claims a record
            // the writer has not committed: a capture still between its two phases is
            // legitimately in neither the inbox nor the library, and asking the
            // invariant of it would be asking the wrong question.
            log.commit(capture)
            await Task.yield()
        }
    }

    /// The consumer half: pass after pass over the same inbox for as long as the
    /// writer is writing, with the mid-flight invariant asked after every pass that
    /// actually ingested something.
    ///
    /// **What ends this loop is the producer stopping, and nothing else** — no
    /// timeout, no deadline, no clock, and no expected number of passes. The writer
    /// always reaches ``RaceLog/finish()`` (it is a `defer`), so the loop always
    /// terminates; how many times it goes round is whatever the two tasks happen to
    /// do to each other on the day, which is exactly the quantity nothing here is
    /// allowed to assert.
    ///
    /// It is a tight loop on purpose. The window the two-phase write exists to close
    /// is the microseconds between a payload landing and its record landing, and the
    /// only way a test opens that window is by enumerating the inbox far more often
    /// than the writer commits to it. Each turn does the real ``InboxDrain/drainOnce()``
    /// — a directory read and, when there is anything there, a real ingest — so a turn
    /// that finds nothing costs one `contentsOfDirectory` and yields.
    private static func runRaceDrain(
        _ drain: InboxDrain, services: AppServices, collectionID: UUID,
        layout: InboxLayout, log: RaceLog
    ) async -> RaceObservations {
        var observed = RaceObservations()
        while !log.isFinished {
            observed.record(await drain.drainOnce())
            // Only after a pass that moved something. A pass that ingested nothing
            // changed nothing the invariant could have broken, and the check is two
            // real reads of a real library rather than a cheap assertion.
            if observed.lastPassIngested {
                observed.violations += await Self.unaccountedFor(
                    log: log, layout: layout,
                    services: services, collectionID: collectionID)
            }
            await Task.yield()
        }
        return observed
    }

    /// The captures that are in NEITHER the inbox nor the library — empty whenever
    /// the handoff is holding.
    ///
    /// **The two reads are ordered, and the order is what makes the answer sound.**
    /// The drain deletes a record only AFTER the ingest transaction has committed, so
    /// a record found missing at the first read had its asset in the library before
    /// that read, and the second read is therefore guaranteed to see it. Reading the
    /// library first would invert exactly that and manufacture a failure out of a
    /// capture that ingested between the two — a timing dependence, in the one place
    /// this test could plausibly have acquired one.
    ///
    /// Identity is `capturedAt` on the library side because that is the only field
    /// that survives the crossing: the record's id is not the asset's id, and the
    /// asset's provenance is shared by every byte-backed capture here. Each capture
    /// is written with its own whole-second timestamp, so the match is exact and
    /// cannot alias.
    private static func unaccountedFor(
        log: RaceLog, layout: InboxLayout, services: AppServices, collectionID: UUID
    ) async -> [String] {
        let committed = log.snapshot
        guard let pending = try? layout.pendingRecordURLs() else {
            return ["the inbox could not be enumerated mid-race"]
        }
        let inInbox = Set(pending.map(\.lastPathComponent))
        let items = try? await services.collectionItems(
            in: collectionID, includeArchived: false)
        let inLibrary = Set((items ?? []).map(\.source.capturedAt))

        return committed
            .filter {
                !inInbox.contains(InboxLayout.recordFileName(for: $0.id))
                    && !inLibrary.contains($0.capturedAt)
            }
            .map { "\($0.id) (captured \($0.capturedAt))" }
    }
}

// MARK: - Standing inside a running pass

/// Records what a pass actually ingested, in the order the ingests happened, and
/// lets a test act at the moment the first one lands.
///
/// The seam is `IngestPipeline`'s existing `timing` sink — emitted once per
/// successful byte ingest, from inside the ingest, carrying the content hash. That
/// makes it the one place a test can stand in the middle of a pass without the drain
/// or the coordinator knowing anything about tests.
///
/// `@unchecked Sendable` over an `NSLock` rather than an actor: the sink is a
/// synchronous `@Sendable` closure called from the pipeline's own task, and it cannot
/// await.
private final class IngestWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes: [String] = []
    private var firstIngest: (@Sendable () -> Void)?

    /// The content hashes of the ingests this watcher saw, in order.
    var ingestOrder: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hashes
    }

    /// Run `body` when the first ingest of the pass completes — while the pass is
    /// still running, and (at width 1) before the second record has been touched.
    func onFirstIngest(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        firstIngest = body
        lock.unlock()
    }

    /// The pipeline's timing sink.
    func observed(_ timing: IngestTiming) {
        lock.lock()
        hashes.append(timing.hash)
        let body = hashes.count == 1 ? firstIngest : nil
        lock.unlock()
        // Outside the lock: `body` may cancel a task that is about to take it again.
        body?()
    }
}

/// A one-shot boolean a synchronous, `Sendable` closure can set and a test can read.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// One record a synchronous, `Sendable` closure can read off disk and a test can look
/// at afterwards — the inbox as it stood in the middle of a pass, which is the only
/// place the write-ahead stamp is observable without killing the process.
private final class ObservedRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var value: InboxRecord?

    var recorded: InboxRecord? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ newValue: InboxRecord?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Holds the task running a pass so something inside that pass can cancel it.
///
/// The indirection exists because the handle does not exist until after the task is
/// created, and the thing that cancels it has to be installed before. Armed first,
/// released through a ``Gate`` second — so there is no ordering to get lucky about.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<DrainSummary, Never>?

    func arm(_ task: Task<DrainSummary, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

// MARK: - Running the writer against the drain

/// The three shapes a race capture takes, so that all of them are being committed
/// while the drain is running: bytes handed over in memory, bytes handed over as a
/// file the writer copies, and no bytes at all.
///
/// The three are not decoration. The first two are the writer's two staging paths —
/// `Data.write` and `copyItem` — which share one ordering and must therefore share
/// its guarantee; the third has no first phase at all, so its record is the only
/// file it ever writes.
private enum RaceShape: CaseIterable {
    case inlineBytes
    case fileBytes
    case mediaLess
}

/// One capture in the race: what the writer will commit, and the two identities it
/// is looked up by afterwards.
///
/// It is one type rather than a plan item and a separate log entry because those
/// would be the same fields twice. The two identities are both needed and neither is
/// redundant: the capture has two legitimate homes and no single field spans them —
/// the record's `id` does not become the asset's, and `capturedAt` does not survive
/// into a file name.
private struct RaceCapture: Sendable {
    /// Finds the capture in the inbox: `<id>.json`.
    let id: UUID
    /// Finds it in the library: it is written through to `source.capturedAt`, and is
    /// distinct per capture so the match cannot alias.
    let capturedAt: Date
    /// Its position in the plan — what makes its bytes, its link and its scratch
    /// file name distinct from every other capture's.
    let index: Int
    let shape: RaceShape
}

/// The one thing the two racing tasks share: what the writer has committed so far,
/// and whether it has stopped committing.
///
/// Both halves are read by the drain's task while the writer's task is still going,
/// and the second half is the drain loop's whole termination condition — which is why
/// it lives here beside the captures rather than as a second synchronisation object
/// with its own lock and its own ordering to reason about.
///
/// `@unchecked Sendable` over an `NSLock` for the same reason ``IngestWatcher`` is:
/// the writer is synchronous file I/O in one task and the reader is another, and an
/// actor would put an `await` in the middle of a write loop that has no use for one.
private final class RaceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var committed: [RaceCapture] = []
    private var finished = false

    /// Append a capture whose record is already on disk.
    func commit(_ capture: RaceCapture) {
        lock.lock()
        committed.append(capture)
        lock.unlock()
    }

    /// The producer has stopped, whether it got through the whole plan or threw.
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// Whether the producer has stopped. One-way, so a reader that sees `true` is
    /// never going to see `false` again and the drain loop cannot fail to end.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// What has been committed at this instant. Only ever grows, so a snapshot taken
    /// before the reads it is checked against is one that under-claims — which is the
    /// safe direction: a capture the log has not heard of yet is simply not asked
    /// about.
    var snapshot: [RaceCapture] {
        lock.lock()
        defer { lock.unlock() }
        return committed
    }
}

/// What one round of the race saw, tallied rather than kept: a round runs however
/// many passes it runs — tens of thousands of them, most finding an empty inbox — and
/// the array of those would be a large answer to a question with four numbers in it.
///
/// Carried out of the drain task as a value and asserted in the test body rather than
/// asserted in place, so a failure is reported against the test rather than against
/// whichever task happened to notice it.
private struct RaceObservations: Sendable {
    /// How many passes ran. Reported by nothing and asserted by nothing — see
    /// `runRaceDrain` — but a `0` here would say the race never happened.
    var passes = 0
    var ingested = 0
    var skippedIncomplete = 0
    var quarantined = 0
    var retrying = 0
    /// Passes that could not enumerate the inbox at all.
    var unreadable = 0
    /// Captures found in neither the inbox nor the library, mid-race. Empty is the
    /// only passing value.
    var violations: [String] = []

    /// Whether the pass just recorded put anything in the library — the trigger for
    /// the mid-flight accounting, which is too expensive to run on a pass that
    /// changed nothing.
    private(set) var lastPassIngested = false

    mutating func record(_ summary: DrainSummary) {
        passes += 1
        ingested += summary.ingested
        skippedIncomplete += summary.skippedIncomplete
        quarantined += summary.quarantined
        retrying += summary.retrying
        if summary.inboxUnreadable { unreadable += 1 }
        lastPassIngested = summary.ingested > 0
    }
}

