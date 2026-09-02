// AtelierBrowse — what the phone is currently showing (092 · S5, moved here by 098 · P3).
//
// Two observable objects over ``BrowseLibrary``, and the split between them is
// load-bearing.
//
// ``BrowseStore`` is the LIBRARY: opened once, holding the collection tree, the
// media-path resolvers, and the reason the library is unavailable when it is. There is
// exactly one, and it lives for the process.
//
// ``CollectionFeed`` is ONE SCREEN'S contents. There is one per grid on the navigation
// stack, because a pushed subcollection and the root it was pushed from are both on
// screen in the user's mental model and going Back must not find the root showing the
// child's items. A single shared `items` array would do exactly that, and it is the kind
// of bug that only appears once someone has a subcollection.
//
// **Why these are here and not in `AtelierRefsMobile` any more.** They were written in
// the app target on the reading that `@MainActor` state is "the part that cannot be
// tested without a phone" — which is the same reading `InboxDrainScheduler` was written
// under, and 455 is what that cost: two bugs, both in the direction the changelog claimed
// they were right, both found the first time a test could ask. Neither of these types
// imports SwiftUI or UIKit. What genuinely could not move is one call to
// `LibraryLocation.resolvedRoot()`, which reads `CommandLine.arguments`, and one debug
// fixture seed — so both are INJECTED (``BrowseStore/init(root:prepare:)``) and the app's
// file is the two closures that supply them.
//
// 098 · finding 9 counted what remained untestable before this move: the bootstrap failure
// mapping, the feed's generation guard and the two unconditional stores below. The guard
// and the stores each had a defect or a cost that only a test would name; see
// ``CollectionFeed/load(_:from:)`` and ``BrowseStore/refreshCollections()``.

import AtelierCore
import AtelierLibraryPaths
import Foundation
import Observation

@MainActor
@Observable
public final class BrowseStore {
    /// Whether there is a library to read at all.
    public enum Phase: Equatable {
        case loading
        case ready
        /// The library could not be opened. On iOS this is very likely the App Group —
        /// 092 · S1 · decision 3 made a missing container a typed FATAL error rather
        /// than a fallback, precisely so a provisioning bug fails where it is fixable,
        /// and 093 § 7 notes that something has to render that and nothing did. This is
        /// that something, worded by ``BrowseFailure``.
        case failed(String)
    }

    /// Where the library lives. Throwing, because on iOS resolving it is a real
    /// operation that really fails — an App Group the entitlement does not grant — and
    /// the failure is the one the phone's error screen exists for.
    ///
    /// A closure rather than a `URL`, so the app can hand over
    /// `LibraryLocation.resolvedRoot`, which reads `CommandLine.arguments` and therefore
    /// cannot be spelled inside a package a test drives.
    ///
    /// `@MainActor`, like ``RootPreparation`` and like ``InboxWork``: both of these ran
    /// inside a `@MainActor func bootstrap()` before the move and still do, and saying so
    /// keeps that fact in the type rather than leaving the app to rediscover it. The seed
    /// in particular is a wipe-and-rewrite of a whole library on the launch path, which is
    /// worth being able to see.
    public typealias RootResolver = @MainActor () throws -> URL

    /// Something to do to the root BEFORE the library is opened. The debug fixture seed
    /// and nothing else: it wipes and rewrites the root, and a pool already open on the
    /// old file would be reading a deleted inode.
    public typealias RootPreparation = @MainActor (URL) async throws -> Void

    public private(set) var phase: Phase = .loading
    /// The whole collection tree, for the switcher sheet.
    public private(set) var collections: [BrowseCollectionNode] = []
    /// One thumbnail per collection, for the switcher's rows (093 § 2). Keyed by
    /// collection id; **absent means there is nothing to show**, and the row draws a
    /// folder rather than an empty frame.
    public private(set) var collectionCovers: [UUID: URL] = [:]
    /// Which collection the ROOT grid shows. Unsorted at launch, always, in v1
    /// (093 § 2) — it is where every share lands (092 · S3), so it is the answer to
    /// "what did I save" by construction.
    public var rootCollectionID: UUID = BrowseLibrary.rootCollectionID

    /// Where the library lives — the inbox hangs off the same root, and the export
    /// controller needs it. Set once bootstrap has resolved it.
    public private(set) var libraryRoot: URL?

