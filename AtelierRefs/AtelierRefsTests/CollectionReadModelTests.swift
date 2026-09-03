//
//  CollectionReadModelTests.swift
//  AtelierRefsTests
//
//  099 · 1A / 13A — the per-window read model.
//
//  Most of these drive a STUB feed rather than a real library, and that is the
//  point of the phase rather than a shortcut: the read is injected, so "a
//  superseded load publishes nothing" can be asserted by holding one read open
//  instead of by racing two real queries and hoping. The two that need a real
//  `AppServices` — the saved-search feed and the ingest throttle — use one.
//
//  Every wait is a signal, never a sleep (099 · 11A): `CollectionReadModel.events`
//  says which load landed and which was superseded, and ``EventRecorder`` records
//  from before the work starts so a wait cannot lose a race it was written to win.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("CollectionReadModel (099 · 1A)", .timeLimit(.minutes(1)))
struct CollectionReadModelTests {

    // MARK: - A feed a test can hold open

    /// A stub ``CollectionFeed`` whose reads a test drives by hand.
    ///
    /// `park` names the ids whose read suspends until ``release()``; everything
    /// else answers immediately from `pages`. It emits `.parked` when a read
    /// suspends and `.read` when one starts, so a test awaits the state it needs
    /// rather than sleeping into it.
    @MainActor
    final class StubFeed {
        var pages: [UUID: CollectionFeed.Page] = [:]
        var failure: Error?
        var park: Set<UUID> = []
        private(set) var reads: [UUID] = []
        private var gate: CheckedContinuation<Void, Never>?
        let events = EventSignal<Event>()

        enum Event: Sendable, Equatable {
            case read(UUID)
            case parked(UUID)
        }

        func feed(carriesMembership: Bool = true) -> CollectionFeed {
            CollectionFeed(
                carriesMembership: carriesMembership,
                missingEntity: "collection",
                missingSentence: "That folder no longer exists.",
                read: { [self] id in
                    reads.append(id)
                    events.emit(.read(id))
                    if park.contains(id) {
                        events.emit(.parked(id))
                        await withCheckedContinuation { gate = $0 }
                    }
                    if let failure { throw failure }
                    return pages[id] ?? CollectionFeed.Page(items: [])
                })
        }

        /// Let the parked read finish.
        func release() {
            let waiting = gate
            gate = nil
            waiting?.resume()
        }
    }

    // MARK: - Fixtures

