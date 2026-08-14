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

    private func drain(_ env: TempPipeline) -> InboxDrain {
        InboxDrain(libraryRoot: env.root, coordinator: env.coordinator)
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
            coordinator: IngestCoordinator(pipeline: pipeline, maxConcurrent: width))
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
        var pass = InboxDrain.Pass()
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
        var pass = InboxDrain.Pass()
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
        await gate.open()
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

/// A latch a task can park on until a test opens it. `wait()` ignores cancellation on
/// purpose: it is what holds a task at the starting line WHILE it is being cancelled.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }
}
