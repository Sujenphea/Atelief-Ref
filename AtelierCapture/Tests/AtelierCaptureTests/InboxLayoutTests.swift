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

@Suite("InboxLayout: what the inbox's enumerations can and cannot see (096 4)")
struct InboxLayoutTests {

    /// A throwaway inbox, cleaned up by the caller's `defer`.
    static func makeLayout() throws -> InboxLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return InboxLayout(libraryRoot: root)
    }

    static func request(_ platform: String = "web") -> CaptureRequest {
        CaptureRequest(provenance: ProvenanceDTO(platform: platform))
    }

    /// What a retaining `InboxDrain` leaves behind, performed by hand because the drain
    /// lives in a package this one does not depend on (and must not: `AtelierCapture` is
    /// what the share extension links). The move it performs is pinned against the real
    /// drain by `InboxDrainTests`; here it is only a fixture.
    @discardableResult
    static func retain(_ record: InboxRecord, in layout: InboxLayout) throws -> InboxRecord {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.ingested, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: layout.recordURL(for: record.id),
            to: layout.ingestedRecordURL(for: record.id))
        let payload = layout.payloadURL(for: record.id)
        if fileManager.fileExists(atPath: payload.path) {
            try fileManager.moveItem(
                at: payload,
                to: layout.ingested.appendingPathComponent(
                    InboxLayout.payloadFileName(for: record.id)))
        }
        return record
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
}
