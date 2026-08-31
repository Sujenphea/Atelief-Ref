// AtelierBrowse — the phone's read seam over a library (092 · S5).
//
// One type, opened once at launch, holding the same `AppServices` the Mac's grid reads
// through and the library root the thumbnails hang off. Every method here is a READ.
// There is no write funnel on this type and there is deliberately no way to reach one:
// v1 browse is read-only (091 · D1), and the way an invariant like that survives
// contact with a UI is by the UI not being handed the verb.
//
// **One `DatabasePool`, opened by the app.** `AppServices.init(databasePath:)` opens a
// pool and migrates what it finds, which on a first launch is what creates the library
// and its Unsorted collection. The share extension still never opens SQLite (091 · D2)
// — it appends files to a directory and returns — so the phone has exactly one process
// on the database, which is the same shape the Mac has. Since 096 · 4 the companion app
// opens that pool itself and composes it in through ``init(root:services:)``, because the
// drain writes through the same `AppServices` this reads through.
//
// **What this does NOT do: drain the inbox.** Something does, now — the companion's
// `InboxDrainScheduler` runs `InboxDrain` at launch and on every foreground (096 · 4), so
// a capture made on the phone appears in the phone's own grid without a round trip through
// a Mac. It is still not THIS type, and the boundary is the point: there is no write funnel
// here and deliberately no way to reach one, because the way "v1 browse is read-only"
// (091 · D1) survives contact with a UI is by the UI not being handed the verb. The app
// wires the drain from beside this seam rather than through it.

import AtelierCapture
import AtelierCore
import AtelierLibraryPaths
import Foundation

/// The companion's read-only view of a library on disk.
public struct BrowseLibrary: Sendable {
    /// The library root — where `blobs/`, `thumbnails/` and the database live.
    public let root: URL

    /// The shared read surface. `private` so no caller can reach a mutation through
    /// this type; the read methods below are the whole API.
    private let services: AppServices

    /// Open (or create, and migrate) the library rooted at `root`.
    public init(root: URL) throws {
        try self.init(
            root: root,
            services: AppServices(
                databasePath: root
                    .appendingPathComponent(AtelierCore.databaseFileName)
                    .path))
    }

    /// Compose over an already-open `AppServices` — how the tests drive this without
    /// re-opening a pool over a library they just seeded.
    public init(root: URL, services: AppServices) {
        self.root = root
        self.services = services
    }

    // MARK: - Collections

    /// Every collection, as the phone's switcher tree (093 § 2).
    public func collectionTree() async throws -> [BrowseCollectionNode] {
        BrowseCollectionTree.tree(
            try await services.listCollections(), unsortedID: Collection.unsortedID)
    }

    /// One collection by id; `.notFound` if absent.
    public func collection(id: UUID) async throws -> Collection {
        try await services.getCollection(id: id)
    }

    /// The collection the phone opens on: Unsorted, always, in v1.
    ///
    /// It is where every share lands (092 · S3), so it is the answer to "what did I
    /// save" by construction. Restoring the last-viewed collection — which the Mac does
    /// (`NavModel.swift:51`–`:53`) — is a second mechanism and a preference the phone
    /// has not yet earned (093 § 2).
    public static let rootCollectionID = Collection.unsortedID

    // MARK: - Items

    /// A collection's items, in the collection's OWN persisted sort mode, archived
    /// items excluded.
    ///
    /// The sort mode is read rather than chosen: it is a property of the collection
    /// (007 · G4), the Mac writes it, and a phone that ignored it would show the same
    /// collection in a different order on the two devices for no reason a user could
    /// see. `includeArchived: false` is browse's side of 023 · A — an archived asset
    /// keeps its membership row and is hidden at the read.
    public func items(in collectionID: UUID) async throws -> [CollectionItemDetail] {
        let collection = try await services.getCollection(id: collectionID)
        return try await services.collectionItems(
            in: collectionID, sort: collection.sortMode, includeArchived: false)
    }

    /// The direct subcollections of `id`, in manual order.
    public func subcollections(of id: UUID) async throws -> [Collection] {
        try await services.childCollections(of: id)
            .sorted(by: BrowseCollectionTree.byManualOrder)
    }

    /// One asset with its provenance, for the detail screen; `.notFound` if absent.
    public func asset(id: UUID) async throws -> AssetDetail {
        try await services.getAsset(id: id)
    }

    // MARK: - Media

    /// The grid tile's thumbnail — the 512 tier — or `nil` for an asset with no bytes
    /// at all (a media-less kind with no card image, 003 · O1: the tile draws a swatch
    /// or a text card instead).
    ///
    /// Not stat'ed. A grid scrolls past hundreds of these and a missing thumbnail is
    /// something the image loader finds out anyway, one file open later, at the moment
    /// it was going to touch the disk regardless.
    public func gridThumbnailURL(for asset: Asset) -> URL? {
        asset.blobHash.map(gridThumbnailURL(forHash:))
    }

    /// The 512 tier for a blob hash — for a caller holding a hash rather than an asset,
    /// which is what the cover reads return.
    public func gridThumbnailURL(forHash hash: String) -> URL {
        LibraryMediaPaths.thumbnailURL(
            libraryRoot: root, hash: hash,
            size: LibraryMediaPaths.gridThumbnailSize, fileExtension: "jpg")
    }

    /// A representative thumbnail per collection, for the switcher's rows (093 § 2:
    /// "a reference library's collections are recognised by their contents, not their
    /// spelling").
    ///
    /// The explicit cover where one is set, and the collection's most recently added
    /// byte-backed member where none is — `fallingBackToRecent`, which exists because
    /// nothing sets a cover by default, so on a real library the un-fallen-back answer
    /// is a sheet of placeholders. The rule itself lives in `AppServices` rather than
    /// here, so this seam and the Mac's gallery cannot pick different pictures for the
    /// same folder.
    ///
    /// A collection with nothing to show is **absent** from the result rather than
    /// mapped to a `nil` URL — the row then draws a folder, which is what "empty" looks
    /// like, as opposed to "the tier has not been generated", which is what an absent
    /// file at a present URL looks like. Unstat'ed for the same reason
    /// ``gridThumbnailURL(for:)`` is: the image loader finds that out one file open
    /// later, and this is called with the whole tree.
    public func collectionCovers(for ids: [UUID]) async throws -> [UUID: URL] {
        try await services.collectionCovers(ids, fallingBackToRecent: true)
            .mapValues(gridThumbnailURL(forHash:))
    }

    /// The detail screen's image — the 1280 tier, falling back to the 512 tier when
    /// that file is absent, and `nil` when neither exists or the asset has no bytes.
    ///
    /// This one IS stat'ed, because there is exactly one of it on screen and the
    /// fallback is the difference between a soft image and no image. The fallback
    /// matters for a library older than the tier: `ThumbnailBackfill` fills gaps on the
    /// Mac, and a phone reading a library mid-backfill should show the tier that is
    /// there rather than nothing.
    ///
    /// The original in `blobs/` is deliberately never read — see
    /// ``LibraryMediaPaths/detailThumbnailSize``.
    public func detailImageURL(
        for asset: Asset, fileManager: FileManager = .default
    ) -> URL? {
        guard let hash = asset.blobHash else { return nil }
        for size in [LibraryMediaPaths.detailThumbnailSize,
                     LibraryMediaPaths.gridThumbnailSize] {
            let url = LibraryMediaPaths.thumbnailURL(
                libraryRoot: root, hash: hash, size: size, fileExtension: "jpg")
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