    private func item(_ order: Int, in collectionID: UUID) -> CollectionItemDetail {
        let assetID = UUID()
        let sourceID = UUID()
        return CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: collectionID, assetID: assetID,
                addedAt: Date(), manualOrder: order),
            asset: Asset(
                id: assetID, kind: .image, blobHash: String(format: "%040x", order),
                mimeType: "image/png", width: 10, height: 10, duration: nil,
                fileSize: 1, downloadState: .downloaded, createdAt: Date(),
                sourceId: sourceID),
            source: Source(id: sourceID, platform: .web, capturedAt: Date()))
    }

    private func makeModel(
        _ stub: StubFeed, carriesMembership: Bool = true
    ) -> CollectionReadModel {
        CollectionReadModel(
            feed: stub.feed(carriesMembership: carriesMembership),
            selectionStore: GridSelectionStore())
    }

    // MARK: - Load

    @Test("a load publishes the rows, the subfolders and the collection identity")
    func loadPublishes() async throws {
        let stub = StubFeed()
        let id = UUID()
        let child = Collection(
            id: UUID(), name: "Child", createdAt: Date(), updatedAt: Date(),
            parentCollectionID: id)
        stub.pages[id] = CollectionFeed.Page(
            items: [item(0, in: id), item(1, in: id)], subfolders: [child])
        let model = makeModel(stub)
        let recorder = EventRecorder(model.events.stream())

        #expect(model.loadedCollectionID == nil)
        model.load(id)
        await recorder.wait { $0.contains(.loaded(collectionID: id, count: 2)) }

        #expect(model.items.count == 2)
        #expect(model.subfolders.map(\.id) == [child.id])
        #expect(model.loadedCollectionID == id)
        #expect(model.contentsVersion == 1)
        // The derivations ran off the same publish — `displayItems` and the
        // selection store's order are what the grid actually draws.
        #expect(model.displayItems.count == 2)
        #expect(model.detailRun.count == 2)
    }

    // MARK: - The race guard

    @Test("a SUPERSEDED load publishes nothing at all")
    func supersededLoadPublishesNothing() async throws {
        let stub = StubFeed()
        let first = UUID()
        let second = UUID()
        stub.pages[first] = CollectionFeed.Page(items: [item(0, in: first)])
        stub.pages[second] = CollectionFeed.Page(
            items: [item(0, in: second), item(1, in: second)])
        stub.park = [first]

        let model = makeModel(stub)
        let recorder = EventRecorder(model.events.stream())
        let feedRecorder = EventRecorder(stub.events.stream())

        // The slow load starts and parks INSIDE the read.
        model.load(first)
        await feedRecorder.wait { $0.contains(.parked(first)) }
        // A newer load starts and finishes while the first is still in flight.
        model.load(second)
        await recorder.wait { $0.contains(.loaded(collectionID: second, count: 2)) }
        #expect(model.loadedCollectionID == second)

        // Now let the STALE read finish. It must publish nothing — not the rows,
        // not the identity, not even a version bump.
        let versionAfterSecond = model.contentsVersion
        stub.release()
        await recorder.wait { $0.contains(.superseded(collectionID: first)) }
        #expect(model.loadedCollectionID == second)
        #expect(model.items.count == 2)
        #expect(model.contentsVersion == versionAfterSecond)
    }

    @Test("a superseded FAILURE raises no alert for a collection already left")
    func supersededFailureSetsNoError() async throws {
        let stub = StubFeed()
        let first = UUID()
        let second = UUID()
        stub.pages[second] = CollectionFeed.Page(items: [item(0, in: second)])
        stub.park = [first]

        let model = makeModel(stub)
        let recorder = EventRecorder(model.events.stream())
        let feedRecorder = EventRecorder(stub.events.stream())

        model.load(first)
        await feedRecorder.wait { $0.contains(.parked(first)) }
        model.load(second)
        await recorder.wait { $0.contains(.loaded(collectionID: second, count: 1)) }

        // The parked read now fails — but it belongs to a collection the window has
        // already left, so its sentence must not reach the alert.
        stub.failure = AtelierError.notFound(entity: "collection", id: first)
        stub.release()
        await recorder.wait { $0.contains(.superseded(collectionID: first)) }
        #expect(model.lastError == nil)
    }

    // MARK: - Selection

    @Test("a reload prunes the selection to the rows that survived")
    func selectionPrunedToSurvivors() async throws {
        let stub = StubFeed()
        let id = UUID()
        let rows = [item(0, in: id), item(1, in: id), item(2, in: id)]
        stub.pages[id] = CollectionFeed.Page(items: rows)
        let model = makeModel(stub)
        let recorder = EventRecorder(model.events.stream())

        model.load(id)
        await recorder.wait { $0.contains(.loaded(collectionID: id, count: 3)) }
        model.selectionStore.replace(
            GridSelection(ids: Set(rows.map(\.item.id)), lead: rows[2].item.id))
        #expect(model.selectionStore.selection.ids.count == 3)

        // Two of the three leave the feed — including the LEAD, whose disappearance
        // is what auto-dismisses the detail overlay.
        stub.pages[id] = CollectionFeed.Page(items: [rows[0]])
        model.load(id)
        await recorder.wait { $0.contains(.loaded(collectionID: id, count: 1)) }

        #expect(model.selectionStore.selection.ids == [rows[0].item.id])
        #expect(model.selectionStore.selection.lead != rows[2].item.id)
    }

    // MARK: - Failure

    @Test("a fetch failure surfaces the feed's own sentence")
    func fetchFailureSetsLastError() async throws {
        let stub = StubFeed()
        let id = UUID()
        stub.failure = AtelierError.notFound(entity: "collection", id: id)
        let model = makeModel(stub)
        let recorder = EventRecorder(model.events.stream())

        model.load(id)
        await recorder.wait { $0.contains(.failed(collectionID: id)) }
        #expect(model.lastError == "That folder no longer exists.")
        #expect(model.loadedCollectionID == nil)
    }

    @Test("a failure the feed has no override for falls through to Core's table")
    func fetchFailureFallsThroughToLocalizedDescription() async throws {
        let stub = StubFeed()
        let id = UUID()
        // A `.notFound` on a DIFFERENT entity is not this feed's sentence to write:
        // P0 made `AtelierError: LocalizedError` with an exhaustive noun table, and
        // the app now asks for `localizedDescription` rather than restating it.
        let error = AtelierError.notFound(entity: "asset", id: UUID())
        stub.failure = error
        let model = makeModel(stub)
        let recorder = EventRecorder(model.events.stream())

        model.load(id)
        await recorder.wait { $0.contains(.failed(collectionID: id)) }
        #expect(model.lastError == error.localizedDescription)
        #expect(model.lastError != "That folder no longer exists.")
    }

    // MARK: - Change events

    @Test("a change event reloads only a MATCHING id, and always on nil")
    func changeEventReloadsOnlyMatchingID() async throws {
        let stub = StubFeed()
        let loaded = UUID()
        let other = UUID()
        stub.pages[loaded] = CollectionFeed.Page(items: [item(0, in: loaded)])
        let model = makeModel(stub)
        let recorder = EventRecorder(model.events.stream())
        let changes = PassthroughSubject<UUID?, Never>()
        model.follow(changes)

        // Nothing is loaded yet: a change of ANY shape must not fetch. A window that
        // has never shown a collection has no business reading one.
        changes.send(nil)
        changes.send(loaded)
        #expect(stub.reads.isEmpty)

        model.load(loaded)
        await recorder.wait { $0.contains(.loaded(collectionID: loaded, count: 1)) }
        #expect(stub.reads == [loaded])

        // A change naming a DIFFERENT collection is not this feed's business.
        changes.send(other)
        #expect(stub.reads == [loaded])

        // Its own id reloads it.
        changes.send(loaded)
        await recorder.wait { $0.filter { $0 == .loaded(collectionID: loaded, count: 1) }.count == 2 }
        #expect(stub.reads == [loaded, loaded])

        // `nil` — the producer cannot say which — reloads every feed.
        changes.send(nil)
        await recorder.wait { $0.filter { $0 == .loaded(collectionID: loaded, count: 1) }.count == 3 }
        #expect(stub.reads.count == 3)
    }

    // MARK: - The saved-search feed

    @Test("the saved-search feed carries rows and NO memberships")
    func savedSearchFeedHasNoMemberships() async throws {
        let dbPath = NSTemporaryDirectory() + "read-model-search-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let collection = try await services.createCollection(name: "Refs")
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/1", title: "teal swatch",
            capturedAt: Date())
        for hex in ["#112233", "#445566"] {
            _ = try await services.ingestContent(
                .color(hex: hex), from: source, into: collection.id)
        }
        let search = try await services.createSavedSearch(
            name: "Teal", rules: SearchRules(text: "swatch"))

        let model = CollectionReadModel(
            feed: .savedSearch(services), selectionStore: GridSelectionStore())
        let recorder = EventRecorder(model.events.stream())
        model.load(search.id)
        await recorder.wait { events in
            events.contains { if case .loaded = $0 { return true } else { return false } }
        }

        #expect(model.items.count == 2)
        #expect(model.loadedCollectionID == search.id)
        // A query is not a container: no tree beneath it…
        #expect(model.subfolders.isEmpty)
        // …and the synthesised rows carry the membership-less sentinel scope, which
        // is what `looseItems(for:)` stamps (048).
        #expect(model.items.allSatisfy {
            $0.item.collectionID == AssetDragPayload.nilSourceID
        })
        #expect(model.items.allSatisfy { $0.item.id == $0.asset.id })
    }

    /// **057's own named test** (*"Grid reuse: mid-triage vanish (item stops
    /// matching) drives one reload, no crash, selection pruned"*).
    ///
    /// The saved search is `favoritesOnly`, so un-starring a hit is the smallest
    /// real way to make an item stop matching WITHOUT deleting it — which is the
    /// whole point: the asset is still in the library and still in its collection,
    /// and the only thing that changed is whether it answers the query.
    @Test("an item that stops matching vanishes on the next reload, selection pruned")
    func savedSearchItemThatStopsMatchingVanishes() async throws {
        let dbPath = NSTemporaryDirectory() + "read-model-vanish-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let collection = try await services.createCollection(name: "Refs")
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/vanish", capturedAt: Date())
        var assets: [Asset] = []
        for hex in ["#112233", "#445566", "#778899"] {
            let outcome = try await services.ingestContent(
                .color(hex: hex), from: source, into: collection.id)
            assets.append(outcome.asset)
        }
        // Two of the three match.
        _ = try await services.setFavorite(true, for: [assets[0].id, assets[1].id])
        let search = try await services.createSavedSearch(
            name: "Starred", rules: SearchRules(favoritesOnly: true))

        let store = GridSelectionStore()
        let model = CollectionReadModel(feed: .savedSearch(services), selectionStore: store)
        let recorder = EventRecorder(model.events.stream())
        model.load(search.id)
        await recorder.wait(forAtLeast: 1, where: Self.isLoad(of: search.id))
        #expect(model.items.count == 2)

        // The user is mid-triage with BOTH hits selected and one of them the lead.
        let visible = model.items.map(\.item.id)
        store.replace(GridSelection(
            ids: Set(visible), anchor: visible.first, lead: visible.first))
        #expect(store.selection.ids.count == 2)

        // One of them stops matching — un-starred from anywhere, including this
        // very grid. The asset is untouched otherwise.
        _ = try await services.setFavorite(false, for: [assets[0].id])
        model.reload()
        await recorder.wait(forAtLeast: 2, where: Self.isLoad(of: search.id))

        // It is gone from the feed…
        #expect(model.items.count == 1)
        #expect(!model.items.contains { $0.asset.id == assets[0].id })
        #expect(model.items.first?.asset.id == assets[1].id)
        // …the selection is pruned to the survivor, and the lead — which pointed at
        // the row that left — falls away with it (009's stale-selection guard).
        #expect(store.selection.ids == Set(model.items.map(\.item.id)))
        #expect(store.selection.ids.count == 1)
        #expect(store.selection.lead == nil || model.items.contains {
            $0.item.id == store.selection.lead
        })
        // Nothing was deleted: the asset is still in its collection.
        let survivors = try await services.collectionItems(
            in: collection.id, sort: .newest, includeArchived: false)
        #expect(survivors.count == 3)
    }

    /// 057 gives a smart collection 007's grid modes minus `.manual`, and
    /// `evaluate(rules:)` passes no sort at all — so `.mostViewed` has to be
    /// applied over the fetched page, by the one function that reproduces core's
    /// `ORDER BY` byte for byte.
    @Test("the saved-search feed honours Most Viewed, and Newest is the service's order")
    func savedSearchFeedSorts() async throws {
        let dbPath = NSTemporaryDirectory() + "read-model-sort-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let collection = try await services.createCollection(name: "Refs")
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/vanish", capturedAt: Date())
        var assets: [Asset] = []
        for hex in ["#112233", "#445566", "#778899"] {
            let outcome = try await services.ingestContent(
                .color(hex: hex), from: source, into: collection.id)
            assets.append(outcome.asset)
        }
        let search = try await services.createSavedSearch(name: "All", rules: SearchRules())
        // The OLDEST asset is the most viewed, so the two orders cannot coincide.
        try await services.recordViews([assets[0].id])
        try await services.recordViews([assets[0].id])
        try await services.recordViews([assets[1].id])

        let newest = CollectionReadModel(
            feed: .savedSearch(services, sort: .newest), selectionStore: GridSelectionStore())
        let newestRecorder = EventRecorder(newest.events.stream())
        newest.load(search.id)
        await newestRecorder.wait(forAtLeast: 1, where: Self.isLoad(of: search.id))
        // `.newest` IS the service's own order, untouched — asserted against the
        // service rather than against a list retyped here, because three colours
        // ingested in one millisecond tie on `created_at` and fall through to
        // `id DESC`, which is not something a test should be predicting.
        let serviceOrder = try await services.evaluateSavedSearch(id: search.id, limit: 500)
        #expect(newest.items.map(\.asset.id) == serviceOrder.map(\.asset.id))

        let viewed = CollectionReadModel(
            feed: .savedSearch(services, sort: .mostViewed),
            selectionStore: GridSelectionStore())
        let viewedRecorder = EventRecorder(viewed.events.stream())
        viewed.load(search.id)
        await viewedRecorder.wait(forAtLeast: 1, where: Self.isLoad(of: search.id))
        #expect(viewed.items.map(\.asset.id) == [assets[0].id, assets[1].id, assets[2].id])
    }

    @Test("a saved-search feed refuses to reorder (057 — no manual order)")
    func savedSearchFeedRefusesReorder() async throws {
        let stub = StubFeed()
        let id = UUID()
        let rows = [item(0, in: id), item(1, in: id)]
        stub.pages[id] = CollectionFeed.Page(items: rows)

        let membershipLess = makeModel(stub, carriesMembership: false)
        let recorder = EventRecorder(membershipLess.events.stream())
        membershipLess.load(id)
        await recorder.wait { $0.contains(.loaded(collectionID: id, count: 2)) }

        let before = membershipLess.items.map(\.asset.id)
        #expect(membershipLess.applyReorder(
            movingAssetIDs: [rows[1].asset.id], insertAt: 0) == nil)
        #expect(membershipLess.items.map(\.asset.id) == before)

        // The identical drag through a MEMBERSHIP-carrying feed does reorder — so the
        // refusal above is the feed's rule and not a broken solve (14A, confirmed
        // through the read model).
        let stub2 = StubFeed()
        stub2.pages[id] = CollectionFeed.Page(items: rows)
        let collectionFeed = makeModel(stub2)
        let recorder2 = EventRecorder(collectionFeed.events.stream())
        collectionFeed.load(id)
        await recorder2.wait { $0.contains(.loaded(collectionID: id, count: 2)) }
        let reordered = collectionFeed.applyReorder(
            movingAssetIDs: [rows[1].asset.id], insertAt: 0)
        #expect(reordered == [rows[1].asset.id, rows[0].asset.id])
        #expect(collectionFeed.items.map(\.asset.id) == [rows[1].asset.id, rows[0].asset.id])
    }

    // MARK: - One feed, forwarded

    @Test("IngestionModel's feed IS the read model's — a forward, never a copy")
    func modelForwardsRatherThanCopies() async throws {
        let dbPath = NSTemporaryDirectory() + "read-model-forward-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        let collection = try await services.createCollection(name: "Refs")
        await model.refreshFolders()
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        for hex in ["#010203", "#040506", "#070809"] {
            _ = try await services.ingestContent(
                .color(hex: hex), from: source, into: collection.id)
        }

        let recorder = EventRecorder(model.contents.events.stream())
        model.loadContents(of: collection.id)
        await recorder.wait(forAtLeast: 1, where: Self.isLoad(of: collection.id))

        // This is the assertion the ~140 `model.items` reads across the other suites
        // rest on: the forwards on `IngestionModel` are computed properties over
        // `contents`, so those suites already assert the read model's state. If
        // anyone reintroduces storage here, these stop agreeing.
        #expect(model.items.map(\.item.id) == model.contents.items.map(\.item.id))
        #expect(model.loadedCollectionID == model.contents.loadedCollectionID)
        #expect(model.contentsVersion == model.contents.contentsVersion)
        #expect(model.displayItems.map(\.item.id) == model.contents.displayItems.map(\.item.id))
        #expect(model.detailRun.map(\.item.id) == model.contents.detailRun.map(\.item.id))
        #expect(model.itemsVersion == model.contents.itemsVersion)

        // An in-place edit made through the read model is visible through the model
        // with no second publish to keep in step.
        let order = model.items.map(\.asset.id)
        _ = model.contents.applyReorder(movingAssetIDs: [order[2]], insertAt: 0)
        #expect(model.items.map(\.asset.id) == [order[2], order[0], order[1]])
        #expect(model.contentsVersion == model.contents.contentsVersion)
    }

    // MARK: - 13A — the ingest throttle, end to end

    @Test("a burst of capture batches collapses to one reload plus one trailing")
    func ingestBurstCollapses() async throws {
        let dbPath = NSTemporaryDirectory() + "read-model-burst-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()

        let unsorted = model.unsortedFolderID
        let recorder = EventRecorder(model.contents.events.stream())
        model.loadContents(of: unsorted)
        await recorder.wait(forAtLeast: 1, where: Self.isLoad(of: unsorted))

        // Ten batches into the same collection, back to back — the shape a sweep or
        // an inbox drain produces. Before 13A this was ten full `collectionItems`
        // reads of the same folder.
        for _ in 0..<10 { model.refreshAfterIngest(touching: unsorted) }

        // The FIRST one still lands immediately: a capture the user just watched
        // arrive must not wait half a second.
        await recorder.wait(forAtLeast: 2, where: Self.isLoad(of: unsorted))
        #expect(recorder.count(where: Self.isLoad(of: unsorted)) == 2)

        // …and the nine behind it collapse into exactly ONE trailing reload at the
        // end of the window, so the last batch of a burst is never the one that
        // goes missing. Awaited through the load signal, not slept through.
        await recorder.wait(forAtLeast: 3, where: Self.isLoad(of: unsorted))
        #expect(recorder.count(where: Self.isLoad(of: unsorted)) == 3)
    }

    private static func isLoad(of id: UUID) -> @Sendable (CollectionReadModel.Event) -> Bool {
        { event in
            if case .loaded(let collectionID, _) = event { return collectionID == id }
            return false
        }
    }
}
