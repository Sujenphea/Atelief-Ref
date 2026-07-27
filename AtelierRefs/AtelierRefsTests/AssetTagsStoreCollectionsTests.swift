//
//  AssetTagsStoreCollectionsTests.swift
//  AtelierRefsTests
//
//  041 — the Item Detail "Collections" surface on the shared per-asset store.
//  Guards the behavior that has no coverage elsewhere: bind loads memberships +
//  the full library list, add/remove reflect, the membership-change callback
//  fires, and — the subtle one — removing an asset's LAST membership RE-HOMES it
//  to Unsorted instead of orphaning it.
//
//  The store's mutators are fire-and-forget (`Task {}`), so assertions poll the
//  `@Published` state through `waitUntil` rather than racing the write.
//

import AtelierCore
import Combine
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("AssetTagsStore: collections (041)")
struct AssetTagsStoreCollectionsTests {

    private func makeServices() throws -> AppServices {
        let dbPath = NSTemporaryDirectory() + "tagstore-collections-\(UUID().uuidString).sqlite"
        return try AppServices(databasePath: dbPath)
    }

    /// Ingest one media-less color into `collectionID` (its only membership) and
    /// return its id.
    private func seedColor(into collectionID: UUID, _ services: AppServices) async throws -> UUID {
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        let hex = "#\(String(UUID().uuidString.prefix(6)))"
        return try await services.ingestContent(.color(hex: hex), from: source, into: collectionID).asset.id
    }

    /// Poll a main-actor condition until true (or ~2s elapse → recorded failure),
    /// yielding so the store's internal `Task` can run between checks.
    private func waitUntil(
        _ label: String, _ cond: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if cond() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitUntil timed out: \(label)")
    }

    // MARK: bind

    @Test("bind loads the asset's memberships + the full library list")
    func bindLoadsCollections() async throws {
        let services = try makeServices()
        let temp1 = try await services.createCollection(name: "Temp1")
        _ = try await services.createCollection(name: "Temp2")
        let assetID = try await seedColor(into: temp1.id, services)

        let store = AssetTagsStore(services: services)
        store.bind(to: assetID)

        try await waitUntil("memberships load") { store.collections.map(\.name) == ["Temp1"] }
        // allCollections is the whole library (name-ordered), incl. Unsorted.
        #expect(store.allCollections.map(\.name).contains("Temp2"))
        #expect(store.allCollections.contains { $0.id == Collection.unsortedID })
    }

    // MARK: add / remove

    @Test("addToCollection adds a membership; removeFromCollection (not last) drops only it")
    func addAndRemoveNonLast() async throws {
        let services = try makeServices()
        let temp1 = try await services.createCollection(name: "Temp1")
        let temp2 = try await services.createCollection(name: "Temp2")
        let assetID = try await seedColor(into: temp1.id, services)

        let store = AssetTagsStore(services: services)
        store.bind(to: assetID)
        try await waitUntil("initial load") { store.collections.map(\.name) == ["Temp1"] }

        store.addToCollection(temp2)
        try await waitUntil("added Temp2") { store.collections.map(\.name) == ["Temp1", "Temp2"] }

        // Removing Temp2 is NOT the last membership → Temp1 remains, no re-home.
        store.removeFromCollection(temp2)
        try await waitUntil("removed Temp2") { store.collections.map(\.name) == ["Temp1"] }
    }

    // MARK: re-home (the subtle invariant)

    @Test("removing the LAST membership re-homes the asset to Unsorted (never orphans)")
    func removeLastReHomesToUnsorted() async throws {
        let services = try makeServices()
        let temp1 = try await services.createCollection(name: "Temp1")
        let assetID = try await seedColor(into: temp1.id, services)

        let store = AssetTagsStore(services: services)
        store.bind(to: assetID)
        try await waitUntil("initial load") { store.collections.map(\.id) == [temp1.id] }

        // Temp1 is the asset's ONLY membership. Removing it must NOT orphan the
        // asset — it falls back to the Unsorted home.
        store.removeFromCollection(temp1)
        try await waitUntil("re-homed to Unsorted") {
            store.collections.map(\.id) == [Collection.unsortedID]
        }
        // Confirm at the DB, not just the chip list.
        let onDisk = try await services.collections(for: assetID).map(\.id)
        #expect(onDisk == [Collection.unsortedID])
    }

    // MARK: callback

    @Test("onMembershipChanged fires after add and remove")
    func membershipCallbackFires() async throws {
        let services = try makeServices()
        let temp1 = try await services.createCollection(name: "Temp1")
        let temp2 = try await services.createCollection(name: "Temp2")
        let assetID = try await seedColor(into: temp1.id, services)

        let store = AssetTagsStore(services: services)
        store.bind(to: assetID)
        try await waitUntil("initial load") { store.collections.map(\.name) == ["Temp1"] }

        let counter = Counter()
        store.onMembershipChanged = { counter.n += 1 }

        store.addToCollection(temp2)
        try await waitUntil("callback after add") { counter.n >= 1 }

        store.removeFromCollection(temp2)
        try await waitUntil("callback after remove") { counter.n >= 2 }
    }

    /// A tiny main-actor box so the callback can bump a value the test observes
    /// (avoids capturing a `var` across the escaping closure boundary).
    @MainActor private final class Counter { var n = 0 }
}
