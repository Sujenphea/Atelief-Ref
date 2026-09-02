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

    // MARK: - One screen

    /// Everything one grid screen needs, from ONE read of the collection.
    ///
    /// The collection itself is in here because the screen needs its name AND because
    /// the items read needs its `sortMode`; see ``BrowseLibrary/feed(for:)`` for why
    /// that makes it the one read that cannot be concurrent with the others.
    public struct Feed: Sendable, Equatable {
        public let collection: Collection
        /// In the collection's own persisted order, archived items excluded.
        public let items: [CollectionItemDetail]
        /// Direct children, in manual order.
        public let subcollections: [Collection]

        public init(
            collection: Collection,
            items: [CollectionItemDetail],
            subcollections: [Collection]
        ) {
            self.collection = collection
            self.items = items
            self.subcollections = subcollections
        }
    }

    /// One screen's contents: the collection, its items and its direct children.
    ///
    /// **One collection read, not two** (098 · finding 13). The screen used to ask this
    /// type three questions concurrently — `collection(id:)`, `items(in:)`,
    /// `subcollections(of:)` — and `items(in:)` opened with a `getCollection` of its own
    /// to find the sort mode. So every reload read the collection row twice, once for a
    /// name and once for an enum, and the second read was invisible at the call site.
    ///
    /// **The shape is a dependency, not a preference.** The order the items come back in
    /// is a property OF the collection (007 · G4 — the Mac writes it and the phone must
    /// not override it), so the sort mode has to be in hand before the items request can
    /// be built. What CAN overlap still does: once the collection is read, the items and
    /// the children go out together and the latency is the slower one rather than their
    /// sum (009 · 16A). Three reads, two of them concurrent, where there were four.
    ///
    /// `.notFound` if the collection is absent — which is the screen's error state and
    /// not an empty grid, because "this folder is gone" and "this folder is empty" are
    /// different sentences.
    public func feed(for collectionID: UUID) async throws -> Feed {
        let collection = try await services.getCollection(id: collectionID)
        async let itemsRead = services.collectionItems(
            in: collectionID, sort: collection.sortMode, includeArchived: false)
        async let childrenRead = services.childCollections(of: collectionID)
        let (items, children) = try await (itemsRead, childrenRead)
        return Feed(
            collection: collection,
            items: items,
            subcollections: children.sorted(by: BrowseCollectionTree.byManualOrder))
    }

    /// ONE membership of a collection, by the pair of ids a navigation value carries;
    /// `nil` when that collection has no such item, `.notFound` when the collection
    /// itself is gone.
    ///
    /// The detail screen's read. It used to be ``items(in:)`` plus a `first { }`, which
    /// is the whole P14 join — 0.293 s at 5,000 rows (`.change-log/450`) — to keep one
    /// row and drop the rest, paid on every tap. Archived items are excluded here for
    /// the same reason they are excluded from the grid: an item hidden from the
    /// collection must not still be reachable by deep-linking its id.
    public func item(_ itemID: UUID, in collectionID: UUID) async throws
        -> CollectionItemDetail? {
        try await services.collectionItem(
            in: collectionID, id: itemID, includeArchived: false)
    }

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
