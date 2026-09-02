// AtelierBrowse tests — the phone's read seam, against a real library.
//
// A real migrated SQLite file and real `AppServices` writes, not a fake: the point of
// this type is that it reads through the SAME surface the Mac's grid reads through, and
// a stub would prove that a stub returns what it was told to.
//
// What is being pinned: the collection's own persisted sort mode is honoured rather
// than overridden, archived items are excluded, Unsorted exists by migration, the
// thumbnail paths land where the media store puts them, and the detail tier falls back.

import Foundation
import Testing

import AtelierCapture
import AtelierCore
import AtelierLibraryPaths
@testable import AtelierBrowse

@Suite("BrowseLibrary (092 S5)")
struct BrowseLibraryTests {

    // MARK: - Collections

    @Test("a fresh library opens on Unsorted, which the migration guarantees")
    func opensOnUnsorted() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let tree = try await fixture.library.collectionTree()
        #expect(tree.contains { $0.id == BrowseLibrary.rootCollectionID })
        let unsorted = try await fixture.library.collection(id: BrowseLibrary.rootCollectionID)
        #expect(unsorted.name.isEmpty == false)
    }

    @Test("the tree carries collections created since the library opened")
    func treeSeesNewCollections() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let made = try await fixture.services.createCollection(name: "Textures")
        let child = try await fixture.services.createCollection(
            name: "Concrete", parent: made.id)

        let tree = try await fixture.library.collectionTree()
        // Unsorted is pinned first (093 § 2), so the new root follows it.
        #expect(tree.first?.id == BrowseLibrary.rootCollectionID)
        let node = BrowseCollectionTree.node(made.id, in: tree)
        #expect(node?.children.map(\.collection.name) == ["Concrete"])
        #expect(BrowseCollectionTree.node(child.id, in: tree) != nil)
    }

    // MARK: - Items

    @Test("items come back in the collection's OWN persisted sort mode")
    func honoursPersistedSortMode() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        // Three captures, ingested oldest first, so manual order and newest order are
        // reverses of each other and the two modes are distinguishable.
        let first = try await fixture.ingest(hashSeed: 1, capturedAt: date(2024, 1, 1))
        let second = try await fixture.ingest(hashSeed: 2, capturedAt: date(2025, 1, 1))
        let third = try await fixture.ingest(hashSeed: 3, capturedAt: date(2026, 1, 1))

        let manual = try await fixture.library.items(in: BrowseLibrary.rootCollectionID)
        #expect(manual.map(\.asset.id) == [first, second, third])

        try await fixture.services.setCollectionSortMode(
            .newest, for: BrowseLibrary.rootCollectionID)
        let newest = try await fixture.library.items(in: BrowseLibrary.rootCollectionID)
        #expect(newest.map(\.asset.id) == [third, second, first])
    }

    @Test("an archived item is hidden from browse but keeps its membership")
    func archivedExcluded() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let kept = try await fixture.ingest(hashSeed: 1, capturedAt: date(2026, 1, 1))
        let shelved = try await fixture.ingest(hashSeed: 2, capturedAt: date(2026, 1, 2))
        _ = try await fixture.services.archive([shelved])

        let items = try await fixture.library.items(in: BrowseLibrary.rootCollectionID)
        #expect(items.map(\.asset.id) == [kept])
    }

    @Test("an unknown collection is a typed not-found, not an empty grid")
    func unknownCollection() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        await #expect(throws: AtelierError.self) {
            _ = try await fixture.library.items(in: UUID())
        }
    }

    @Test("one asset reads back with its provenance")
    func assetDetail() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let id = try await fixture.ingest(hashSeed: 7, capturedAt: date(2026, 5, 5))
        let detail = try await fixture.library.asset(id: id)
        #expect(detail.asset.id == id)
        #expect(detail.source.platform == .web)
    }

    // MARK: - Media paths

    @Test("the grid tile's thumbnail is the 512 tier under the library root")
    func gridThumbnailPath() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let id = try await fixture.ingest(hashSeed: 1, capturedAt: date(2026, 1, 1))
        let detail = try await fixture.library.asset(id: id)
        let url = fixture.library.gridThumbnailURL(for: detail.asset)

        #expect(url == LibraryMediaPaths.thumbnailURL(
            libraryRoot: fixture.root, hash: detail.asset.blobHash!,
            size: LibraryMediaPaths.gridThumbnailSize, fileExtension: "jpg"))
    }

    @Test("a media-less kind has no thumbnail at all")
    func mediaLessHasNoThumbnail() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let result = try await fixture.services.ingestContent(
            AssetContentDraft.color(hex: "#ff0000"),
            from: SourceDraft(platform: .localPaste, capturedAt: Date()),
            into: BrowseLibrary.rootCollectionID)
        let detail = try await fixture.library.asset(id: result.asset.id)

        #expect(fixture.library.gridThumbnailURL(for: detail.asset) == nil)
        #expect(fixture.library.detailImageURL(for: detail.asset) == nil)
    }

    @Test("the detail image prefers 1280 and falls back to 512")
    func detailTierFallback() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let id = try await fixture.ingest(hashSeed: 4, capturedAt: date(2026, 1, 1))
        let asset = try await fixture.library.asset(id: id).asset
        let hash = asset.blobHash!

        // Nothing on disk yet — this library has metadata but no generated tiers.
        #expect(fixture.library.detailImageURL(for: asset) == nil)

        try fixture.writeThumbnail(hash: hash, size: LibraryMediaPaths.gridThumbnailSize)
        #expect(fixture.library.detailImageURL(for: asset)?.lastPathComponent
            == "\(hash)@\(LibraryMediaPaths.gridThumbnailSize).jpg")

        try fixture.writeThumbnail(hash: hash, size: LibraryMediaPaths.detailThumbnailSize)
        #expect(fixture.library.detailImageURL(for: asset)?.lastPathComponent
            == "\(hash)@\(LibraryMediaPaths.detailThumbnailSize).jpg")
    }

    // MARK: - Switcher covers

    @Test("a collection with no cover set still has a picture: its newest member")
    func coversFallBackToNewestMember() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        try await fixture.ingest(hashSeed: 1, capturedAt: date(2026, 1, 1))
        let newest = try await fixture.ingest(hashSeed: 2, capturedAt: date(2026, 1, 2))
        let hash = try await fixture.library.asset(id: newest).asset.blobHash!

        let covers = try await fixture.library.collectionCovers(
            for: [BrowseLibrary.rootCollectionID])
        // The 512 tier's path, exactly as a tile would ask for it — the switcher and the
        // grid share a decode cache keyed by path, so a disagreement here would be two
        // decodes of one file rather than a wrong picture.
        #expect(covers[BrowseLibrary.rootCollectionID]
            == fixture.library.gridThumbnailURL(forHash: hash))
    }

    @Test("an empty collection is absent from the covers, so its row can draw a folder")
    func emptyCollectionHasNoCover() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let empty = try await fixture.services.createCollection(name: "Type")
        let covers = try await fixture.library.collectionCovers(
            for: [BrowseLibrary.rootCollectionID, empty.id])
        #expect(covers[empty.id] == nil)
    }

    @Test("an archived newest member does not become a collection's cover")
    func archivedMemberIsNotACover() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }

        let kept = try await fixture.ingest(hashSeed: 1, capturedAt: date(2026, 1, 1))
        let shelved = try await fixture.ingest(hashSeed: 2, capturedAt: date(2026, 1, 2))
        _ = try await fixture.services.archive([shelved])
        let hash = try await fixture.library.asset(id: kept).asset.blobHash!

        let covers = try await fixture.library.collectionCovers(
            for: [BrowseLibrary.rootCollectionID])
        #expect(covers[BrowseLibrary.rootCollectionID]
            == fixture.library.gridThumbnailURL(forHash: hash))
    }

    // MARK: - Fixtures

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}

