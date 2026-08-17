// AtelierRefsMobile — what the phone is currently showing (092 · S5).
//
// Two observable objects over ``BrowseLibrary``, and the split between them is
// load-bearing.
//
// ``LibraryStore`` is the LIBRARY: opened once, holding the collection tree, the
// media-path resolvers, and the reason the library is unavailable when it is. There is
// exactly one, and it lives for the process.
//
// ``CollectionFeed`` is ONE SCREEN'S contents. There is one per grid on the navigation
// stack, because a pushed subcollection and the root it was pushed from are both on
// screen in the user's mental model and going Back must not find the root showing the
// child's items. A single shared `items` array would do exactly that, and it is the
// kind of bug that only appears once someone has a subcollection.
//
// Both are deliberately thin. The ordering, the tree, the masonry decomposition and the
// media paths live in `AtelierBrowse`, where `swift test` can reach them; what is here
// is the part that cannot be tested without a phone — `@MainActor` state, a load
// generation counter, and the mapping from a typed error to a sentence.

import AtelierBrowse
import AtelierCapture
import AtelierCore
import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    /// Whether there is a library to read at all.
    enum Phase: Equatable {
        case loading
        case ready
        /// The library could not be opened. On iOS this is very likely the App Group —
        /// 092 · S1 · decision 3 made a missing container a typed FATAL error rather
        /// than a fallback, precisely so a provisioning bug fails where it is fixable,
        /// and 093 § 7 notes that something has to render that and nothing did. This is
        /// that something.
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// The whole collection tree, for the switcher sheet.
    private(set) var collections: [BrowseCollectionNode] = []
    /// One thumbnail per collection, for the switcher's rows (093 § 2). Keyed by
    /// collection id; **absent means there is nothing to show**, and the row draws a
    /// folder rather than an empty frame.
    private(set) var collectionCovers: [UUID: URL] = [:]
    /// Which collection the ROOT grid shows. Unsorted at launch, always, in v1
    /// (093 § 2) — it is where every share lands (092 · S3), so it is the answer to
    /// "what did I save" by construction.
    var rootCollectionID: UUID = BrowseLibrary.rootCollectionID

    private var library: BrowseLibrary?

    // MARK: - Bootstrap

    /// Open the library and read the collection tree. Idempotent.
    func bootstrap() async {
        guard library == nil else { return }
        do {
            // `resolvedRoot()`, not `defaultRoot()`, for the reason the Mac uses it:
            // with no `-library-root` argument and no `ATELIER_LIBRARY_ROOT` it IS
            // `defaultRoot()` byte for byte, and with one it is the throwaway-library
            // escape hatch tests and seeded verification runs depend on.
            let root = try LibraryLocation.resolvedRoot()
            // Before the library is opened, because seeding wipes and rewrites the root
            // and a pool already on the old file would be reading a deleted inode. Debug
            // builds only, launch-argument gated, and it refuses a non-throwaway root —
            // see `FixtureLibrary`'s header.
            #if DEBUG
            if FixtureLibrary.isRequested { try await FixtureLibrary.seed(at: root) }
            #endif
            let opened = try BrowseLibrary(root: root)
            library = opened
            collections = try await opened.collectionTree()
            // Ready BEFORE the covers: the grid is what the user launched for and it
            // needs none of them, so gating first paint on a read only the sheet
            // consumes would spend launch latency on a screen nobody has asked for yet.
            phase = .ready
            await refreshCovers()
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Re-read the collection tree — after a switch, so a collection made on the Mac
    /// since launch is reachable.
    func refreshCollections() async {
        guard let library else { return }
        collections = (try? await library.collectionTree()) ?? collections
        await refreshCovers()
    }

    /// Re-read the switcher's row thumbnails, for the tree as it currently stands.
    ///
    /// Never throws and never clears: a cover read that fails leaves the previous map in
    /// place and the rows that have no entry draw folders. This is decoration for a
    /// sheet — it must not be able to take out the library the way a failed tree read
    /// legitimately can.
    private func refreshCovers() async {
        guard let library else { return }
        let ids = BrowseCollectionTree.flattened(collections).map(\.node.id)
        guard let covers = try? await library.collectionCovers(for: ids) else { return }
        collectionCovers = covers
    }

    // MARK: - Reads

    func collection(id: UUID) async throws -> Collection {
        try await requireLibrary().collection(id: id)
    }

    func items(in id: UUID) async throws -> [CollectionItemDetail] {
        try await requireLibrary().items(in: id)
    }

    func subcollections(of id: UUID) async throws -> [Collection] {
        try await requireLibrary().subcollections(of: id)
    }

    // MARK: - Media

    func gridThumbnailURL(for asset: Asset) -> URL? {
        library?.gridThumbnailURL(for: asset)
    }

    func detailImageURL(for asset: Asset) -> URL? {
        library?.detailImageURL(for: asset)
    }

    // MARK: - Errors

    private func requireLibrary() throws -> BrowseLibrary {
        guard let library else { throw LibraryUnavailable() }
        return library
    }

    /// The library is not open — the phase already says why, so this carries nothing.
    struct LibraryUnavailable: Error {}

    /// One sentence per failure class. The typed payloads stay in the error; a person
    /// holding a phone is told what is wrong and, where it is actionable, that it is a
    /// setup problem rather than their library being gone.
    static func message(for error: Error) -> String {
        switch error {
        case LibraryLocationError.appGroupIdentifierMissing:
            "This build is missing its App Group. The library can't be opened."
        case LibraryLocationError.appGroupContainerUnavailable:
            "The App Group container isn't available. The library can't be opened."
        case let error as AtelierError:
            switch error {
            case .notFound: "That collection is no longer in the library."
            default: "The library couldn't be read."
            }
        default:
            "The library couldn't be opened."
        }
    }
}

/// One grid's contents. Owned by the screen that shows it, not by the library.
@MainActor
@Observable
final class CollectionFeed {
    private(set) var name: String = ""
    private(set) var items: [CollectionItemDetail] = []
    private(set) var subcollections: [Collection] = []
    private(set) var error: String?
    private(set) var hasLoaded = false

    /// Supersedes an in-flight load, the same guard `IngestionModel.loadContents(of:)`
    /// uses: the reads can finish out of order, and a stale one must not overwrite the
    /// current collection's content.
    private var generation = 0

    func load(_ id: UUID, from store: LibraryStore) async {
        generation &+= 1
        let mine = generation
        do {
            // Independent reads, so the latency is the slowest ONE rather than their
            // sum (009 · 16A).
            async let collectionRead = store.collection(id: id)
            async let itemsRead = store.items(in: id)
            async let subcollectionsRead = store.subcollections(of: id)
            let (collection, loadedItems, loadedSubcollections) =
                try await (collectionRead, itemsRead, subcollectionsRead)
            guard mine == generation else { return }
            name = collection.name
            items = loadedItems
            subcollections = loadedSubcollections
            error = nil
            hasLoaded = true
        } catch {
            guard mine == generation else { return }
            self.error = LibraryStore.message(for: error)
            hasLoaded = true
        }
    }
}
