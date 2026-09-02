// AtelierCapture — retirement tests (096 · 3B).
//
// The fixtures are built with the REAL `InboxWriter`, for the reason 092 · S3's suite gives:
// hand-rolling the on-disk shape lets the two sides of a contract drift while both suites
// stay green. What retirement moves is what the extension actually wrote.

import Foundation
import Testing

@testable import AtelierCapture
import AtelierCaptureTestSupport

@Suite("InboxRetirement: taking a capture out of the pending set (096 3B)")
struct InboxRetirementTests {

    /// A throwaway inbox, cleaned up by the caller's `defer`.
    static func makeLayout() throws -> InboxLayout {
        try InboxFixtures.makeLayout(suite: "InboxRetirementTests")
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

    // MARK: - The other fate (096 · 4)

    /// The decision this section exists for. A record in `ingested/` is already an asset in
    /// the phone's own library, with its blob on disk — so "nothing is lost" is guaranteed
    /// by that copy, and keeping a second one under `sent/` would defer the unbounded
    /// growth this whole file was written to end rather than ending it.
    @Test("an ingested capture is deleted outright, not moved to sent/")
    func ingestedCaptureIsDeleted() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let record = try InboxWriter(layout: layout).write(
            Self.request(), payload: Data([0xFF, 0xD8]))
        try InboxLayoutTests.retain(record, in: layout)

        let summary = InboxRetirement.retire([record.id], in: layout)

        #expect(summary == InboxRetirement.Summary(retired: 1, failed: 0))
        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(
            atPath: layout.ingestedRecordURL(for: record.id).path))
        #expect(!fileManager.fileExists(
            atPath: layout.ingested.appendingPathComponent(
                InboxLayout.payloadFileName(for: record.id)).path))
        // Nothing was moved anywhere: `sent/` was never even created, since this pass had
        // no capture that needed keeping.
        #expect(!fileManager.fileExists(atPath: layout.sent.path))
        #expect(try layout.ingestedRecordURLs().isEmpty)
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    @Test("an ingested media-less capture deletes with no payload to find")
    func ingestedMediaLessCaptureIsDeleted() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let record = try InboxWriter(layout: layout).write(Self.request())
        try InboxLayoutTests.retain(record, in: layout)

        #expect(InboxRetirement.retire([record.id], in: layout)
            == InboxRetirement.Summary(retired: 1, failed: 0))
        #expect(try layout.ingestedRecordURLs().isEmpty)
    }

    /// The residue of a crash between `InboxDrain`'s two moves: the record reached
    /// `ingested/` and the payload did not. Nothing enumerates a bare `.bin`, so those bytes
    /// are reclaimable only here — at the one moment the program knows the capture is
    /// finished with.
    @Test("clearing reclaims the inbox-side payload an interrupted retention left behind")
    func reclaimsStrayPayloadFromInterruptedRetention() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let fileManager = FileManager.default
        let record = try InboxWriter(layout: layout).write(
            Self.request(), payload: Data([0x0A, 0x0B]))

        // The record moves; the payload does not. Exactly the state the drain's ordering
        // makes reachable, and exactly the one it argues is a leak rather than a wedge.
        try fileManager.createDirectory(at: layout.ingested, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: layout.recordURL(for: record.id),
            to: layout.ingestedRecordURL(for: record.id))
        #expect(fileManager.fileExists(atPath: layout.payloadURL(for: record.id).path))

        #expect(InboxRetirement.retire([record.id], in: layout)
            == InboxRetirement.Summary(retired: 1, failed: 0))

        #expect(!fileManager.fileExists(
            atPath: layout.ingestedRecordURL(for: record.id).path))
        #expect(!fileManager.fileExists(atPath: layout.payloadURL(for: record.id).path))
    }

    /// One press, two fates. A phone that drained some of its inbox and not the rest is the
    /// ordinary case, not an edge one: the drain runs on foreground and a share can land a
    /// second later.
    @Test("one pass moves a pending capture and deletes an ingested one")
    func mixedListTakesBothPaths() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let drained = try writer.write(Self.request("twitter"), payload: Data([0x01]))
        let waiting = try writer.write(Self.request("pinterest"), payload: Data([0x02]))
        try InboxLayoutTests.retain(drained, in: layout)

        #expect(InboxRetirement.retire([drained.id, waiting.id], in: layout)
            == InboxRetirement.Summary(retired: 2, failed: 0))

        let fileManager = FileManager.default
        // The one that was never ingested is kept, because the library holds nothing for
        // it and `sent/` is all that stands between it and oblivion.
        #expect(fileManager.fileExists(atPath: layout.sentRecordURL(for: waiting.id).path))
        #expect(fileManager.fileExists(
            atPath: layout.sent.appendingPathComponent(
                InboxLayout.payloadFileName(for: waiting.id)).path))
        // The one that was ingested is gone.
        #expect(!fileManager.fileExists(atPath: layout.sentRecordURL(for: drained.id).path))
        #expect(try layout.ingestedRecordURLs().isEmpty)
        #expect(try layout.pendingRecordURLs().isEmpty)
    }

    @Test("retiring an ingested capture twice is idempotent")
    func retiringIngestedTwiceIsIdempotent() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let record = try InboxWriter(layout: layout).write(
            Self.request(), payload: Data([0x07]))
        try InboxLayoutTests.retain(record, in: layout)

        #expect(InboxRetirement.retire([record.id], in: layout).retired == 1)
        #expect(InboxRetirement.retire([record.id], in: layout)
            == InboxRetirement.Summary(retired: 0, failed: 0))
    }

    /// Retirement still only touches what it was named, and the ingested set is no
    /// exception — a capture drained but not exported (the funnel refused it, or it landed
    /// while the share sheet was open) must survive a Clear it was not part of.
    @Test("an unnamed ingested capture is left alone")
    func unnamedIngestedCaptureSurvives() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let cleared = try writer.write(Self.request("twitter"), payload: Data([0x01]))
        let kept = try writer.write(Self.request("pinterest"), payload: Data([0x02]))
        try InboxLayoutTests.retain(cleared, in: layout)
        try InboxLayoutTests.retain(kept, in: layout)

        #expect(InboxRetirement.retire([cleared.id], in: layout)
            == InboxRetirement.Summary(retired: 1, failed: 0))

        #expect(try layout.ingestedRecordURLs().map(\.lastPathComponent)
            == [InboxLayout.recordFileName(for: kept.id)])
        #expect(FileManager.default.fileExists(
            atPath: layout.ingested.appendingPathComponent(
                InboxLayout.payloadFileName(for: kept.id)).path))
    }

    /// The deletion must not reach a NEIGHBOUR's bytes. `delete` composes the payload name
    /// from the id through `payloadFileName(for:)` rather than from the record's own
    /// `payloadFile` field, which is the same discipline that stopped a malformed record
    /// carrying off a healthy capture on the drain's paths.
    @Test("deleting an ingested capture leaves a neighbour's payload alone")
    func deletionDoesNotReachANeighbour() throws {
        let layout = try Self.makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.directory) }
        let writer = InboxWriter(layout: layout)
        let cleared = try writer.write(Self.request("twitter"), payload: Data([0x01]))
        let neighbour = try writer.write(Self.request("pinterest"), payload: Data([0x02]))
        try InboxLayoutTests.retain(cleared, in: layout)

        InboxRetirement.retire([cleared.id], in: layout)

        #expect(FileManager.default.fileExists(
            atPath: layout.payloadURL(for: neighbour.id).path))
        #expect(try layout.pendingRecordURLs().map(\.lastPathComponent)
            == [InboxLayout.recordFileName(for: neighbour.id)])
    }
}
