//
//  InboxArchiveImportTests.swift
//  AtelierRefsTests
//
//  092 · S6c — the other end of the phone's export.
//
//  `InboxArchiveTests` proves the phone writes a folder the READER can parse. That is a
//  producer/consumer handshake, and it stops one layer short of the claim S6 actually
//  makes: that a capture made on a phone becomes an ASSET in a Mac library, with the
//  provenance it would have had if the Mac had drained it directly, and that sending it
//  twice does not leave the user with it twice.
//
//  So this test starts where the phone starts — a real `InboxWriter`, real JPEG payloads,
//  no library rows, because iOS never drains its inbox — runs the app's own export path
//  (`InboxArchive.pendingRecords` + `.write`, which is all `CaptureExport` does), and
//  finishes in `ArchiveImportController`, the Mac's shipped importer. Nothing is stubbed
//  in the middle. What is not exercised is the transport, which is a folder move and
//  belongs to AirDrop or Finder rather than to this program.
//
//  **The load-bearing assertions are counts, not presence.** 18A dedup collapses a
//  re-import only when the incoming provenance matches the stored one; a field the phone's
//  writer dropped or normalised would still leave every capture PRESENT on the Mac — as a
//  second copy. Two of the four tests below exist to count.
//

import AtelierArchive
import AtelierCapture
import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AtelierRefs

// MARK: - Rig

/// A phone (an inbox and nothing else) and a Mac (a library), with archive folders
/// between them.
@MainActor
private struct PhoneToMacRig {
    let base: URL
    /// The phone's library root — the inbox hangs off it. Its database is never opened:
    /// what the phone has to send lives entirely in `inbox/`.
    let phoneRoot: URL
    let layout: InboxLayout
    let writer: InboxWriter
    let mac: AppServices
    let macStore: MediaStore