    /// What the last drain pass is worth telling the user, or `nil` (098 · P6).
    ///
    /// **Why the store holds it.** The drain is not a screen and has no view of its own;
    /// the thing it changes is this library, and every screen that would show the notice is
    /// already observing this object for ``ingestGeneration``. A second observable for one
    /// optional string would be a second lifetime to get wrong.
    ///
    /// The sentence is decided by `DrainSummary.userNotice` in `AtelierIngestion`, which
    /// this package deliberately does not link — so it arrives as a `String?` through
    /// ``noteDrain(notice:)``, the same shape ``noteIngest()`` has and for the same reason.
    ///
    /// **Assigned unconditionally by a pass, including to `nil`.** The notice describes the
    /// LAST pass, not the history: a quarantine reported at launch and then not reproduced
    /// is a stale alarm, and the phone drains on every activation, so a condition that
    /// still holds will say so again within seconds.
    public private(set) var drainNotice: String?

    /// Bumped once per drain pass that put something new in the library (096 · 4).
    ///
    /// A counter rather than a notification or a callback into the feed, because there is
    /// one grid per screen on the navigation stack and each owns its own
    /// ``CollectionFeed`` — a store that held references to them would be holding views.
    /// A screen keys its load on this alongside its collection id, so a capture that lands
    /// while the user is looking at the grid appears in it. The value means nothing; only
    /// that it changed does.
    public private(set) var ingestGeneration = 0

    /// The one open database in this process — the browse seam reads through it and, since
    /// 096 · 4, the ingest pipeline writes through it.
    ///
    /// Held here rather than reached through ``BrowseLibrary``, which keeps its own copy
    /// `private` on purpose: that type is the READ seam and the way "v1 browse is
    /// read-only" survives contact with a UI is by the UI not being handed the verb. The
    /// drain is not the UI, so it is wired from here instead of by widening that seam.
    public private(set) var services: AppServices?

    private var library: BrowseLibrary?
    private let resolveRoot: RootResolver
    private let prepareRoot: RootPreparation?

    public init(root: @escaping RootResolver, prepare: RootPreparation? = nil) {
        self.resolveRoot = root
        self.prepareRoot = prepare
    }

    // MARK: - Bootstrap

    /// Resolve the root, open the library and read the collection tree. Idempotent.
    public func bootstrap() async {
        guard library == nil else { return }
        do {
            let root = try resolveRoot()
            // Before the library is opened: see ``RootPreparation``.
            try await prepareRoot?(root)
            // Opened here and composed into the browse seam, rather than letting the seam
            // open its own: 096 · 4 gave this process a writer as well as a reader, and
            // two `AppServices` over one file would be two pools and two migration passes
            // at launch for one library.
            let opened = try AppServices.open(libraryRoot: root)
            let browse = BrowseLibrary(root: root, services: opened)
            services = opened
            library = browse
            libraryRoot = root
            collections = try await browse.collectionTree()
            // Ready BEFORE the covers: the grid is what the user launched for and it
            // needs none of them, so gating first paint on a read only the sheet
            // consumes would spend launch latency on a screen nobody has asked for yet.
            phase = .ready
            await refreshCovers()
        } catch {
            phase = .failed(BrowseFailure.message(for: error))
        }
    }

    /// A drain pass put something new in the library (096 · 4).
    ///
    /// Only the counter moves. Re-reading the tree and the feed is the screens' job — they
    /// are keyed on this — and doing it here as well would be the same read twice, once for
    /// a screen that may not be on top of the stack.
    public func noteIngest() {
        ingestGeneration &+= 1
    }

    /// A drain pass finished; this is what it is worth saying, or `nil` for the ordinary
    /// pass (098 · P6). See ``drainNotice``.
    public func noteDrain(notice: String?) {
        drainNotice = notice
    }

    /// The user has read it. Separate from ``noteDrain(notice:)`` so that dismissing is not
    /// spelled as "a pass with nothing to say", which is a different fact.
    public func dismissDrainNotice() {
        drainNotice = nil
    }

    /// How many collections the library holds, Unsorted included.
    ///
    /// Off the tree the switcher already loaded, so it costs no read. Its one consumer is
    /// ``BrowseEmptyState/resolve(isUnsorted:itemCount:subcollectionCount:libraryCollectionCount:)``,
    /// which uses it to tell a phone that has never been shared to from one whose Unsorted
    /// is merely tidy.
    public var collectionCount: Int {
        BrowseCollectionTree.flattened(collections).count
    }

