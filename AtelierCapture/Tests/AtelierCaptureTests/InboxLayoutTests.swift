// AtelierCapture — the shape of the inbox itself (096 · 4).
//
// `InboxLayout` is mostly path arithmetic, and path arithmetic is mostly proved by the
// suites that use it — `InboxWriterTests` commits records through it, `InboxDrainTests`
// drains them, `InboxRetirementTests` retires them. What those suites cannot prove is the
// property the whole design rests on: that a directory added beside `.staging/`, `failed/`
// and `sent/` is INVISIBLE to the enumeration the drain walks.
//
// That invisibility is stated as an argument in prose — the enumeration takes top-level
// `*.json` and a directory has no extension — and it has now been relied on four times. An
// argument relied on four times deserves a test, because the day someone reaches for
// `enumerator(at:)` or drops `.skipsSubdirectoryDescendants` nothing else in the program
// would notice until a phone re-ingested every capture it had ever made.
//
// The fixtures are built with the REAL `InboxWriter` for the reason every suite here gives:
// hand-rolling the on-disk shape lets the two sides of a contract drift while both stay
// green.

import Foundation
import Testing

@testable import AtelierCapture
import AtelierCaptureTestSupport

@Suite("InboxLayout: what the inbox's enumerations can and cannot see (096 4)")
struct InboxLayoutTests {

    /// A throwaway inbox, cleaned up by the caller's `defer`.
    static func makeLayout() throws -> InboxLayout {
        try InboxFixtures.makeLayout(suite: "InboxLayoutTests")
    }

    static func request(_ platform: String = "web") -> CaptureRequest {
        CaptureRequest(provenance: ProvenanceDTO(platform: platform))
    }

    /// What a retaining `InboxDrain` leaves behind — `InboxFixtures.retain`, which
    /// executes the same `retentionMoves(for:)` the drain does (457), so this suite and
    /// the drain cannot disagree about the order.
    @discardableResult
    static func retain(_ record: InboxRecord, in layout: InboxLayout) throws -> InboxRecord {
        try InboxFixtures.retain(record, in: layout)
    }

    // MARK: - What the drain sees

    /// The load-bearing one. A retained record must leave the pending set completely, or
    /// every pass re-ingests it for the life of the device.
    @Test("ingested/ is never enumerated as pending")
    func ingestedIsNotPending() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let retained = try writer.write(Self.request(), payload: Data([0x01]))
        let waiting = try writer.write(Self.request("twitter"), payload: Data([0x02]))

        try Self.retain(retained, in: layout)