    static func make() throws -> PhoneToMacRig {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("InboxArchiveImportTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let phoneRoot = base.appendingPathComponent("phone", isDirectory: true)
        let macRoot = base.appendingPathComponent("mac", isDirectory: true)
        for directory in [phoneRoot, macRoot] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        let layout = InboxLayout(libraryRoot: phoneRoot)
        return PhoneToMacRig(
            base: base,
            phoneRoot: phoneRoot,
            layout: layout,
            writer: InboxWriter(layout: layout),
            mac: try AppServices(
                databasePath: macRoot.appendingPathComponent("library.sqlite").path),
            macStore: MediaStore(root: macRoot))
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    // MARK: The phone

    /// A share made on the phone: a record, a payload file, and no asset row anywhere.
    @discardableResult
    func share(
        width: Int = 20, height: Int = 12, url: String, title: String? = nil,
        at capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> InboxRecord {
        try writer.write(
            CaptureRequest(
                provenance: ProvenanceDTO(
                    platform: "web", originalURL: url, authorName: "A Designer",
                    title: title)),
            payload: try Self.jpeg(width: width, height: height),
            capturedAt: capturedAt)
    }

    /// A shared link: complete without any bytes at all.
    @discardableResult
    func shareLink(
        _ url: String, at capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> InboxRecord {
        try writer.write(
            CaptureRequest(
                provenance: ProvenanceDTO(platform: "web", originalURL: url),
                kind: AssetKind.link.rawValue,
                payload: AssetPayload(link: LinkPayload(url: url))),
            payload: PayloadSource?.none,
            capturedAt: capturedAt)
    }

    /// How many captures are still waiting on the phone.
    func pendingCount() throws -> Int {
        try layout.pendingRecordURLs().count
    }

    func payloadURL(_ record: InboxRecord) -> URL {
        layout.payloadURL(for: record)!
    }

    // MARK: The export, exactly as the app runs it

    /// `CaptureExport`'s whole job, minus the Caches directory and the date formatter —
    /// both of which are iOS-target code this suite cannot link. The two calls that
    /// decide what crosses are the app's own.
    @discardableResult
    func export(
        named name: String,
        at exportedAt: Date = Date(timeIntervalSince1970: 1_700_010_000)
    ) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try InboxArchive.write(
            records: try InboxArchive.pendingRecords(in: layout),
            layout: layout, to: root, appVersion: "1.0-test", exportedAt: exportedAt)
        return root
    }

    // MARK: The Mac

    func importIntoMac(_ archive: URL) async -> ImportRunSummary {
        await ArchiveImportController.perform(
            services: mac, store: macStore, folder: DirectFolderAccess(url: archive),
            snapshot: {}, flag: CancelFlag(), onProgress: { _ in })
    }

    /// The collection the import created, by the name the folder had.
    func destination(_ name: String) async throws -> Collection? {
        try await mac.listCollections().first {
            $0.name == name && $0.parentCollectionID == nil
        }
    }

    /// The archive's own "Unsorted", found by PARENT rather than by name — the Mac
    /// library has an Unsorted of its own, and telling them apart is the point.
    func landing(under destination: Collection) async throws -> Collection? {
        try await mac.listCollections().first {
            $0.parentCollectionID == destination.id && $0.name == InboxArchive.collectionName
        }
    }

    func items(in collectionID: UUID, sort: SortMode = .manual) async throws
        -> [CollectionItemDetail]
    {
        try await mac.collectionItems(in: collectionID, sort: sort, includeArchived: false)
    }

    /// Distinct assets in the Mac library, counted across every collection — the number a
    /// dropped provenance field silently doubles.
    func macAssetCount() async throws -> Int {
        var ids: Set<UUID> = []
        for collection in try await mac.listCollections() {
            for detail in try await mac.collectionItems(
                in: collection.id, sort: .manual, includeArchived: true)
            {
                ids.insert(detail.asset.id)
            }
        }
        return ids.count
    }

    // MARK: Bytes

    /// A real JPEG — `InboxArchive.probe` reads a container's header, so a fixture has to
    /// be a container. Sized distinctly per call so a swapped payload is visible.
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

// MARK: - The round trip

@MainActor
@Suite("Phone inbox → archive → Mac library (092 S6c)")
struct InboxArchiveImportTests {

    /// The whole claim in one case: three shares made on a phone become three assets in a
    /// Mac library, with their bytes, their kinds and their provenance intact.
    @Test("Captures made on the phone arrive on the Mac as assets")
    func capturesArrive() async throws {
        let rig = try PhoneToMacRig.make()
        defer { rig.cleanup() }

        let hero = try rig.share(
            width: 40, height: 30, url: "https://example.com/hero", title: "Hero")
        try rig.share(width: 22, height: 33, url: "https://example.com/second")
        try rig.shareLink("https://example.com/an-article")

        let archive = try rig.export(named: "Atelier 2026-08-17 2005")
        let summary = await rig.importIntoMac(archive)

        #expect(summary.outcome == .succeeded)
        #expect(summary.destinationName == "Atelier 2026-08-17 2005")
        #expect(summary.collections == 1)
        #expect(summary.assets == 3)
        #expect(summary.newAssets == 3)
        #expect(summary.memberships == 3)
        #expect(summary.skipped == 0)
        #expect(summary.failed == 0)
        // Nothing in the folder went unreferenced: the manifest accounts for every file
        // the phone copied, which is the claim a share sheet is implicitly making.
        #expect(summary.unreferenced == 0)

        let destination = try #require(try await rig.destination("Atelier 2026-08-17 2005"))
        let landing = try #require(try await rig.landing(under: destination))
        let items = try await rig.items(in: landing.id)
        #expect(items.count == 3)

        // Provenance verbatim — the property the whole format was chosen for.
        let arrived = try #require(items.first { $0.source.originalURL == "https://example.com/hero" })
        #expect(arrived.source.platform == .web)
        #expect(arrived.source.authorName == "A Designer")
        #expect(arrived.source.title == "Hero")
        #expect(arrived.asset.kind == .image)
        #expect(arrived.asset.width == 40)
        #expect(arrived.asset.height == 30)
        #expect(arrived.asset.downloadState == .downloaded)

        // The bytes themselves, at the address the phone computed for them: the Mac
        // re-hashes what it stores, so this equality is what makes dedup possible at all.
        let hash = try #require(arrived.asset.blobHash)
        #expect(hash == (try ContentHasher.hash(contentsOf: rig.payloadURL(hero))))
        #expect(rig.macStore.hasBlob(
            hash: hash,
            fileExtension: LibraryMediaPaths.fileExtension(forMIMEType: "image/jpeg")))

        // The media-less one crossed on its payload alone.
        let link = try #require(items.first { $0.asset.kind == .link })
        #expect(link.asset.blobHash == nil)
        #expect(AssetPayload(jsonString: link.asset.payload)?.link?.url
            == "https://example.com/an-article")

        // **And the phone still has all three.** 417's rule, measured from the far end:
        // an export copies, so a user whose AirDrop failed has lost nothing.
        #expect(try rig.pendingCount() == 3)
    }

    /// The phone's captures land in a container named after the folder, NOT merged into
    /// the Mac's own Unsorted — rule 1 of the replay layer, which never writes into a
    /// collection the user already has. Worth pinning because it is a decision, not an
    /// accident: an import that merged would be unreviewable and unundoable.
    @Test("An import lands in its own container, leaving the Mac's Unsorted alone")
    func landsInItsOwnContainer() async throws {
        let rig = try PhoneToMacRig.make()
        defer { rig.cleanup() }
        try rig.share(url: "https://example.com/one")

        let archive = try rig.export(named: "Atelier 2026-08-17 2005")
        #expect(await rig.importIntoMac(archive).outcome == .succeeded)

        #expect(try await rig.items(in: Collection.unsortedID).isEmpty)
        let destination = try #require(try await rig.destination("Atelier 2026-08-17 2005"))
        let landing = try #require(try await rig.landing(under: destination))
        #expect(try await rig.items(in: landing.id).count == 1)
    }

    /// **Importing the same folder twice.** The AirDrop the user re-sent because they
    /// weren't sure the first one landed. Two containers — the importer never merges — but
    /// ONE asset each, because 18A matched on the provenance the archive carried verbatim.
    @Test("Importing the same archive twice does not double the assets")
    func importingTwiceCollapses() async throws {
        let rig = try PhoneToMacRig.make()
        defer { rig.cleanup() }
        try rig.share(url: "https://example.com/one")
        try rig.share(url: "https://example.com/two")
        try rig.shareLink("https://example.com/three")

        let archive = try rig.export(named: "Atelier 2026-08-17 2005")
        let first = await rig.importIntoMac(archive)
        let second = await rig.importIntoMac(archive)

        #expect(first.newAssets == 3)
        #expect(second.outcome == .succeeded)
        #expect(second.assets == 3)
        // Every asset the second run touched was already here.
        #expect(second.newAssets == 0)
        #expect(try await rig.macAssetCount() == 3)

        // Two containers, not one clobbered — the destination rule. The SECOND one's
        // name is asserted only as "different", deliberately: `Validation`'s Finder-style
        // disambiguation strips a trailing integer before numbering, so this actually
        // arrives as "Atelier 2026-08-17 2" — the export's time of day read as a copy
        // index and thrown away. Cosmetic, and a property of a core naming rule (043 ·
        // 2c) that every collection in the app shares, so pinning the wart here would
        // make S6c the thing that has to change when the rule is fixed.
        #expect(second.destinationName != first.destinationName)
        #expect(try await rig.destination(first.destinationName) != nil)
        #expect(try await rig.destination(second.destinationName) != nil)
    }

    /// **The consequence of keeping the records (417).** The phone does not empty its
    /// inbox after an export, so tomorrow's export contains today's captures again. Two
    /// DIFFERENT folders, written at different times, carrying overlapping records: the
    /// Mac must end up with three assets, not five.
    ///
    /// This is the case that would fail if `InboxArchive` stamped anything time-of-export
    /// into the provenance it writes — a fresh `capturedAt`, a regenerated URL — because
    /// dedup would then see two different sources over the same bytes.
    @Test("Two exports of an inbox that kept its records import as one library")
    func overlappingExportsCollapse() async throws {
        let rig = try PhoneToMacRig.make()
        defer { rig.cleanup() }

        let monday = Date(timeIntervalSince1970: 1_700_000_000)
        try rig.share(width: 40, height: 30, url: "https://example.com/one", at: monday)
        try rig.share(width: 22, height: 33, url: "https://example.com/two", at: monday)
        let first = try rig.export(named: "Atelier 2026-08-17 2005", at: monday)

        // Tuesday: one new capture, and the two from Monday still sitting there.
        let tuesday = monday.addingTimeInterval(86_400)
        try rig.share(width: 18, height: 24, url: "https://example.com/three", at: tuesday)
        let second = try rig.export(named: "Atelier 2026-08-18 0910", at: tuesday)
        #expect(try rig.pendingCount() == 3)

        #expect(await rig.importIntoMac(first).newAssets == 2)
        let tuesdayRun = await rig.importIntoMac(second)

        #expect(tuesdayRun.outcome == .succeeded)
        #expect(tuesdayRun.assets == 3)
        // Only the capture Monday's archive did not contain.
        #expect(tuesdayRun.newAssets == 1)
        #expect(try await rig.macAssetCount() == 3)
    }

    /// **Newest-first on the Mac is the order things were captured on the PHONE.**
    /// `InboxArchive` stamps `record.capturedAt` into the asset's `created_at` rather than
    /// letting the import stamp its own clock — the same fix 092 · S3's review made for
    /// library archives, which matters more here because these captures have never been
    /// anywhere else. Without it a phone import collapses to one instant and reads in
    /// whatever order the drain happened to walk.
    ///
    /// Seeded middle, oldest, newest, so an export that replayed in file order, in write
    /// order, or backwards would all fail this.
    @Test("Capture time survives the trip, so Newest reads as it did on the phone")
    func captureTimeSurvives() async throws {
        let rig = try PhoneToMacRig.make()
        defer { rig.cleanup() }

        let day = 86_400.0
        let epoch = 1_700_000_000.0
        let seeds: [(url: String, offset: Double)] = [
            ("https://example.com/beta", 2 * day),
            ("https://example.com/alpha", 0),
            ("https://example.com/gamma", 5 * day),
        ]
        for (index, seed) in seeds.enumerated() {
            try rig.share(
                width: 10 + index, height: 8 + index, url: seed.url,
                at: Date(timeIntervalSince1970: epoch + seed.offset))
        }

        let archive = try rig.export(named: "Atelier 2026-08-17 2005")
        #expect(await rig.importIntoMac(archive).outcome == .succeeded)

        let destination = try #require(try await rig.destination("Atelier 2026-08-17 2005"))
        let landing = try #require(try await rig.landing(under: destination))
        let newest = try await rig.items(in: landing.id, sort: .newest)
        #expect(newest.map(\.source.originalURL) == [
            "https://example.com/gamma",
            "https://example.com/beta",
            "https://example.com/alpha",
        ])
        // Not merely the same ORDER — the same instants. A trip that preserved the
        // sequence by luck of insert order would pass the line above.
        #expect(newest.map(\.asset.createdAt) == seeds.sorted { $0.offset > $1.offset }
            .map { Date(timeIntervalSince1970: epoch + $0.offset) })
    }
}
