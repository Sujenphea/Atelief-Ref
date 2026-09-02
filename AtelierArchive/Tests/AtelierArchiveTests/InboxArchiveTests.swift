//
//  InboxArchiveTests.swift
//  AtelierArchiveTests
//
//  092 · S6b — the phone's inbox, as an archive.
//
//  Driven through the REAL `InboxWriter`, because that is what puts records in an inbox on
//  a phone: a fixture that hand-wrote JSON would be testing this file against a spelling
//  of the record format rather than against the format. The payloads are real JPEGs from
//  `FixtureImages` (457), since the whole point of `probe` is reading a container's header.
//
//  The claim the last test makes is the one that matters: what this writes,
//  `LibraryArchiveReader` reads. Those two have never met before — one is the phone's
//  producer, the other is the Mac's consumer — and they agree here, in `swift test`,
//  without a phone, a Mac app, or a transport.
//

import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore
import Foundation
import ImageIO
import Testing

@testable import AtelierArchive

@Suite("InboxArchive: the phone's captures as an archive (092 S6)")
struct InboxArchiveTests {

    // MARK: - What each capture becomes

    @Test("An image capture becomes a byte-backed entry with its file beside it")
    func imageCapture() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let record = try rig.captureImage(width: 40, height: 30, url: "https://example.com/a")

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.files == 1)
        #expect(summary.skipped == 0)

        let manifest = try rig.manifest()
        let asset = try #require(manifest.assets.first)
        #expect(asset.kind == .image)
        #expect(asset.width == 40)
        #expect(asset.height == 30)
        #expect(asset.mimeType == "image/jpeg")
        // The hash is the file's, computed the way every other blob address in the program
        // is — so the Mac recomputing it on import lands on the same string.
        #expect(asset.blobHash == (try ContentHasher.hash(contentsOf: rig.payloadURL(record))))
        let file = try #require(manifest.collections.first?.items.first?.file)
        #expect(FileManager.default.fileExists(atPath: rig.root.appendingPathComponent(file).path))
    }

    @Test("A shared link becomes a media-less entry with no file")
    func linkCapture() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureLink("https://example.com/an-article")

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.files == 0)
        let manifest = try rig.manifest()
        let asset = try #require(manifest.assets.first)
        #expect(asset.kind == .link)
        #expect(asset.blobHash == nil)
        // Decoded, not string-matched: the manifest is JSON, so the URL's slashes are
        // escaped in it, and a `contains` check would be asserting an encoding detail.
        let payload = try #require(AssetPayload(jsonString: asset.payload))
        #expect(payload.link?.url == "https://example.com/an-article")
        #expect(manifest.collections.first?.items.first?.file == nil)
    }

    /// Provenance verbatim is what makes a re-import collapse instead of forking (18A),
    /// so it is asserted rather than assumed.
    @Test("Provenance crosses verbatim")
    func provenanceIsVerbatim() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/exact?q=1")

        _ = try rig.export()

        let source = try #require(try rig.manifest().sources.first)
        #expect(source.originalURL == "https://example.com/exact?q=1")
        #expect(source.platform == .web)
    }

    /// **The bug 092 · S6c found, pinned where it happened.** Records are written with
    /// `.secondsSince1970`; a stock `JSONDecoder` reads a bare number as
    /// `timeIntervalSinceReferenceDate`, which is the same digits 31 years later. Every
    /// date was shifted by the same constant, so the export's ORDER was right and nothing
    /// looked wrong until a Mac imported the folder and dated the captures 2054.
    @Test("Capture time survives the read, rather than gaining 31 years")
    func captureTimeIsNotEpochShifted() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try rig.writer.write(
            CaptureRequest(
                provenance: ProvenanceDTO(platform: "web", originalURL: "https://example.com/t")),
            payload: try FixtureImages.solidImage(width: 8, height: 8, format: .jpeg),
            capturedAt: when)

        let records = try InboxArchive.pendingRecords(in: rig.layout)

        #expect(records.count == 1)
        #expect(records.first?.capturedAt == when)
    }

    // MARK: - The formats a phone actually shares (098 · finding 12)
    //
    // Every payload in this suite is a JPEG. A phone shares HEIC out of its camera roll,
    // PNG and JPEG off the web, photographs taken sideways, and GIFs — and this file's
    // `probe` reads a container's HEADER, which is precisely the part of a file that
    // differs between them. The list is `FixtureImages.PhoneFormat`, shared with the
    // drain's sweep in AtelierIngestion so the two ends of the handoff cover the same
    // formats by construction.

    /// Run `body` with a format's bytes, or record a LOUD skip when this host cannot
    /// encode them (HEIC). The convention it replaces — `guard let … else { return }` —
    /// is a test that passes without running.
    private func withPayload(
        _ format: FixtureImages.PhoneFormat, _ body: (Data) throws -> Void
    ) throws {
        guard let bytes = try? format.bytes() else {
            withKnownIssue(
                "\(format) could not be encoded on this host, so the case did not run",
                isIntermittent: true
            ) {
                Issue.record("no \(format) encoder available")
            }
            return
        }
        try body(bytes)
    }

    @Test(
        "every format a phone shares exports with its header's dimensions and MIME",
        arguments: FixtureImages.PhoneFormat.allCases)
    func everyFormatExports(format: FixtureImages.PhoneFormat) throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        try withPayload(format) { bytes in
            let record = try rig.captureImage(bytes: bytes, url: "https://example.com/a")

            let summary = try rig.export()

            #expect(summary.captures == 1)
            #expect(summary.files == 1)
            #expect(summary.skipped == 0)
            let asset = try #require(try rig.manifest().assets.first)
            #expect(asset.mimeType == format.mimeType)
            #expect(asset.fileSize == bytes.count)
            #expect(asset.blobHash
                == (try ContentHasher.hash(contentsOf: rig.payloadURL(record))))

            // **The STORED dimensions, not the display ones**, and it is worth saying why
            // that is right rather than a bug: `probe` reads
            // `kCGImagePropertyPixelWidth` out of the header without decoding, and the
            // reader's only requirement is that both are positive. The file that crosses
            // is the ORIGINAL container, EXIF and all, so the Mac re-ingests it through
            // the same pipeline the phone used and its asset gets the transformed size.
            // The manifest's numbers are a completeness check, not the final geometry.
            #expect(asset.width == format.storedSize.width)
            #expect(asset.height == format.storedSize.height)

            // The bytes in the folder are the bytes from the inbox, unchanged.
            let file = try #require(try rig.manifest().collections.first?.items.first?.file)
            #expect(try Data(contentsOf: rig.root.appendingPathComponent(file)) == bytes)
        }
    }

    /// The sweep from the phone's other state: the capture has been through the local
    /// pipeline and is parked under `ingested/`. Same formats, same answers — the export
    /// reads the original payload either way.
    @Test(
        "every format exports from ingested/ as it does from the pending set",
        arguments: FixtureImages.PhoneFormat.allCases)
    func everyFormatExportsAfterRetention(format: FixtureImages.PhoneFormat) throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        try withPayload(format) { bytes in
            let record = try rig.captureImage(bytes: bytes, url: "https://example.com/a")
            try rig.retain(record)

            let summary = try rig.export()

            #expect(summary.captures == 1)
            #expect(summary.exported == [record.id])
            let asset = try #require(try rig.manifest().assets.first)
            #expect(asset.mimeType == format.mimeType)
            #expect(asset.width == format.storedSize.width)
        }
    }

    /// The GIF's fate at this end, stated: the archive copies the container, so every
    /// frame crosses. Nothing on the phone re-encodes it, and the Mac is what decides
    /// what to keep of it.
    @Test("an animated GIF crosses with all of its frames")
    func animatedGIFCrossesWhole() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let bytes = try FixtureImages.animatedGIF(width: 40, height: 30, frames: 3)
        _ = try rig.captureImage(bytes: bytes, url: "https://example.com/a")

        _ = try rig.export()

        let file = try #require(try rig.manifest().collections.first?.items.first?.file)
        let copied = rig.root.appendingPathComponent(file)
        #expect(copied.pathExtension == "gif")
        let source = try #require(
            CGImageSourceCreateWithURL(copied as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
    }

    // MARK: - Sharing and skipping

    @Test("Two captures of the same bytes share one file")
    func identicalBytesShareAFile() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let bytes = try FixtureImages.solidImage(width: 12, height: 12, format: .jpeg)
        _ = try rig.captureImage(bytes: bytes, url: "https://example.com/1")
        _ = try rig.captureImage(bytes: bytes, url: "https://example.com/2")

        let summary = try rig.export()

        #expect(summary.captures == 2)
        #expect(summary.files == 1)
        let items = try #require(try rig.manifest().collections.first?.items)
        #expect(items.count == 2)
        #expect(items[0].file == items[1].file)
    }

    @Test("A record whose payload has gone missing is skipped; the rest still export")
    func missingPayloadIsSkipped() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let doomed = try rig.captureImage(width: 8, height: 8, url: "https://example.com/gone")
        _ = try rig.captureImage(width: 9, height: 9, url: "https://example.com/kept")
        try FileManager.default.removeItem(at: rig.payloadURL(doomed))

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.skipped == 1)
        #expect(try rig.manifest().assets.count == 1)
    }

    /// The assertion that makes 096 · 3B's clear control safe. `exported` is what the phone
    /// retires, and retiring a capture that never reached the manifest would take it out of
    /// the pending set on the strength of a send it was not in — losing it, quietly, in a
    /// feature whose whole premise is that nothing is lost.
    ///
    /// `captures` counts and cannot substitute: it says one, and says nothing about WHICH.
    @Test("exported names only the captures that reached the manifest, never the skipped")
    func exportedNamesOnlyWhatLanded() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let doomed = try rig.captureImage(width: 8, height: 8, url: "https://example.com/gone")
        let kept = try rig.captureImage(width: 9, height: 9, url: "https://example.com/kept")
        try FileManager.default.removeItem(at: rig.payloadURL(doomed))

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.skipped == 1)
        #expect(summary.exported == [kept.id])
    }

    @Test("A payload that is not a readable image is skipped rather than shipped")
    func unreadablePayloadIsSkipped() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(bytes: Data("not an image".utf8), url: "https://example.com/x")

        #expect(throws: InboxArchive.WriteError.nothingCopied) { _ = try rig.export() }
    }

    @Test("An empty inbox is a refusal, not an empty folder")
    func emptyInboxRefuses() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        #expect(throws: InboxArchive.WriteError.nothingToExport) { _ = try rig.export() }
    }

    /// The manifest is the commit marker (008 · H6). A folder with files and no manifest is
    /// visibly incomplete; one with a manifest claims to be whole.
    @Test("A refused run leaves no manifest behind")
    func refusalWritesNoManifest() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(bytes: Data("not an image".utf8), url: "https://example.com/x")

        _ = try? rig.export()

        #expect(!FileManager.default.fileExists(
            atPath: rig.root.appendingPathComponent(ArchiveLayout.manifestFilename).path))
    }

    // MARK: - What goes wrong at the filesystem (098, the failure sweep)

    /// The copy failing is a different branch from the payload being missing, and
    /// nothing had ever reached it. Forced with a file sitting at the destination the
    /// allocator will pick — which is deterministic, because the name is derived from
    /// the blob hash, so a first export names it for us.
    @Test("a payload that cannot be copied is skipped; the rest still export")
    func aFailedCopyIsSkipped() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let doomed = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        _ = try rig.captureImage(width: 9, height: 9, url: "https://example.com/b")
        let fileManager = FileManager.default

        // Run once to learn the name the allocator gives the first capture's file, then
        // start again with something in the way of exactly that path.
        _ = try rig.export()
        let file = try #require(try rig.manifest().collections.first?.items.first?.file)
        try fileManager.removeItem(at: rig.root)
        let occupied = rig.root.appendingPathComponent(file)
        try fileManager.createDirectory(
            at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: occupied)

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.files == 1)
        #expect(summary.skipped == 1)
        #expect(summary.skippedIDs == [doomed.id])
        #expect(!summary.exported.contains(doomed.id))
        #expect(try rig.manifest().assets.count == 1)
    }

    /// The manifest is the commit marker, so a run that cannot write it must throw
    /// rather than return a summary describing a folder no reader will accept.
    @Test("a manifest that cannot be written is a throw, not a quiet success")
    func aFailedManifestWriteThrows() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        let fileManager = FileManager.default

        // A directory where the manifest has to go.
        try fileManager.createDirectory(at: rig.root, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: rig.root.appendingPathComponent(ArchiveLayout.manifestFilename),
            withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { _ = try rig.export() }

        // The bytes were copied before the manifest was attempted — which is what makes
        // the folder visibly incomplete rather than plausibly whole.
        #expect(throws: (any Error).self) {
            try LibraryArchiveReader.parse(rig.root, schemaVersion: "v19")
        }
    }

    /// A record carrying base64 image bytes inside itself, with no sidecar. The share
    /// extension never writes one (091 · D2 keeps the image out of memory), so this is
    /// another producer's shape in an inbox — and the export refuses it rather than
    /// inventing a file for it. The branch had no test.
    @Test("a record with inline bytes and no sidecar is skipped by name")
    func inlineImageRecordIsSkipped() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let kept = try rig.captureImage(width: 8, height: 8, url: "https://example.com/kept")
        // `.sample()` carries `image:`; with no payload the writer has nothing to strip
        // it in favour of, so the base64 stays in the record.
        let inline = try rig.writer.write(.sample(), payload: PayloadSource?.none)
        #expect(inline.payloadFile == nil)

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.skipped == 1)
        #expect(summary.skippedIDs == [inline.id])
        #expect(summary.exported == [kept.id])
    }

    // MARK: - Ingested is not sent (096 · 4)

    /// The failure this exists to prevent, stated as the thing that must not happen: the
    /// phone drains a share into its own grid and can then never hand it to the Mac. Being
    /// in the local library and having reached the Mac are independent facts, and the export
    /// answers the second one.
    @Test("A capture the phone has ingested is still exported, bytes and all")
    func ingestedCaptureIsStillExported() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let record = try rig.captureImage(width: 40, height: 30, url: "https://example.com/a")
        try rig.retain(record)

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.files == 1)
        #expect(summary.skipped == 0)
        #expect(summary.exported == [record.id])

        // The bytes travelled, not just the row: the manifest's file is really in the
        // folder, with the dimensions the reader refuses an entry without.
        let manifest = try rig.manifest()
        let asset = try #require(manifest.assets.first)
        #expect(asset.width == 40)
        #expect(asset.height == 30)
        let file = try #require(manifest.collections.first?.items.first?.file)
        #expect(FileManager.default.fileExists(
            atPath: rig.root.appendingPathComponent(file).path))
    }

    /// A phone whose drain has caught up has an EMPTY pending set and a full `ingested/`.
    /// Reading only the top level would make that the same case as a phone that has never
    /// captured anything, and the export would refuse with `nothingToExport`.
    @Test("An inbox of nothing but ingested captures is not an empty inbox")
    func ingestedOnlyInboxStillExports() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.retain(
            try rig.captureImage(width: 12, height: 12, url: "https://example.com/a"))
        try rig.retain(try rig.captureLink("https://example.com/b"))

        #expect(try rig.layout.pendingRecordURLs().isEmpty)

        let summary = try rig.export()
        #expect(summary.captures == 2)
        #expect(summary.exported.count == 2)
    }

    /// The ordinary state of a phone that drains on foreground: some captures through the
    /// pipeline, some landed since. Both go, and the order is capture time — which is what
    /// the drained ones would have lost if the union were simply appended.
    @Test("Pending and ingested captures export together, in capture order")
    func pendingAndIngestedExportInCaptureOrder() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // The older capture is the one that has already been drained, so file order,
        // directory order and capture order all disagree.
        let older = try rig.writer.write(
            CaptureRequest(provenance: ProvenanceDTO(
                platform: "web", originalURL: "https://example.com/older")),
            payload: try FixtureImages.solidImage(width: 8, height: 8, format: .jpeg),
            capturedAt: base)
        let newer = try rig.writer.write(
            CaptureRequest(provenance: ProvenanceDTO(
                platform: "web", originalURL: "https://example.com/newer")),
            payload: try FixtureImages.solidImage(width: 9, height: 9, format: .jpeg),
            capturedAt: base.addingTimeInterval(60))
        try rig.retain(older)

        let summary = try rig.export()

        #expect(summary.captures == 2)
        #expect(summary.exported == [older.id, newer.id])
        #expect(try InboxArchive.pendingRecords(in: rig.layout).map(\.id)
            == [older.id, newer.id])
    }

    /// The residue of a crash between `InboxDrain`'s two moves: record retained, payload
    /// still in the inbox. The drain's ordering argues this is a leak rather than a wedge,
    /// and "not a wedge" means precisely that the export still reads it as a whole capture.
    @Test("A half-finished retention exports with the bytes it left behind")
    func halfFinishedRetentionStillExports() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let record = try rig.captureImage(width: 16, height: 16, url: "https://example.com/a")
        try rig.retain(record, movingPayload: false)

        // The state under test, spelled out so a change in the fixture cannot quietly make
        // this test about something else.
        #expect(FileManager.default.fileExists(
            atPath: rig.layout.ingestedRecordURL(for: record.id).path))
        #expect(FileManager.default.fileExists(
            atPath: rig.layout.payloadURL(for: record.id).path))

        let summary = try rig.export()
        #expect(summary.captures == 1)
        #expect(summary.files == 1)
        #expect(summary.skipped == 0)
        #expect(try rig.manifest().assets.first?.width == 16)
    }

    /// An ingested record whose bytes are gone from BOTH sites is the same case as a pending
    /// one whose payload was deleted: skipped, left where it is, and not shipped as an entry
    /// the Mac's reader would drop.
    @Test("An ingested capture with no bytes anywhere is skipped, not shipped")
    func ingestedCaptureWithoutBytesIsSkipped() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let doomed = try rig.captureImage(width: 8, height: 8, url: "https://example.com/gone")
        let kept = try rig.captureImage(width: 9, height: 9, url: "https://example.com/kept")
        try rig.retain(doomed)
        try FileManager.default.removeItem(
            at: rig.layout.ingested.appendingPathComponent(
                InboxLayout.payloadFileName(for: doomed.id)))

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.skipped == 1)
        #expect(summary.exported == [kept.id])
    }

    /// A record cannot legitimately be pending AND ingested — retention moves it — so this
    /// pins the guard against a state that should not exist. Two manifest entries under one
    /// source id is not something the reader can make sense of, and the id is the record's
    /// by design so a re-export stays diffable.
    @Test("A record in both directories is exported once")
    func aRecordInBothPlacesIsExportedOnce() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let record = try rig.captureImage(width: 10, height: 10, url: "https://example.com/a")

        // Copied, not moved: both sites, one id.
        try FileManager.default.createDirectory(
            at: rig.layout.ingested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: rig.layout.recordURL(for: record.id),
            to: rig.layout.ingestedRecordURL(for: record.id))

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.exported == [record.id])
        #expect(try rig.manifest().sources.count == 1)
    }

    /// `sent/` is the user's assertion that a capture reached the Mac, and it has to keep
    /// meaning that. If the export read it the way it now reads `ingested/`, Clear would
    /// stop doing anything at all.
    @Test("A retired capture under sent/ is not exported")
    func retiredCaptureIsNotExported() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let record = try rig.captureImage(width: 10, height: 10, url: "https://example.com/a")
        InboxRetirement.retire([record.id], in: rig.layout)

        #expect(throws: InboxArchive.WriteError.nothingToExport) { _ = try rig.export() }
        #expect(try InboxArchive.pendingRecords(in: rig.layout).isEmpty)
    }

    /// And the same for `failed/`: a capture the drain gave up on is not something to hand
    /// the Mac, and the enumeration that keeps it out is the one `ingested/` had to be added
    /// without disturbing.
    @Test("A quarantined capture under failed/ is not exported")
    func quarantinedCaptureIsNotExported() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let record = try rig.captureImage(width: 10, height: 10, url: "https://example.com/a")
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: rig.layout.failed, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: rig.layout.recordURL(for: record.id),
            to: rig.layout.failedRecordURL(for: record.id))

        #expect(try InboxArchive.pendingRecords(in: rig.layout).isEmpty)
    }

    // MARK: - What could not be read is counted (098 · finding 8)

    /// The defect: `pendingRecords` dropped an undecodable `.json` with a `try?` and the
    /// phone counted `.json` FILES, so a single corrupt record made the control say one
    /// more than the manifest would ever contain — permanently, with no screen that could
    /// show it and no control that could clear it.
    @Test("a corrupt record among good ones is counted, and the good ones still export")
    func corruptRecordIsCountedNotDropped() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let kept = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        try rig.writeCorruptRecord()

        let pending = try InboxArchive.pending(in: rig.layout)
        #expect(pending.records.map(\.id) == [kept.id])
        #expect(pending.unreadable == 1)

        let summary = try rig.export()
        #expect(summary.captures == 1)
        #expect(summary.unreadable == 1)
        #expect(summary.skipped == 1)
        #expect(summary.skippedIDs.isEmpty)
        #expect(summary.exported == [kept.id])
        #expect(try rig.manifest().assets.count == 1)
    }

    /// An inbox of nothing but corrupt files is `nothingToExport`, not a folder claiming
    /// to be an export of nothing — and the count says why rather than saying zero.
    @Test("an inbox of nothing but corrupt records reports honestly")
    func allCorruptInboxReportsHonestly() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.writeCorruptRecord()
        try rig.writeCorruptRecord()

        let pending = try InboxArchive.pending(in: rig.layout)
        #expect(pending.records.isEmpty)
        #expect(pending.unreadable == 2)

        #expect(throws: InboxArchive.WriteError.nothingToExport) { _ = try rig.export() }
    }

    /// An undecodable record parked under `ingested/` is the same case and the one that
    /// bit: it is invisible to the pending enumeration, so nothing but this ever looked
    /// at it.
    @Test("an unreadable record under ingested/ is counted too")
    func unreadableIngestedRecordIsCounted() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: rig.layout.ingested, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(
            to: rig.layout.ingestedRecordURL(for: UUID()))

        #expect(try InboxArchive.pending(in: rig.layout).unreadable == 1)
        #expect(try rig.export().unreadable == 1)
    }

    /// `skipped` is one answer made of two halves, and a caller reading only one of them
    /// would under-report. Both kinds in one run, so the arithmetic is asserted rather
    /// than assumed.
    @Test("skipped is exactly the unreadable plus the named")
    func skippedIsTheSumOfItsHalves() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/kept")
        let doomed = try rig.captureImage(width: 9, height: 9, url: "https://example.com/gone")
        try FileManager.default.removeItem(at: rig.payloadURL(doomed))
        try rig.writeCorruptRecord()

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.unreadable == 1)
        #expect(summary.skippedIDs == [doomed.id])
        #expect(summary.skipped == summary.unreadable + summary.skippedIDs.count)
        #expect(summary.skipped == 2)
    }

    /// The other half of 098 · finding 1b, from the export's side: a capture the phone's
    /// drain gave up on stays in the pending set, and the whole reason it stays there is
    /// that the Mac may decode what this device could not.
    @Test("a capture the phone could not ingest is still sent")
    func exhaustedCaptureIsStillSent() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        var record = try rig.captureImage(
            width: 12, height: 12, url: "https://example.com/exhausted")
        // What a retaining drain leaves behind once the attempts are gone: the record
        // pending, at the count that exhausted, with its bytes beside it.
        record.attempts = 3
        try rig.writer.rewrite(record)

        let summary = try rig.export()

        #expect(summary.captures == 1)
        #expect(summary.files == 1)
        #expect(summary.skipped == 0)
        #expect(summary.exported == [record.id])
        #expect(try rig.manifest().assets.first?.width == 12)
    }

    // MARK: - The folder an export lives in (098 · finding 4)

    /// The leak: the phone removed a folder of the same NAME, which is the same name only
    /// within one minute. Two sends a minute apart left two complete copies of every
    /// capture, and Clear then made the abandoned one their only owner.
    @Test("writeExport clears every sibling, not just its own name")
    func writeExportClearsStaleSiblings() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let record = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        let fileManager = FileManager.default

        let stale = rig.exportsParent.appendingPathComponent(
            "Atelier 2026-08-17 1830", isDirectory: true)
        try fileManager.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("last time's bytes".utf8).write(
            to: stale.appendingPathComponent("payload.jpg"))

        let export = try rig.writeExport(folderName: "Atelier 2026-08-17 1831")

        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(export.folder.lastPathComponent == "Atelier 2026-08-17 1831")
        #expect(export.summary.exported == [record.id])
        // Exactly one folder under the parent: the one that was just handed out.
        #expect(try fileManager.contentsOfDirectory(
            at: rig.exportsParent, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent) == ["Atelier 2026-08-17 1831"])
        #expect(fileManager.fileExists(atPath: export.summary.manifestURL.path))
    }

    @Test("writeExport creates the parent when there has never been an export")
    func writeExportCreatesAFreshParent() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        #expect(!FileManager.default.fileExists(atPath: rig.exportsParent.path))

        let export = try rig.writeExport(folderName: "Atelier 2026-08-17 1830")

        #expect(FileManager.default.fileExists(atPath: export.folder.path))
        #expect(export.summary.captures == 1)
    }

    /// A file where a folder would be is litter this directory's meaning does not allow
    /// for — it is "the current export" and nothing else — so it goes with the rest.
    @Test("writeExport clears a non-directory sibling too")
    func writeExportClearsAStrayFile() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: rig.exportsParent, withIntermediateDirectories: true)
        let stray = rig.exportsParent.appendingPathComponent(".DS_Store")
        try Data("stray".utf8).write(to: stray)

        let export = try rig.writeExport(folderName: "Atelier 2026-08-17 1830")

        #expect(!fileManager.fileExists(atPath: stray.path))
        #expect(try fileManager.contentsOfDirectory(
            at: rig.exportsParent, includingPropertiesForKeys: nil).count == 1)
        #expect(export.summary.captures == 1)
    }

    /// Refused BEFORE anything is deleted: an empty inbox must not cost the user the
    /// folder they may still be holding a share sheet over.
    @Test("writeExport refuses an empty inbox without touching what is there")
    func writeExportRefusesBeforeClearing() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let fileManager = FileManager.default
        let previous = rig.exportsParent.appendingPathComponent(
            "Atelier 2026-08-17 1830", isDirectory: true)
        try fileManager.createDirectory(at: previous, withIntermediateDirectories: true)

        #expect(throws: InboxArchive.WriteError.nothingToExport) {
            _ = try rig.writeExport(folderName: "Atelier 2026-08-17 1831")
        }
        #expect(fileManager.fileExists(atPath: previous.path))
    }

    /// The unreadable count reaches the summary through this entry point too — the phone
    /// only ever calls this one, so a fold that happened only in `write` would be a fold
    /// that never happened.
    @Test("writeExport carries the unreadable count into its summary")
    func writeExportCarriesTheUnreadableCount() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/a")
        try rig.writeCorruptRecord()

        let export = try rig.writeExport(folderName: "Atelier 2026-08-17 1830")

        #expect(export.summary.captures == 1)
        #expect(export.summary.unreadable == 1)
        #expect(export.summary.skipped == 1)
    }

    // MARK: - The handshake

    /// The rule is the reader's (`LibraryArchiveReaderRefusalTests` pins it for a
    /// Mac-written archive); this pins that a PHONE-written one is subject to it — that
    /// `InboxArchive.write` puts the phone's schema version where the reader looks, so a
    /// phone on a newer build than the Mac sends a folder the Mac declines whole, before
    /// a record is read, rather than half-imports. Today's behaviour, without a
    /// format-version field of the inbox's own yet (098, the test batch).
    @Test("An archive from a schema newer than the reader's is refused, not half-read")
    func newerSchemaIsRefused() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 8, height: 8, url: "https://example.com/newer")
        let records = try InboxArchive.pendingRecords(in: rig.layout)
        _ = try InboxArchive.write(
            records: records, layout: rig.layout, to: rig.root,
            appVersion: "9.9-test", schemaVersion: "v99",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(throws: ArchiveReadError.refused(.schemaTooNew("v99"))) {
            try LibraryArchiveReader.parse(rig.root, schemaVersion: "v19")
        }
        // The same folder reads on a build that has caught up.
        #expect(throws: Never.self) {
            try LibraryArchiveReader.parse(rig.root, schemaVersion: "v99")
        }
    }

    @Test("What the phone writes, the Mac's reader reads")
    func theReaderReadsIt() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.captureImage(width: 20, height: 10, url: "https://example.com/one")
        _ = try rig.captureLink("https://example.com/two")

        _ = try rig.export()
        let parse = try LibraryArchiveReader.parse(rig.root, schemaVersion: "v19")

        // One collection, two memberships, nothing skipped and nothing left over.
        #expect(parse.plans.count == 1)
        let plan = try #require(parse.plans.first)
        #expect(plan.name == InboxArchive.collectionName)
        #expect(plan.items.count == 2)
        #expect(parse.skipped.isEmpty)
        #expect(parse.unreferenced.isEmpty)

        // The byte-backed one resolves to real bytes with usable dimensions — the exact
        // thing the reader refuses an entry for when a writer gets it wrong.
        let media = try #require(plan.items.first { if case .media = $0.body { return true }
                                                   else { return false } })
        guard case let .media(kind, bytes, _) = media.body else { return }
        #expect(kind == .image)
        #expect(bytes.width == 20)
        #expect(bytes.height == 10)
        #expect(media.source.originalURL == "https://example.com/one")
    }

    // MARK: - Fixtures

    /// A real inbox written by the real `InboxWriter`, plus a destination to export into.
    struct Rig {
        let libraryRoot: URL
        let root: URL
        /// The stand-in for `Caches/Exports/`: the directory `writeExport` owns and
        /// clears. Deliberately NOT created by the rig — "there has never been an
        /// export" is a case.
        let exportsParent: URL
        let layout: InboxLayout
        let writer: InboxWriter

        init() throws {
            let base = try InboxFixtures.temporaryLibraryRoot(suite: "InboxArchiveTests")
            libraryRoot = base.appendingPathComponent("library", isDirectory: true)
            root = base.appendingPathComponent("export", isDirectory: true)
            exportsParent = base.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(
                at: libraryRoot, withIntermediateDirectories: true)
            layout = InboxLayout(libraryRoot: libraryRoot)
            writer = InboxWriter(layout: layout)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: libraryRoot.deletingLastPathComponent())
        }

        @discardableResult
        func captureImage(width: Int, height: Int, url: String) throws -> InboxRecord {
            try captureImage(
                bytes: try FixtureImages.solidImage(width: width, height: height, format: .jpeg),
                url: url)
        }

        @discardableResult
        func captureImage(bytes: Data, url: String) throws -> InboxRecord {
            try writer.write(
                CaptureRequest(provenance: ProvenanceDTO(platform: "web", originalURL: url)),
                payload: bytes)
        }

        @discardableResult
        func captureLink(_ url: String) throws -> InboxRecord {
            try writer.write(.sampleLink(url), payload: PayloadSource?.none)
        }

        func payloadURL(_ record: InboxRecord) -> URL {
            layout.payloadURL(for: record)!
        }

        /// What a retaining `InboxDrain` leaves behind (096 · 4): the capture's files under
        /// `inbox/ingested/`, out of the pending set and still on disk — `InboxFixtures
        /// .retain`, which executes the drain's own `retentionMoves(for:)` (457), so this
        /// suite cannot drift from the drain's order. `movingPayload: false` reproduces
        /// the state a crash between the two moves leaves behind.
        @discardableResult
        func retain(_ record: InboxRecord, movingPayload: Bool = true) throws -> InboxRecord {
            try InboxFixtures.retain(record, in: layout, movingPayload: movingPayload)
        }

        /// A `.json` in the pending set that will never decode into a record — the state
        /// `pending(in:)` used to drop with a `try?` and nothing else in the program
        /// could see. Returns the name it was written under.
        @discardableResult
        func writeCorruptRecord() throws -> String {
            let id = UUID()
            try FileManager.default.createDirectory(
                at: layout.directory, withIntermediateDirectories: true)
            try Data("{ not a record".utf8).write(to: layout.recordURL(for: id))
            return InboxLayout.recordFileName(for: id)
        }

        /// The whole read-and-write an export is, through the low-level writer — the
        /// shape every assertion about the manifest is made against.
        func export() throws -> InboxArchive.Summary {
            let pending = try InboxArchive.pending(in: layout)
            return try InboxArchive.write(
                records: pending.records, layout: layout, to: root,
                appVersion: "1.0-test", schemaVersion: "v19",
                exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                unreadable: pending.unreadable)
        }

        /// The same run through the entry point the phone actually calls, which owns the
        /// folder lifecycle as well (098 · finding 4).
        func writeExport(folderName: String) throws -> InboxArchive.Export {
            try InboxArchive.writeExport(
                try InboxArchive.pending(in: layout), layout: layout,
                under: exportsParent, folderName: folderName,
                appVersion: "1.0-test", schemaVersion: "v19",
                now: Date(timeIntervalSince1970: 1_700_000_000))
        }

        func manifest() throws -> ArchiveManifest {
            try ArchiveManifest.makeDecoder().decode(
                ArchiveManifest.self,
                from: Data(contentsOf: root.appendingPathComponent(
                    ArchiveLayout.manifestFilename)))
        }
    }
}
