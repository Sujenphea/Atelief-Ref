//
//  InboxArchiveTests.swift
//  AtelierArchiveTests
//
//  092 · S6b — the phone's inbox, as an archive.
//
//  Driven through the REAL `InboxWriter`, because that is what puts records in an inbox on
//  a phone: a fixture that hand-wrote JSON would be testing this file against a spelling
//  of the record format rather than against the format. The payloads are real JPEGs made
//  with ImageIO, since the whole point of `probe` is reading a container's header.
//
//  The claim the last test makes is the one that matters: what this writes,
//  `LibraryArchiveReader` reads. Those two have never met before — one is the phone's
//  producer, the other is the Mac's consumer — and they agree here, in `swift test`,
//  without a phone, a Mac app, or a transport.
//

import AtelierCapture
import AtelierCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

    // MARK: - Sharing and skipping

    @Test("Two captures of the same bytes share one file")
    func identicalBytesShareAFile() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let bytes = try Rig.jpeg(width: 12, height: 12)
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

    // MARK: - The handshake

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
        let layout: InboxLayout
        let writer: InboxWriter

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("InboxArchiveTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            libraryRoot = base.appendingPathComponent("library", isDirectory: true)
            root = base.appendingPathComponent("export", isDirectory: true)
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
            try captureImage(bytes: try Self.jpeg(width: width, height: height), url: url)
        }

        @discardableResult
        func captureImage(bytes: Data, url: String) throws -> InboxRecord {
            try writer.write(
                CaptureRequest(provenance: ProvenanceDTO(platform: "web", originalURL: url)),
                payload: bytes)
        }

        @discardableResult
        func captureLink(_ url: String) throws -> InboxRecord {
            try writer.write(
                CaptureRequest(
                    provenance: ProvenanceDTO(platform: "web", originalURL: url),
                    kind: AssetKind.link.rawValue,
                    payload: AssetPayload(link: LinkPayload(url: url))),
                payload: PayloadSource?.none)
        }

        func payloadURL(_ record: InboxRecord) -> URL {
            layout.payloadURL(for: record)!
        }

        func export() throws -> InboxArchive.Summary {
            let records = try layout.pendingRecordURLs()
                .compactMap { try? JSONDecoder().decode(InboxRecord.self, from: Data(contentsOf: $0)) }
                .sorted { $0.capturedAt < $1.capturedAt }
            return try InboxArchive.write(
                records: records, layout: layout, to: root,
                appVersion: "1.0-test", schemaVersion: "v19",
                exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }

        func manifest() throws -> ArchiveManifest {
            try ArchiveManifest.makeDecoder().decode(
                ArchiveManifest.self,
                from: Data(contentsOf: root.appendingPathComponent(
                    ArchiveLayout.manifestFilename)))
        }

        /// A real JPEG of the requested size — `probe` reads a container's header, so a
        /// fixture has to be one.
        static func jpeg(width: Int, height: Int) throws -> Data {
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(
                red: CGFloat(width % 7) / 7, green: 0.4, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return data as Data
        }
    }
}
