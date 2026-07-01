// AtelierCore — App Services read tests (chunk 6, P14/P16/A2)
//
// The bounded read surface: list/get collections, the P14 joined collection
// read mapped to the public GRDB-free `CollectionItemDetail`, and `getAsset`.
// Asserts ordering, nested asset+source correctness, and `.notFound` triggers.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: reads (P14/P16)")
struct ServicesReadTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    private func sourceDraft(
        url: String, title: String? = nil, handle: String? = nil
    ) -> SourceDraft {
        SourceDraft(
            platform: .web, originalURL: url, authorHandle: handle,
            authorName: nil, title: title, capturedAt: Date())
    }

    // MARK: listCollections

    @Test("listCollections holds only the seeded Unsorted folder on a fresh store")
    func listEmpty() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        // The v2 migration seeds the protected Unsorted folder; a fresh store
        // therefore starts with exactly that one collection.
        let ids = try await services.listCollections().map(\.id)
        #expect(ids == [Collection.unsortedID])
    }

    @Test("listCollections is ordered by name then id")
    func listOrdered() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await services.createCollection(name: "Zephyr")
        _ = try await services.createCollection(name: "Alpha")
        _ = try await services.createCollection(name: "Mango")
        // Exclude the seeded Unsorted folder — its ordering is exercised elsewhere.
        let names = try await services.listCollections()
            .filter { $0.id != Collection.unsortedID }
            .map(\.name)
        #expect(names == ["Alpha", "Mango", "Zephyr"])
    }

    @Test("listCollections breaks name ties by id (stable)")
    func listTieByID() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        // Two collections with the same name → tie broken by id, stably.
        let a = try await services.createCollection(name: "Dup")
        let b = try await services.createCollection(name: "Dup")
        // Exclude the seeded Unsorted folder; assert the two "Dup" rows order by id.
        let ids = try await services.listCollections()
            .filter { $0.id != Collection.unsortedID }
            .map(\.id)
        let expected = [a.id, b.id].sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        #expect(ids == expected)
    }

    // MARK: getCollection

    @Test("getCollection returns the collection when present")
    func getFound() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let created = try await services.createCollection(name: "Refs")
        let fetched = try await services.getCollection(id: created.id)
        // Compare by identity + fields (the read-back date is millisecond-
        // truncated text, so a full `==` against the in-memory value would
        // spuriously differ on sub-millisecond precision).
        #expect(fetched.id == created.id)
        #expect(fetched.name == created.name)
    }

    @Test("getCollection throws notFound when absent")
    func getNotFound() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.getCollection(id: ghost)
        }
    }

    // MARK: collectionItems (P14 joined read → public detail)

    @Test("collectionItems returns the joined details, ordered, with nested asset+source")
    func collectionItemsJoined() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Three distinct assets (distinct hashes + urls), then a manual order.
        let r1 = try await services.ingest(
            assetDraft(hash: "a1"), from: sourceDraft(url: "https://e/1", title: "One"), into: c.id)
        let r2 = try await services.ingest(
            assetDraft(hash: "b2"), from: sourceDraft(url: "https://e/2", title: "Two"), into: c.id)
        let r3 = try await services.ingest(
            assetDraft(hash: "c3"), from: sourceDraft(url: "https://e/3", title: "Three"), into: c.id)
        // Order them explicitly 0,1,2 = r3, r1, r2.
        try await services.setGridOrder(
            collectionID: c.id, orderedAssetIDs: [r3.asset.id, r1.asset.id, r2.asset.id])

        let details = try await services.collectionItems(in: c.id)
        try #require(details.count == 3)
        // manual_order ascending → r3, r1, r2.
        #expect(details.map(\.asset.id) == [r3.asset.id, r1.asset.id, r2.asset.id])
        #expect(details.map(\.item.manualOrder) == [0, 1, 2])
        // Each row's nested asset + source are the right ones.
        for detail in details {
            #expect(detail.asset.id == detail.item.assetID)
            #expect(detail.source.id == detail.asset.sourceId)
        }
        // Spot-check a source title round-trips through the public type.
        let titles = Set(details.map(\.source.title))
        #expect(titles == ["One", "Two", "Three"])
    }

    @Test("collectionItems is empty for a collection with no items")
    func collectionItemsEmpty() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Empty")
        #expect(try await services.collectionItems(in: c.id).isEmpty)
    }

    @Test("collectionItems throws notFound for a missing collection")
    func collectionItemsNotFound() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.collectionItems(in: ghost)
        }
    }

    // MARK: getAsset

    @Test("getAsset returns the asset with its source provenance")
    func getAssetFound() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let r = try await services.ingest(
            assetDraft(hash: "abcd"),
            from: sourceDraft(url: "https://e/x", title: "Hello", handle: "@me"), into: c.id)
        let detail = try await services.getAsset(id: r.asset.id)
        // Identity + fields (read-back dates are millisecond-truncated text).
        #expect(detail.asset.id == r.asset.id)
        #expect(detail.asset.blobHash == r.asset.blobHash)
        #expect(detail.asset.width == r.asset.width)
        #expect(detail.source.id == r.asset.sourceId)
        #expect(detail.source.title == "Hello")
        #expect(detail.source.authorHandle == "@me")
    }

    @Test("getAsset throws notFound when absent")
    func getAssetNotFound() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "asset", id: ghost)) {
            try await services.getAsset(id: ghost)
        }
    }
}
