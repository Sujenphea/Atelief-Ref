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

    /// The write that had to fail, as the error it threw.
    ///
    /// The four typed failures are asserted through this rather than by comparing whole
    /// `InboxWriteError` values, because every case now carries an `underlying` built
    /// from `localizedDescription` — a system string that varies with locale and OS
    /// version and is nobody's contract. What a test may pin is the case and its path
    /// (``InboxWriteError/shape``); what it may only pin the PRESENCE of is the reason
    /// (``InboxWriteError/underlying``).
    private func failure(
        of operation: () throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> InboxWriteError {
        try #require(
            #expect(
                throws: InboxWriteError.self,
                sourceLocation: sourceLocation,
                performing: operation),
            sourceLocation: sourceLocation)
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

    // MARK: - A payload that is a file (406)
    //
    // The entry point the share extension takes. A provider's temporary file reaches
    // `.staging/` by `copyItem` and is never loaded, so the extension's peak footprint
    // stops being "one whole image" — which was the finding. What these assert is that
    // the file path lands EXACTLY where the `Data` path does: the same two files, the
    // same empty staging, the same bytes.

    /// A file of `count` bytes on disk. Written, not sparse — these are the payloads
    /// that are meant to succeed, so their bytes have to be real and comparable.
    private func makeFile(_ root: URL, named name: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    @Test("a file payload lands as the same two files the Data path produces")
    func fileSourceRoundTrip() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        let bytes = CaptureFixtures.png()
        let source = try makeFile(root, named: "shared.png", bytes: bytes)

        let record = try InboxWriter(libraryRoot: root).write(
            .sample(), payload: .fileURL(source), id: id, capturedAt: Self.capturedAt)

        #expect(record.payloadFile == "\(id.uuidString).bin")
        #expect(exists(layout.payloadURL(for: id)))
        #expect(exists(layout.recordURL(for: id)))
        #expect(try readRecord(at: layout.recordURL(for: id)) == record)
        // Byte-identical to the source, which is the whole claim: nothing decoded,
        // re-encoded or truncated on the way through.
        #expect(try Data(contentsOf: layout.payloadURL(for: id)) == bytes)
        // A copy, never a move — the provider's file may be storage another process
        // owns, and moving it would be reaching into it.
        #expect(exists(source))
        #expect(try Data(contentsOf: source) == bytes)
        // The same ordering discipline, and the same clean staging.
        #expect(layout.isComplete(record))
        #expect(record.request.image == nil)
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    @Test("the two payload shapes are interchangeable — same bytes in, same sidecar out")
    func fileAndDataPathsAgree() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let bytes = CaptureFixtures.png()
        let writer = InboxWriter(libraryRoot: root)
        let source = try makeFile(root, named: "shared.png", bytes: bytes)

        let fromData = try writer.write(.sample(), payload: bytes, capturedAt: Self.capturedAt)
        let fromFile = try writer.write(
            .sample(), payload: .fileURL(source), capturedAt: Self.capturedAt)

        let a = try Data(contentsOf: #require(layout.payloadURL(for: fromData)))
        let b = try Data(contentsOf: #require(layout.payloadURL(for: fromFile)))
        #expect(a == b)
        #expect(a == bytes)
        #expect(try layout.pendingRecordURLs().count == 2)
    }

    @Test("a file payload that is not there fails as a write, not as a size problem")
    func missingFileSourceFails() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        let missing = root.appendingPathComponent("gone.png", isDirectory: false)

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: .fileURL(missing), id: id, capturedAt: Self.capturedAt)
        }
        // `payloadSize` cannot stat it, and that is deliberately not a refusal: the
        // copy's own failure carries what the filesystem actually said.
        #expect(error.shape == .payloadWriteFailed(path: layout.payloadURL(for: id).path))
        #expect(!error.underlying.isEmpty)
        #expect(try layout.pendingRecordURLs().isEmpty)
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    // MARK: - The cap (406)
    //
    // Without one, a very large share gets the extension jetsammed mid-write and the
    // user sees a share sheet that silently did nothing — 091 · D2's named failure, and
    // the worst one because it is indistinguishable from success. These assert the
    // refusal is typed, is checked BEFORE anything is copied, and leaves nothing behind.

    /// A file that *reports* `count` bytes without occupying them. `truncate` makes it
    /// sparse on APFS, so a 64 MiB refusal costs the test suite no disk and no wait.
    private func makeSparseFile(_ root: URL, named name: String, count: Int) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(count))
        try handle.close()
        return url
    }

    @Test("a file one byte over the cap is refused, and nothing is copied")
    func overCapFileIsRefused() throws {
        let root = try makeRoot()
        // A sparse 64 MiB file costs no disk, but a copy of one may materialise; this
        // is the only place in the suite that leaves anything worth removing.
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        let limit = InboxWriter.maximumPayloadBytes
        let source = try makeSparseFile(root, named: "huge.bin", count: limit + 1)
        #expect(InboxWriter.payloadSize(of: .fileURL(source)) == limit + 1)

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: .fileURL(source), id: id, capturedAt: Self.capturedAt)
        }
        #expect(error.shape == .payloadTooLarge(bytes: limit + 1, limit: limit))
        // The one case with nothing caught, so nothing to quote.
        #expect(error.underlying.isEmpty)

        // Nothing in the inbox, nothing staged, and the source untouched.
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(!exists(layout.payloadURL(for: id)))
        #expect(!exists(layout.recordURL(for: id)))
        #expect(!exists(layout.staging.appendingPathComponent("\(id.uuidString).bin")))
        #expect(exists(source))
    }

    @Test("a file exactly at the cap is accepted — the boundary is inclusive")
    func atCapFileIsAccepted() throws {
        let root = try makeRoot()
        // A sparse 64 MiB file costs no disk, but a copy of one may materialise; this
        // is the only place in the suite that leaves anything worth removing.
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        // Sparse, so this writes a 64 MiB sidecar without occupying 64 MiB: what is
        // under test is the comparison, not the copy.
        let source = try makeSparseFile(
            root, named: "exact.bin", count: InboxWriter.maximumPayloadBytes)

        let record = try InboxWriter(libraryRoot: root).write(
            .sample(), payload: .fileURL(source), id: id, capturedAt: Self.capturedAt)

        #expect(record.payloadFile == "\(id.uuidString).bin")
        #expect(layout.isComplete(record))
        #expect(
            InboxWriter.payloadSize(of: .fileURL(layout.payloadURL(for: id)))
                == InboxWriter.maximumPayloadBytes)
    }

    @Test("the Data fallback is capped too, by the same constant")
    func overCapDataIsRefused() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        let limit = InboxWriter.maximumPayloadBytes
        // The honest limitation of this path, stated in the assertion: by the time a
        // `Data` exists the bytes are already resident, so the cap can only refuse to
        // WRITE them. That is why the extension prefers a file representation.
        let payload = Data(count: limit + 1)

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: payload, id: id, capturedAt: Self.capturedAt)
        }
        #expect(error.shape == .payloadTooLarge(bytes: limit + 1, limit: limit))
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(!exists(layout.payloadURL(for: id)))
    }

    @Test("the cap is a size, measured the same way for both shapes")
    func payloadSizeIsMeasuredNotGuessed() throws {
        let root = try makeRoot()
        let bytes = CaptureFixtures.png()
        let source = try makeFile(root, named: "shared.png", bytes: bytes)

        #expect(InboxWriter.payloadSize(of: .data(bytes)) == bytes.count)
        #expect(InboxWriter.payloadSize(of: .fileURL(source)) == bytes.count)
        #expect(InboxWriter.payloadSize(of: .data(Data())) == 0)
        // Unknowable rather than zero: a file that cannot be stat'd is not an empty
        // file, and reporting zero would sail it straight past the cap.
        #expect(
            InboxWriter.payloadSize(of: .fileURL(root.appendingPathComponent("gone"))) == nil)
        // The constant itself is the tunable, and it is one number.
        #expect(InboxWriter.maximumPayloadBytes == 64 * 1024 * 1024)
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

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }
        #expect(error.shape == .payloadWriteFailed(path: layout.payloadURL(for: id).path))
        #expect(!error.underlying.isEmpty)

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

    // MARK: - A record may only name its own sidecar (403)
    //
    // "Cannot escape the inbox" is a weaker property than it sounds: `<other>.json` is
    // a plain component sitting right there beside the record. A record naming one used
    // to resolve, ingest as media, and then be DELETED by the success path or moved to
    // `failed/` by the failure path — a malformed capture destroying a healthy one. The
    // name is now checked against the id that supplied it.

    @Test("a payloadFile naming another record's files resolves to nothing")
    func aRecordCannotNameASiblingsFiles() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)

        // A real, healthy capture: both its `.json` and its `.bin` are on disk, so the
        // refusals below are refusals of names that DO resolve to something.
        let sibling = try InboxWriter(libraryRoot: root).write(
            .sample(), payload: CaptureFixtures.png(), capturedAt: Self.capturedAt)
        #expect(exists(layout.recordURL(for: sibling.id)))
        #expect(exists(layout.payloadURL(for: sibling.id)))

        let id = UUID()
        var record = InboxRecord(
            id: id, capturedAt: Self.capturedAt, request: .sampleContent(),
            payloadFile: InboxLayout.recordFileName(for: sibling.id))
        #expect(layout.payloadURL(for: record) == nil)
        // Not "early" either — the file is right there. It is refused, and the drain
        // reads that as malformed rather than as not-yet-written.
        #expect(!layout.isComplete(record))

        record.payloadFile = InboxLayout.payloadFileName(for: sibling.id)
        #expect(layout.payloadURL(for: record) == nil)
        #expect(!layout.isComplete(record))

        // Its own name, which is the only one that ever resolves.
        record.payloadFile = InboxLayout.payloadFileName(for: id)
        #expect(layout.payloadURL(for: record) == layout.payloadURL(for: id))
    }

    @Test(
        "a payloadFile naming one of the inbox's own directories resolves to nothing",
        arguments: [InboxLayout.stagingDirectoryName, InboxLayout.failedDirectoryName])
    func aRecordCannotNameTheInboxsDirectories(name: String) throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        // Both directories exist, and both are plain components — the old guard let
        // them through, and a drain that resolved one would have moved or deleted a
        // DIRECTORY of captures.
        try FileManager.default.createDirectory(at: layout.staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.failed, withIntermediateDirectories: true)

        let record = InboxRecord(
            capturedAt: Self.capturedAt, request: .sampleContent(), payloadFile: name)
        #expect(layout.payloadURL(for: record) == nil)
        #expect(!layout.isComplete(record))
    }

    @Test("a record written by the writer resolves and is complete, as it always was")
    func theCanonicalNameStillResolves() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        let id = UUID()
        let record = try InboxWriter(libraryRoot: root).write(
            .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)

        #expect(record.payloadFile == InboxLayout.payloadFileName(for: id))
        #expect(layout.payloadURL(for: record) == layout.payloadURL(for: id))
        #expect(layout.isComplete(record))
    }

    // MARK: - Quarantine destinations

    @Test("failedRecordURL composes into failed/, beside the payload's destination")
    func failedRecordURLComposes() {
        let layout = InboxLayout(libraryRoot: URL(fileURLWithPath: "/tmp/library"))
        let id = UUID()

        #expect(
            layout.failedRecordURL(for: id).path
                == "/tmp/library/inbox/failed/\(id.uuidString).json")
        // The same stem the guarded `failedURL(named:)` produces for the sidecar: the
        // two halves of a quarantined capture land together, composed in one place.
        #expect(
            layout.failedURL(named: InboxLayout.payloadFileName(for: id))?.path
                == "/tmp/library/inbox/failed/\(id.uuidString).bin")
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

    // MARK: - Typed failures, and why each one happened
    //
    // Each of the four asserts the same two things: the case and its path, which are
    // the contract, and that `underlying` is populated, which is all a test can say
    // about a message the system wrote. In the extension that field is the whole
    // difference between "a share was lost" and "a share was lost because the volume
    // is full" — there is no debugger behind the share sheet (403).

    @Test("the inbox directory cannot be created")
    func inboxCannotBeCreated() throws {
        let root = try makeRoot()
        let layout = InboxLayout(libraryRoot: root)
        // A file where the directory has to go — the shape a corrupted container takes
        // that a test can actually produce.
        try Data("not a directory".utf8).write(to: layout.directory)

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                .sampleContent(), capturedAt: Self.capturedAt)
        }
        #expect(error.shape == .inboxUnavailable(path: layout.directory.path))
        #expect(!error.underlying.isEmpty)
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

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }
        #expect(error.shape == .payloadWriteFailed(path: layout.payloadURL(for: id).path))
        #expect(!error.underlying.isEmpty)
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

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                request, payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }
        #expect(error.shape == .recordEncodingFailed(id: id))
        #expect(!error.underlying.isEmpty)
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

        let error = try failure {
            try InboxWriter(libraryRoot: root).write(
                .sample(), payload: CaptureFixtures.png(), id: id, capturedAt: Self.capturedAt)
        }
        #expect(error.shape == .recordWriteFailed(path: layout.recordURL(for: id).path))
        #expect(!error.underlying.isEmpty)
        #expect(!exists(layout.payloadURL(for: id)))
        let staged = try FileManager.default.contentsOfDirectory(
            at: layout.staging, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }
}