/// A real, migrated library in a temporary directory, plus the ``BrowseLibrary`` over
/// it — sharing ONE `AppServices` so a seeded write is visible to the read under test.
struct TempBrowseLibrary {
    let root: URL
    let services: AppServices
    let library: BrowseLibrary

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierBrowseTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = try AppServices.open(libraryRoot: root)
        library = BrowseLibrary(root: root, services: services)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Ingest one byte-backed capture into Unsorted, returning its asset id. Every
    /// seed yields a distinct blob hash so 18A dedup never collapses two of them.
    @discardableResult
    func ingest(hashSeed: Int, capturedAt: Date) async throws -> UUID {
        let hash = String(format: "%064x", hashSeed)
        let result = try await services.ingest(
            AssetDraft(
                kind: .image, blobHash: hash, mimeType: "image/jpeg",
                width: 800, height: 600, fileSize: 1234, downloadState: .downloaded),
            from: SourceDraft(
                platform: .web, originalURL: "https://example.com/\(hashSeed)",
                authorName: "Ada", title: "Capture \(hashSeed)", capturedAt: capturedAt),
            into: BrowseLibrary.rootCollectionID)
        return result.asset.id
    }

    /// Put a byte at the tier's path so the fallback has something to find.
    func writeThumbnail(hash: String, size: Int) throws {
        let url = LibraryMediaPaths.thumbnailURL(
            libraryRoot: root, hash: hash, size: size, fileExtension: "jpg")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF]).write(to: url)
    }
}