        let pending = try layout.pendingRecordURLs().map(\.lastPathComponent)
        #expect(pending == [InboxLayout.recordFileName(for: waiting.id)])
        // And genuinely still on disk — an empty pending set because the fixture DELETED
        // the record would pass the line above and prove nothing.
        #expect(FileManager.default.fileExists(
            atPath: layout.ingestedRecordURL(for: retained.id).path))
    }

    @Test("ingestedRecordURLs() sees exactly what pendingRecordURLs() does not")
    func ingestedEnumerationIsTheComplement() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let retained = try writer.write(Self.request(), payload: Data([0x03]))
        let waiting = try writer.write(Self.request("pinterest"))

        try Self.retain(retained, in: layout)

        #expect(try layout.ingestedRecordURLs().map(\.lastPathComponent)
            == [InboxLayout.recordFileName(for: retained.id)])
        #expect(try layout.pendingRecordURLs().map(\.lastPathComponent)
            == [InboxLayout.recordFileName(for: waiting.id)])
    }

    /// The payload sidecar sits in `ingested/` beside its record and must not be mistaken
    /// for one. Same reason `.bin` is filtered out of the pending walk: an enumeration that
    /// returned it would hand the export a file it cannot decode.
    @Test("neither enumeration returns a payload sidecar")
    func enumerationsTakeOnlyRecords() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let retained = try writer.write(Self.request(), payload: Data([0x04]))
        _ = try writer.write(Self.request(), payload: Data([0x05]))

        try Self.retain(retained, in: layout)

        #expect(try layout.pendingRecordURLs().allSatisfy { $0.pathExtension == "json" })
        #expect(try layout.ingestedRecordURLs().allSatisfy { $0.pathExtension == "json" })
        #expect(try layout.ingestedRecordURLs().count == 1)
    }

    /// An inbox whose drain has never retained anything has no `ingested/` at all — the
    /// directory is created lazily — so the absent case is the NORMAL one and must be an
    /// empty answer rather than a throw.
    @Test("an absent ingested/ is an empty enumeration, not an error")
    func absentIngestedDirectoryIsEmpty() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        _ = try InboxWriter(layout: layout).write(Self.request())

        #expect(!FileManager.default.fileExists(atPath: layout.ingested.path))
        #expect(try layout.ingestedRecordURLs().isEmpty)
    }

    /// An inbox that has never been written to at all: neither enumeration may throw, since
    /// both run on a launch path.
    @Test("an absent inbox answers both enumerations with nothing")
    func absentInboxIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = InboxLayout(libraryRoot: root)

        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(try layout.ingestedRecordURLs().isEmpty)
    }

    /// `failed/` and `sent/` are directories under `ingested/`'s own parent, and the
    /// enumeration that finds ingested records must be as blind to its siblings as the
    /// pending one is. Nested records are the case that would break if anyone reached for a
    /// recursive enumerator.
    @Test("a record nested under a sibling directory is in neither enumeration")
    func nestedRecordsAreInvisible() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let fileManager = FileManager.default
        for directory in [layout.failed, layout.sent, layout.staging] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(
                to: directory.appendingPathComponent(
                    InboxLayout.recordFileName(for: UUID())))
        }
        try fileManager.createDirectory(at: layout.ingested, withIntermediateDirectories: true)

        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(try layout.ingestedRecordURLs().isEmpty)
    }

    // MARK: - The guard

    /// The same assertion `sentURLRefusesTraversal` makes, for the same reason: a drain
    /// retaining a record resolves that record's `payloadFile` for MOVING, exactly as
    /// quarantine does, and a name that could be talked into leaving the inbox on the way
    /// to `failed/` could be talked into it on the way to `ingested/`.
    @Test("ingested/ destinations refuse a name that is not a plain component")
    func ingestedURLRefusesTraversal() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }

        #expect(layout.ingestedURL(named: "../escape.json") == nil)
        #expect(layout.ingestedURL(named: "../../escape.bin") == nil)
        #expect(layout.ingestedURL(named: "a/b.json") == nil)
        #expect(layout.ingestedURL(named: "a\\b.json") == nil)
        #expect(layout.ingestedURL(named: "..") == nil)
        #expect(layout.ingestedURL(named: ".") == nil)
        #expect(layout.ingestedURL(named: "") == nil)
        #expect(layout.ingestedURL(named: "ordinary.bin") != nil)
    }

    /// A name the guard accepts must land INSIDE `ingested/` — the guard is only half the
    /// property, and a resolver that accepted a plain component and then composed it
    /// somewhere else would pass every assertion above.
    @Test("an accepted name resolves inside ingested/")
    func acceptedNameStaysInsideIngested() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }

        let resolved = try #require(layout.ingestedURL(named: "ordinary.bin"))
        #expect(resolved.deletingLastPathComponent().standardizedFileURL
            == layout.ingested.standardizedFileURL)
        #expect(resolved.lastPathComponent == "ordinary.bin")

        let id = UUID()
        #expect(layout.ingestedRecordURL(for: id).standardizedFileURL
            == layout.ingested.appendingPathComponent(
                InboxLayout.recordFileName(for: id)).standardizedFileURL)
    }

    /// `ingested/` is a plain directory, not a dot-directory: `.staging/` hides because an
    /// in-flight write must be invisible even to a human, while a retained capture is
    /// something someone digging through an App Group container should be able to find.
    @Test("ingested/ sits beside failed/ and sent/ under the inbox")
    func ingestedIsAPlainSiblingDirectory() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }

        #expect(InboxLayout.ingestedDirectoryName == "ingested")
        #expect(layout.ingested.lastPathComponent == InboxLayout.ingestedDirectoryName)
        #expect(layout.ingested.deletingLastPathComponent().standardizedFileURL
            == layout.directory.standardizedFileURL)
        #expect(!InboxLayout.ingestedDirectoryName.hasPrefix("."))
    }

    // MARK: - The payload mirrors (457)
    //
    // Each mirror is asserted against the `named:` resolver it replaced at the call
    // sites, so the two ways of naming the same file cannot drift — and against the
    // record mirror beside it, so a payload always lands in the directory its record did.

    @Test("failedPayloadURL(for:) is failed/<uuid>.bin, beside failedRecordURL(for:)")
    func failedPayloadMirror() throws {
        let layout = try Self.makeLayout()
        let id = UUID()

        let url = layout.failedPayloadURL(for: id)
        #expect(url.lastPathComponent == InboxLayout.payloadFileName(for: id))
        #expect(url.deletingLastPathComponent().standardizedFileURL
            == layout.failed.standardizedFileURL)
        #expect(url == layout.failedURL(named: InboxLayout.payloadFileName(for: id)))
        #expect(url.deletingLastPathComponent()
            == layout.failedRecordURL(for: id).deletingLastPathComponent())
        #expect(!url.hasDirectoryPath)
    }

    @Test("sentPayloadURL(for:) is sent/<uuid>.bin, beside sentRecordURL(for:)")
    func sentPayloadMirror() throws {
        let layout = try Self.makeLayout()
        let id = UUID()

        let url = layout.sentPayloadURL(for: id)
        #expect(url.lastPathComponent == InboxLayout.payloadFileName(for: id))
        #expect(url.deletingLastPathComponent().standardizedFileURL
            == layout.sent.standardizedFileURL)
        #expect(url == layout.sentURL(named: InboxLayout.payloadFileName(for: id)))
        #expect(url.deletingLastPathComponent()
            == layout.sentRecordURL(for: id).deletingLastPathComponent())
    }

    @Test("ingestedPayloadURL(for:) is ingested/<uuid>.bin, beside ingestedRecordURL(for:)")
    func ingestedPayloadMirror() throws {
        let layout = try Self.makeLayout()
        let id = UUID()

        let url = layout.ingestedPayloadURL(for: id)
        #expect(url.lastPathComponent == InboxLayout.payloadFileName(for: id))
        #expect(url.deletingLastPathComponent().standardizedFileURL
            == layout.ingested.standardizedFileURL)
        #expect(url == layout.ingestedURL(named: InboxLayout.payloadFileName(for: id)))
        #expect(url.deletingLastPathComponent()
            == layout.ingestedRecordURL(for: id).deletingLastPathComponent())
    }

    // MARK: - The retention plan (457)

    /// The order IS the plan: the record first, then the payload. `InboxDrain.retain`
    /// executes this list in order and `InboxFixtures.retain` executes the same list, so
    /// this is the one place the order is stated and the one test that pins it.
    @Test("a retention plan moves the record first, then its payload, into ingested/")
    func retentionPlanOrder() throws {
        let layout = try Self.makeLayout()
        // A record naming its OWN sidecar — the writer's shape.
        let id = UUID()
        let own = InboxRecord(
            id: id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            request: Self.request(),
            payloadFile: InboxLayout.payloadFileName(for: id))

        let moves = layout.retentionMoves(for: own)

        #expect(moves.map(\.file) == [.record, .payload])
        #expect(moves[0].from == layout.recordURL(for: own.id))
        #expect(moves[0].to == layout.ingestedRecordURL(for: own.id))
        #expect(moves[1].from == layout.payloadURL(for: own.id))
        #expect(moves[1].to == layout.ingestedPayloadURL(for: own.id))
    }

    @Test("a media-less record's plan is the record move alone")
    func retentionPlanWithoutPayload() throws {
        let layout = try Self.makeLayout()
        let record = InboxRecord(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), request: Self.request())

        let moves = layout.retentionMoves(for: record)

        #expect(moves.map(\.file) == [.record])
        #expect(moves[0].from == layout.recordURL(for: record.id))
        #expect(moves[0].to == layout.ingestedRecordURL(for: record.id))
    }

    /// The same refusal `payloadURL(for record:)` makes, seen through the plan: a record
    /// naming a neighbour's sidecar gets no payload move, so nothing executing the plan
    /// can carry off a sibling capture.
    @Test("a record naming a file that is not its own sidecar plans no payload move")
    func retentionPlanRefusesForeignPayload() throws {
        let layout = try Self.makeLayout()
        let record = InboxRecord(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            request: Self.request(),
            payloadFile: InboxLayout.payloadFileName(for: UUID()))

        #expect(layout.retentionMoves(for: record).map(\.file) == [.record])
    }

    // MARK: - The shared primitives (457)

    @Test("replacingMove overwrites whatever is at the destination and reports success")
    func replacingMoveReplaces() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        let from = layout.directory.appendingPathComponent("from.bin")
        let to = layout.directory.appendingPathComponent("to.bin")
        try Data([0x01]).write(to: from)
        try Data([0x02]).write(to: to)

        #expect(InboxLayout.replacingMove(from, to: to))

        #expect(!FileManager.default.fileExists(atPath: from.path))
        #expect(try Data(contentsOf: to) == Data([0x01]))
    }

    @Test("replacingMove of an absent source is false, and the destination is cleared")
    func replacingMoveMissingSource() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        let from = layout.directory.appendingPathComponent("absent.bin")
        let to = layout.directory.appendingPathComponent("to.bin")
        try Data([0x02]).write(to: to)

        #expect(!InboxLayout.replacingMove(from, to: to))
        // "Clearing the destination first" is unconditional: the caller asked for the
        // source to be what sits there, and a stale file is not that.
        #expect(!FileManager.default.fileExists(atPath: to.path))
    }

    @Test("removeIfPresent treats an absent file as already gone")
    func removeIfPresentTolerant() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        try FileManager.default.createDirectory(
            at: layout.directory, withIntermediateDirectories: true)
        let file = layout.directory.appendingPathComponent("gone.bin")
        try Data([0x03]).write(to: file)

        #expect(InboxLayout.removeIfPresent(file))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(InboxLayout.removeIfPresent(file))
        #expect(InboxLayout.removeIfPresent(
            layout.directory.appendingPathComponent("never-there.bin")))
    }

    @Test("a LazyDirectory creates nothing until prepared, then exactly once")
    func lazyDirectoryPreparesOnce() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        var directory = InboxLayout.LazyDirectory(layout.failed)

        #expect(!directory.isPrepared)
        #expect(!FileManager.default.fileExists(atPath: layout.failed.path))

        directory.prepare()
        #expect(directory.isPrepared)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: layout.failed.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        // A second prepare does not recreate — a file put there in between survives it.
        let marker = layout.failed.appendingPathComponent("marker")
        try Data("x".utf8).write(to: marker)
        directory.prepare()
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Value semantics are the "once per pass" guarantee: a copy taken before `prepare()`
    /// does not learn that the original prepared, and two passes share nothing.
    @Test("a LazyDirectory is a value — a copy keeps its own flag")
    func lazyDirectoryIsAValue() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        var first = InboxLayout.LazyDirectory(layout.sent)
        let copy = first

        first.prepare()

        #expect(first.isPrepared)
        #expect(!copy.isPrepared)
    }
}
