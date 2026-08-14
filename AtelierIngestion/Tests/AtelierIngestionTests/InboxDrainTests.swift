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
}