    /// Re-read the collection tree — after a switch, so a collection made on the Mac
    /// since launch is reachable.
    ///
    /// **Assigned only if it changed** (098 · finding 14) — and the finding's premise
    /// turned out to be false, which is worth stating here rather than only in a
    /// changelog.
    ///
    /// The finding read `collections = <the same tree>` and concluded that `@Observable`
    /// would publish it, costing the grid an extra body evaluation on every root reload
    /// (every collection switch, every drain pass that ingested) even though nothing on
    /// the phone creates a collection and the tree has almost always not changed.
    /// `BrowseStoreTests.observationAlreadySuppressesASameValueStore` is what happened
    /// when that was asked: since Swift 6.3 the `@Observable` macro's setter compares an
    /// `Equatable` stored property and does NOT notify when the value is unchanged. Both
    /// of this type's guarded properties are `Equatable`, so the extra evaluations the
    /// finding predicted were already not happening.
    ///
    /// The guard stays anyway, for one reason: it is the statement of the requirement,
    /// and the requirement currently rests on `[BrowseCollectionNode]` conforming to
    /// `Equatable`. A member added to that node without a conformance would silently
    /// restore the behaviour the finding described, with nothing to say so. The tests
    /// assert the PROPERTY — a reload that changes nothing invalidates nothing — and are
    /// indifferent to which of the two provides it.
    public func refreshCollections() async {
        guard let library else { return }
        if let tree = try? await library.collectionTree(), tree != collections {
            collections = tree
        }
        await refreshCovers()
    }

    /// Re-read the switcher's row thumbnails, for the tree as it currently stands.
    ///
    /// Never throws and never clears: a cover read that fails leaves the previous map in
    /// place and the rows that have no entry draw folders. This is decoration for a
    /// sheet — it must not be able to take out the library the way a failed tree read
    /// legitimately can. Guarded by `!=` for the reason ``refreshCollections()`` gives.
    private func refreshCovers() async {
        guard let library else { return }
        let ids = BrowseCollectionTree.flattened(collections).map(\.node.id)
        guard let covers = try? await library.collectionCovers(for: ids) else { return }
        if covers != collectionCovers { collectionCovers = covers }
    }

    /// Store the tree directly. `@testable` only, and it exists for exactly one test:
    /// asking the `@Observable` macro's setter, with no guard in front of it, whether it
    /// notifies for a value that did not change. Every other write to `collections` goes
    /// through ``refreshCollections()``.
    internal func setCollectionsForTesting(_ tree: [BrowseCollectionNode]) {
        collections = tree
    }

    // MARK: - Reads

    /// One screen's contents, from one collection read. See ``BrowseLibrary/feed(for:)``.
    public func feed(for id: UUID) async throws -> BrowseLibrary.Feed {
        try await requireLibrary().feed(for: id)
    }

    /// One membership, by the pair of ids a navigation value carries.
    public func item(_ itemID: UUID, in collectionID: UUID) async throws
        -> CollectionItemDetail? {
        try await requireLibrary().item(itemID, in: collectionID)
    }

    /// Every collection an asset is in. See ``BrowseLibrary/memberships(of:)``.
    public func memberships(of assetID: UUID) async throws -> [Collection] {
        try await requireLibrary().memberships(of: assetID)
    }

    // MARK: - Media

    public func gridThumbnailURL(for asset: Asset) -> URL? {
        library?.gridThumbnailURL(for: asset)
    }

    public func detailImageURL(for asset: Asset) -> URL? {
        library?.detailImageURL(for: asset)
    }

    // MARK: - Errors

    private func requireLibrary() throws -> BrowseLibrary {
        guard let library else { throw LibraryUnavailable() }
        return library
    }

    /// The library is not open — the phase already says why, so this carries nothing.
    public struct LibraryUnavailable: Error {
        public init() {}
    }
}

// MARK: - One grid's contents

/// One grid's contents. Owned by the screen that shows it, not by the library.
@MainActor
@Observable
public final class CollectionFeed {
    public private(set) var name: String = ""
    public private(set) var items: [CollectionItemDetail] = []
    public private(set) var subcollections: [Collection] = []
    public private(set) var error: String?
    public private(set) var hasLoaded = false

    /// Supersedes an in-flight load, the same guard `IngestionModel.loadContents(of:)`
    /// uses: the reads can finish out of order, and a stale one must not overwrite the
    /// current collection's content.
    private var generation = 0

    public init() {}

    /// Load `id` through `store`. The ordinary entry point.
    public func load(_ id: UUID, from store: BrowseStore) async {
        await load { try await store.feed(for: id) }
    }

    /// Load from an arbitrary read.
    ///
    /// The seam the generation guard is testable through: a test parks one read on a gate
    /// and starts a second, which is the interleaving the guard exists for and which no
    /// arrangement of a real library can produce on demand. The claim is that the
    /// generation is bumped SYNCHRONOUSLY on entry — before the first suspension — so
    /// that a load started after this one always wins, whichever finishes first.
    public func load(_ read: @MainActor () async throws -> BrowseLibrary.Feed) async {
        generation &+= 1
        let mine = generation
        do {
            let feed = try await read()
            guard mine == generation else { return }
            name = feed.collection.name
            items = feed.items
            subcollections = feed.subcollections
            error = nil
            hasLoaded = true
        } catch {
            guard mine == generation else { return }
            self.error = BrowseFailure.message(for: error)
            hasLoaded = true
        }
    }
}
