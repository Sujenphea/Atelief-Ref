// AtelierCapture — retirement tests (096 · 3B).
//
// The fixtures are built with the REAL `InboxWriter`, for the reason 092 · S3's suite gives:
// hand-rolling the on-disk shape lets the two sides of a contract drift while both suites
// stay green. What retirement moves is what the extension actually wrote.

import Foundation
import Testing

@testable import AtelierCapture

@Suite("InboxRetirement: taking a capture out of the pending set (096 3B)")
struct InboxRetirementTests {

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

    @Test("a retired capture leaves the pending set and keeps both its files")
    func retiresRecordAndPayload() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let record = try writer.write(Self.request(), payload: Data([0xFF, 0xD8]))

        #expect(try layout.pendingRecordURLs().count == 1)

        let summary = InboxRetirement.retire([record.id], in: layout)

        #expect(summary == InboxRetirement.Summary(retired: 1, failed: 0))
        // Gone from pending — which is the whole point: the next export is what was
        // captured since, not everything ever.
        #expect(try layout.pendingRecordURLs().isEmpty)
        // And still on disk, both halves. Nothing here deletes.
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: layout.sentRecordURL(for: record.id).path))
        #expect(fileManager.fileExists(
            atPath: layout.sent.appendingPathComponent(
                InboxLayout.payloadFileName(for: record.id)).path))
        #expect(!fileManager.fileExists(atPath: layout.recordURL(for: record.id).path))
        #expect(!fileManager.fileExists(atPath: layout.payloadURL(for: record.id).path))
    }

    @Test("a media-less capture retires with no payload to move")
    func retiresMediaLessCapture() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let record = try InboxWriter(layout: layout).write(Self.request())

        #expect(InboxRetirement.retire([record.id], in: layout)
            == InboxRetirement.Summary(retired: 1, failed: 0))
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    /// The assertion that makes retirement safe to wire to a button: only what was named
    /// moves. `InboxArchive` skips records its funnel refuses, and a capture made while the
    /// share sheet was open was never in the export at all — both must stay pending.
    @Test("only the named captures retire; everything else stays pending")
    func retiresOnlyWhatWasNamed() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let sent = try writer.write(Self.request("twitter"), payload: Data([0x01]))
        let kept = try writer.write(Self.request("pinterest"), payload: Data([0x02]))

        #expect(InboxRetirement.retire([sent.id], in: layout)
            == InboxRetirement.Summary(retired: 1, failed: 0))

        let pending = try layout.pendingRecordURLs().map(\.lastPathComponent)
        #expect(pending == [InboxLayout.recordFileName(for: kept.id)])
    }

    @Test("an id with no record is not a failure — it is already not pending")
    func unknownIDIsNotAFailure() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }

        #expect(InboxRetirement.retire([UUID()], in: layout)
            == InboxRetirement.Summary(retired: 0, failed: 0))
        // And no empty `sent/` left behind: the directory existing is a signal, so a pass
        // that retired nothing must not create one.
        #expect(!FileManager.default.fileExists(atPath: layout.sent.path))
    }

    @Test("an empty list touches nothing")
    func emptyListIsANoOp() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        _ = try InboxWriter(layout: layout).write(Self.request())

        #expect(InboxRetirement.retire([], in: layout) == InboxRetirement.Summary())
        #expect(try layout.pendingRecordURLs().count == 1)
    }

    /// Retiring the same capture twice is what a user pressing the control after re-exporting
    /// an already-retired set would do. It must not fail, and it must not lose the capture.
    @Test("retiring twice is idempotent, and the second pass finds nothing pending")
    func retiringTwiceIsIdempotent() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let record = try InboxWriter(layout: layout).write(
            Self.request(), payload: Data([0x03]))

        #expect(InboxRetirement.retire([record.id], in: layout).retired == 1)
        #expect(InboxRetirement.retire([record.id], in: layout)
            == InboxRetirement.Summary(retired: 0, failed: 0))
        #expect(FileManager.default.fileExists(
            atPath: layout.sentRecordURL(for: record.id).path))
    }

    /// `sent/` has to be invisible to everything that reads the inbox, exactly as `.staging/`
    /// and `failed/` are — otherwise retiring a capture would leave it being exported and
    /// drained forever, which is the bug this feature exists to prevent, inverted.
    @Test("sent/ is never enumerated as pending")
    func sentIsNotEnumerated() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let first = try writer.write(Self.request(), payload: Data([0x04]))
        let second = try writer.write(Self.request(), payload: Data([0x05]))

        InboxRetirement.retire([first.id, second.id], in: layout)

        #expect(try layout.pendingRecordURLs().isEmpty)
        // The files are genuinely there — an empty enumeration because the move DELETED
        // them would pass the line above and fail the design.
        let contents = try FileManager.default.contentsOfDirectory(
            at: layout.sent, includingPropertiesForKeys: nil)
        #expect(contents.count == 4)
    }

    /// A name is only ever composed by `InboxLayout`, here as everywhere. `sentURL(named:)`
    /// applies the same guard as `failedURL(named:)`, and this pins that it does — a
    /// retirement path that could be talked into escaping the inbox would be a worse version
    /// of the bug R1 closed for the drain.
    @Test("sent/ destinations refuse a name that is not a plain component")
    func sentURLRefusesTraversal() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }

        #expect(layout.sentURL(named: "../escape.json") == nil)
        #expect(layout.sentURL(named: "a/b.json") == nil)
        #expect(layout.sentURL(named: "..") == nil)
        #expect(layout.sentURL(named: "") == nil)
        #expect(layout.sentURL(named: "ordinary.json") != nil)
    }
}
