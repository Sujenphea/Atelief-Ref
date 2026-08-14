// AtelierCapture tests — the inbox handoff, both sides of it (092 · S2).
//
// The writer's contract is an ORDERING, and an ordering is only a contract if
// something asserts it. Three of these tests exist for that alone: staging is empty
// when a write returns, a listed record always has its payload, and a payload that
// fails to land leaves no record behind. The last one is the direct proof — if the
// `.json` were written first, a failed `.bin` would leave a record the drain would
// pick up and fail, which is exactly the share-vanishes bug the two phases prevent.
//
// The rest is the matrix 092 asked for: bytes present, bytes absent (each media-less
// kind), a partial write detected as incomplete rather than corrupt, and every typed
// failure. All of it runs under `swift test` on macOS, with no iOS target and no
// device, because the writer is Foundation-only by design.

import Foundation
import Testing

import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore

@Suite("InboxWriter (092 S2)")
struct InboxWriterTests {
    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// A fresh throwaway Library root. Nothing under it exists yet — the writer
    /// creating the inbox on first use is part of what is under test.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InboxWriterTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func readRecord(at url: URL) throws -> InboxRecord {
        try InboxRecord.makeDecoder().decode(InboxRecord.self, from: Data(contentsOf: url))
    }

    // MARK: - Round trip

    @Test("a capture with bytes lands as a record plus its sidecar, and decodes back equal")
    func roundTripWithBytes() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        let bytes = CaptureFixtures.png()

        let record = try InboxWriter(libraryRoot: root).write(
            .sample(), payload: bytes, id: id, capturedAt: Self.capturedAt)

        #expect(layout.directory == root.appendingPathComponent("inbox", isDirectory: true))
        #expect(record.id == id)
        #expect(record.capturedAt == Self.capturedAt)
        #expect(record.payloadFile == "\(id.uuidString).bin")

        #expect(exists(layout.payloadURL(for: id)))
        #expect(try Data(contentsOf: layout.payloadURL(for: id)) == bytes)
        #expect(exists(layout.recordURL(for: id)))
        #expect(try readRecord(at: layout.recordURL(for: id)) == record)
    }

    @Test("the base64 image field is dropped when the same bytes went to the sidecar")
    func inlineImageIsNotCarriedTwice() throws {
        let root = try makeRoot()
        let id = UUID()

        // `.sample()` carries a base64 PNG — the HTTP producer's shape. On this path
        // the bytes are a file, and holding both would defeat the sidecar (092 · S2).
        let request = CaptureRequest.sample()
        #expect(request.image != nil)

        let record = try InboxWriter(libraryRoot: root).write(
            request, payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        #expect(record.request.image == nil)
        #expect(record.request.provenance == request.provenance)
        let onDisk = try readRecord(at: InboxLayout(libraryRoot: root).recordURL(for: id))
        #expect(onDisk.request.image == nil)
    }

    @Test(
        "a media-less capture writes no sidecar",
        arguments: ["tweet", "link", "color"])
    func mediaLessCaptureHasNoPayload(kind: String) throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()

        let record = try InboxWriter(libraryRoot: root).write(
            .sampleContent(kind: kind), id: id, capturedAt: Self.capturedAt)

        #expect(record.payloadFile == nil)
        #expect(record.request.kind == kind)
        #expect(!exists(layout.payloadURL(for: id)))
        #expect(exists(layout.recordURL(for: id)))
        // Nothing to wait for, so a media-less record is complete on sight.
        #expect(layout.isComplete(record))
        #expect(layout.payloadURL(for: record) == nil)
    }

    // MARK: - The ordering invariant

    @Test("a successful write leaves nothing staged")
    func stagingIsEmptyWhenTheWriteReturns() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let writer = InboxWriter(libraryRoot: root)

        try writer.write(.sample(), payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)
        try writer.write(.sampleContent(), capturedAt: Self.capturedAt)

        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    @Test("the drain's enumeration never sees a staged file")
    func stagingIsInvisibleToTheDrain() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let record = try InboxWriter(libraryRoot: root).write(
            .sampleContent(), capturedAt: Self.capturedAt)

        // A record caught mid-write, sitting where the writer stages. The top-level
        // `*.json` enumeration is what makes it invisible — this is the property the
        // whole two-phase design rests on.
        try Data("{}".utf8).write(to: layout.stagedRecordURL(for: UUID()))

        // Compared by file name: `contentsOfDirectory` hands back symlink-resolved
        // URLs (`/private/var/…` for a temp directory), so the URLs are equal paths
        // and unequal values.
        let pending = try layout.pendingRecordURLs()
        #expect(pending.map(\.lastPathComponent) == ["\(record.id.uuidString).json"])
    }

    @Test("every record the drain can see already has its payload")
    func aListedRecordAlwaysHasItsPayload() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let writer = InboxWriter(libraryRoot: root)

        for _ in 0..<3 {
            try writer.write(.sample(), payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)
            try writer.write(.sampleContent(), capturedAt: Self.capturedAt)
        }

        let pending = try layout.pendingRecordURLs()
        #expect(pending.count == 6)
        for url in pending {
            let record = try readRecord(at: url)
            #expect(layout.isComplete(record))
        }
    }

    // MARK: - Re-committing a record in place (092 · S3)

    @Test("a rewrite replaces the record, keeps the payload, and stages nothing")
    func rewriteReplacesInPlace() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let writer = InboxWriter(libraryRoot: root)
        let id = UUID()
        let bytes = CaptureFixtures.png()

        var record = try writer.write(
            .sample(), payload: bytes, id: id, capturedAt: Self.capturedAt)

        // The drain's one write: an attempt count, and nothing else (092 · S3).
        record.attempts = 2
        try writer.rewrite(record)

        #expect(try readRecord(at: layout.recordURL(for: id)) == record)
        // The capture itself is untouched — only the counter beside it moved.
        #expect(try Data(contentsOf: layout.payloadURL(for: id)) == bytes)
        // Exactly one record, not a second one alongside the old.
        #expect(try layout.pendingRecordURLs().count == 1)
        // Same staging discipline as a first write: a torn re-commit would turn a
        // retryable failure into a record the drain reads as corrupt.
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    @Test("a payload that fails to land leaves no record behind")
    func aFailedPayloadNeverProducesARecord() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        // Occupy the payload's destination so the commit move fails.
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        try Data("squatter".utf8).write(to: layout.payloadURL(for: id))

        #expect(throws: InboxWriteError.payloadWriteFailed(path: layout.payloadURL(for: id).path)) {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }

        // The proof that `.bin` precedes `.json`: had the record been written first,
        // it would be sitting here now, naming a payload that is not the capture's.
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(!exists(layout.recordURL(for: id)))
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    // MARK: - Partial writes

    @Test("a record naming a payload that is not there reads as incomplete, not corrupt")
    func aMissingPayloadIsDetectableAsIncomplete() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        try InboxWriter(libraryRoot: root).write(
            .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        // The torn state a crash between the two phases would leave — or, here, the
        // one the drain would see if it looked between them.
        try FileManager.default.removeItem(at: layout.payloadURL(for: id))

        let record = try readRecord(at: layout.recordURL(for: id))
        #expect(!layout.isComplete(record))
        // Still listed: S3 skips it this pass rather than failing it, so it must
        // remain enumerable.
        #expect(try layout.pendingRecordURLs().map(\.lastPathComponent)
            == ["\(id.uuidString).json"])
    }

    @Test("a payloadFile that is not a plain file name resolves to nothing")
    func payloadNamesCannotEscapeTheInbox() throws {
        let layout = InboxLayout(libraryRoot: URL(fileURLWithPath: "/tmp/library"))

        #expect(layout.payloadURL(named: "../../etc/passwd") == nil)
        #expect(layout.payloadURL(named: "nested/a.bin") == nil)
        #expect(layout.payloadURL(named: "..") == nil)
        #expect(layout.payloadURL(named: "") == nil)
        #expect(layout.payloadURL(named: "a.bin")?.lastPathComponent == "a.bin")

        var record = InboxRecord(
            capturedAt: Self.capturedAt, request: .sampleContent(), payloadFile: "../a.bin")
        #expect(!layout.isComplete(record))
        record.payloadFile = nil
        #expect(layout.isComplete(record))
    }

    // MARK: - attempts

    @Test("attempts starts at zero")
    func attemptsStartsAtZero() throws {
        let root = try makeRoot()
        let id = UUID()
        let record = try InboxWriter(libraryRoot: root).write(
            .sampleContent(), id: id, capturedAt: Self.capturedAt)

        #expect(record.attempts == 0)
        #expect(try readRecord(at: InboxLayout(libraryRoot: root).recordURL(for: id)).attempts == 0)
    }

    @Test("a record written before the counter existed decodes to zero attempts")
    func missingAttemptsDecodesToZero() throws {
        let record = InboxRecord(
            capturedAt: Self.capturedAt, request: .sampleContent(), payloadFile: nil)
        let encoded = try InboxRecord.makeEncoder().encode(record)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["attempts"] != nil)
        object.removeValue(forKey: "attempts")

        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try InboxRecord.makeDecoder().decode(InboxRecord.self, from: trimmed)

        #expect(decoded.attempts == 0)
        #expect(decoded == record)
    }

    // MARK: - Typed failures

    @Test("the inbox directory cannot be created")
    func inboxCannotBeCreated() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        // A file where the directory has to go — the shape a corrupted container takes
        // that a test can actually produce.
        try Data("not a directory".utf8).write(to: layout.directory)

        #expect(throws: InboxWriteError.inboxUnavailable(path: layout.directory.path)) {
            try InboxWriter(libraryRoot: root).write(
                .sampleContent(), capturedAt: Self.capturedAt)
        }
    }

    @Test("the payload cannot be staged")
    func payloadCannotBeStaged() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        try FileManager.default.createDirectory(
            at: layout.staging, withIntermediateDirectories: true)
        // A directory occupying the staged path: the write cannot replace it.
        try FileManager.default.createDirectory(
            at: layout.stagedPayloadURL(for: id), withIntermediateDirectories: true)

        #expect(throws: InboxWriteError.payloadWriteFailed(path: layout.payloadURL(for: id).path)) {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }
        #expect(!exists(layout.recordURL(for: id)))
    }

    @Test("the record cannot be encoded")
    func recordCannotBeEncoded() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        // `rawMetadata` is a lossless JSON carrier, so it can carry a Double that JSON
        // cannot represent. The only realistic way to fail this encode.
        let request = CaptureRequest(
            provenance: ProvenanceDTO(
                platform: "twitter", rawMetadata: .object(["ratio": .number(.infinity)])))

        #expect(throws: InboxWriteError.recordEncodingFailed(id: id)) {
            try InboxWriter(libraryRoot: root).write(
                request, payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }
        // The payload committed in phase 1 is taken back down: no orphan bytes, and
        // certainly no record.
        #expect(!exists(layout.payloadURL(for: id)))
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    @Test("the record cannot be moved into place")
    func recordCannotBeCommitted() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        // Occupy the record's destination so the commit move fails.
        try Data("squatter".utf8).write(to: layout.recordURL(for: id))

        #expect(throws: InboxWriteError.recordWriteFailed(path: layout.recordURL(for: id).path)) {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }
        #expect(!exists(layout.payloadURL(for: id)))
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }
}
