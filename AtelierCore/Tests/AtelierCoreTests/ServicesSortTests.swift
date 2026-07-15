// AtelierCore — App Services sort tests (007 G3 · view tracking + sort mode)
//
// Per-mode ordering (incl. tie-breaks), `recordViews` batch increments +
// last_viewed_at, sort_mode round-trip, and the non-destructive invariant:
// view bumps and mode switches never rewrite manual_order.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: sort + view tracking (007 G3)")
struct ServicesSortTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest a distinct asset into `c` and return its id.
    @discardableResult
    private func seed(_ services: AppServices, into c: UUID) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 10, downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c).asset.id
    }

    // MARK: sort_mode persistence

    @Test("sort_mode defaults to .manual and round-trips")
    func sortModeRoundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        #expect(try await services.getCollection(id: c.id).sortMode == .manual)

        try await services.setCollectionSortMode(.mostViewed, for: c.id)
        #expect(try await services.getCollection(id: c.id).sortMode == .mostViewed)

        try await services.setCollectionSortMode(.newest, for: c.id)
        #expect(try await services.getCollection(id: c.id).sortMode == .newest)
    }

    @Test("setCollectionSortMode on an unknown collection is .notFound")
    func sortModeNotFound() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.self) {
            try await services.setCollectionSortMode(.newest, for: UUID())
        }
    }

    // MARK: recordViews

    @Test("recordViews increments view_count once per distinct id and stamps last_viewed_at")
    func recordViewsIncrements() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        let b = try await seed(services, into: c.id)

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await services.recordViews([a, a, b], at: t)  // a twice in one batch → +1

        let assetA = try await services.getAsset(id: a).asset
        let assetB = try await services.getAsset(id: b).asset
        #expect(assetA.viewCount == 1)
        #expect(assetB.viewCount == 1)
        #expect(assetA.lastViewedAt == t)

        // A second call accumulates.
        try await services.recordViews([a])
        #expect(try await services.getAsset(id: a).asset.viewCount == 2)
    }

    @Test("recordViews skips unknown ids and no-ops on empty")
    func recordViewsSkipsUnknown() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        try await services.recordViews([])            // no-op
        try await services.recordViews([UUID(), a])   // unknown skipped, a bumped
        #expect(try await services.getAsset(id: a).asset.viewCount == 1)
    }

    // MARK: ordering

    @Test(".newest orders by created_at DESC; .mostViewed by view_count DESC")
    func orderingModes() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Ingest in a known order → created_at increases a→b→c.
        let a = try await seed(services, into: c.id)
        let b = try await seed(services, into: c.id)
        let d = try await seed(services, into: c.id)

        // Give `a` the most views, `b` one, `d` none.
        try await services.recordViews([a]); try await services.recordViews([a])
        try await services.recordViews([b])

        let newest = try await services.collectionItems(in: c.id, sort: .newest).map(\.asset.id)
        #expect(newest == [d, b, a])   // reverse ingest order

        let mostViewed = try await services.collectionItems(in: c.id, sort: .mostViewed).map(\.asset.id)
        #expect(mostViewed == [a, b, d])  // 2, 1, 0 views
    }

    @Test(".mostViewed breaks view_count ties by created_at DESC, then id DESC")
    func mostViewedTieBreak() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        let b = try await seed(services, into: c.id)
        let d = try await seed(services, into: c.id)
        // All zero views → the tie-break IS the whole order: created_at DESC.
        let order = try await services.collectionItems(in: c.id, sort: .mostViewed).map(\.asset.id)
        #expect(order == [d, b, a])
    }

    // MARK: append-on-insert (manual order)

    @Test("ingest appends to the END of the manual grid, in insertion order")
    func ingestAppendsInOrder() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Three ingests in a known order — no drag reorder at all.
        let a = try await seed(services, into: c.id)
        let b = try await seed(services, into: c.id)
        let d = try await seed(services, into: c.id)

        // Manual order is the insertion order (0,1,2), NOT a random NULL/id order.
        let order = try await services.collectionItems(in: c.id, sort: .manual).map(\.asset.id)
        #expect(order == [a, b, d])
    }

    @Test("a fresh ingest lands after an existing arrangement, not in front of it")
    func ingestAppendsAfterArranged() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        let b = try await seed(services, into: c.id)
        // Impose an explicit order, then ingest a new item.
        try await services.setGridOrder(collectionID: c.id, orderedAssetIDs: [b, a])
        let d = try await seed(services, into: c.id)

        // The new item is appended to the end — the arrangement is preserved.
        let order = try await services.collectionItems(in: c.id, sort: .manual).map(\.asset.id)
        #expect(order == [b, a, d])
    }

    @Test("addAssets appends the batch to the end, in order, only for new members")
    func addAssetsAppendsBatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let source = try await services.createCollection(name: "Source")
        let target = try await services.createCollection(name: "Target")
        let a = try await seed(services, into: target.id)   // target already holds `a`
        let b = try await seed(services, into: source.id)
        let d = try await seed(services, into: source.id)

        // Add b, d to target (a is already a member and must not move / re-slot).
        try await services.addAssets([b, a, d], to: target.id)

        let order = try await services.collectionItems(in: target.id, sort: .manual).map(\.asset.id)
        #expect(order == [a, b, d])
    }

    // MARK: non-destructive switching

    @Test("manual order survives view bumps and mode switches")
    func manualOrderNonDestructive() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        let b = try await seed(services, into: c.id)
        let d = try await seed(services, into: c.id)

        // Impose an explicit drag order d, a, b.
        try await services.setGridOrder(collectionID: c.id, orderedAssetIDs: [d, a, b])
        let manual0 = try await services.collectionItems(in: c.id, sort: .manual).map(\.asset.id)
        #expect(manual0 == [d, a, b])

        // Bump views and flip modes around.
        try await services.recordViews([b]); try await services.recordViews([b])
        _ = try await services.collectionItems(in: c.id, sort: .mostViewed)
        _ = try await services.collectionItems(in: c.id, sort: .newest)
        try await services.setCollectionSortMode(.mostViewed, for: c.id)

        // Manual order is byte-for-byte the same as before.
        let manual1 = try await services.collectionItems(in: c.id, sort: .manual).map(\.asset.id)
        #expect(manual1 == [d, a, b])
    }
}