/// An `InboxWriteError` split into the half a test may pin and the half it may not
/// (403).
extension InboxWriteError {
    /// The case and the payload that IS a contract — everything but `underlying`.
    enum Shape: Equatable {
        case inboxUnavailable(path: String)
        case payloadWriteFailed(path: String)
        case recordEncodingFailed(id: UUID)
        case recordWriteFailed(path: String)
        /// The whole case is a contract — nothing in it is a system string — so this
        /// one is its own shape rather than a shape minus something (406).
        case payloadTooLarge(bytes: Int, limit: Int)
    }

    var shape: Shape {
        switch self {
        case .inboxUnavailable(let path, _): .inboxUnavailable(path: path)
        case .payloadWriteFailed(let path, _): .payloadWriteFailed(path: path)
        case .recordEncodingFailed(let id, _): .recordEncodingFailed(id: id)
        case .recordWriteFailed(let path, _): .recordWriteFailed(path: path)
        case .payloadTooLarge(let bytes, let limit): .payloadTooLarge(bytes: bytes, limit: limit)
        }
    }

    /// What the writer caught, from whichever case is carrying it. Asserted non-empty
    /// and never asserted equal: the text is `localizedDescription`'s, not ours.
    ///
    /// `payloadTooLarge` caught nothing — the writer decided it — so it has no
    /// `underlying` to expose and yields `""`. A test asserting non-empty on that case
    /// would be asserting that the writer invented a sentence.
    var underlying: String {
        switch self {
        case .inboxUnavailable(_, let underlying), .payloadWriteFailed(_, let underlying),
            .recordEncodingFailed(_, let underlying), .recordWriteFailed(_, let underlying):
            underlying
        case .payloadTooLarge: ""
        }
    }
}
