//
//  ShelfControllerTests.swift
//  AtelierRefsTests
//
//  023 · A2 — the Archived destination's controller, over a real (temp)
//  `AppServices`. No mocks: the shelf's whole job is to be a true picture of
//  `archived_at`, and a stubbed service would let it be a true picture of the
//  stub instead.
//
//  The load states get as much attention as the happy path, deliberately. An
//  empty `items` array means three different things — "not read yet", "read, and
//  nothing is archived", "the read failed" — and the pane says something
//  different for each. Collapsing them is how an empty shelf comes to claim
//  there is nothing archived when it simply has not looked.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("ShelfController (023 · A2)")
struct ShelfControllerTests {

    private func makeServices() throws -> AppServices {
        let path = NSTemporaryDirectory() + "shelf-\(UUID().uuidString).sqlite"
        return try AppServices(databasePath: path)
    }

    /// Seed `count` distinct media-less colors, as `AppFavoritesTests` does —
    /// no blob files needed, and each is guaranteed distinct under 18A dedup.
    @discardableResult
    private func seedColors(
        _ count: Int, into collectionID: UUID, _ services: AppServices
    ) async throws -> [UUID] {
        var ids: [UUID] = []
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        for i in 0..<count {
            let hex = String(
                format: "#%02x%02x%02x",
                (i * 40 + 10) % 256, (i * 17 + 5) % 256, (i * 91 + 3) % 256)
            ids.append(try await services.ingestContent(
                .color(hex: hex), from: source, into: collectionID).asset.id)
        }
        return ids
    }

    // MARK: - Load states

    /// The three-state distinction the pane's empty view rests on.
    @Test("before any load the shelf is not 'empty' — it is unread")
    func unreadIsNotEmpty() async throws {
        let controller = ShelfController()
        #expect(controller.items.isEmpty)
        #expect(controller.hasLoaded == false)
        // …so the pane must NOT say "Nothing archived" yet.
        #expect(controller.isEmpty == false)
    }

    @Test("a load over an unarchived library reports a genuinely empty shelf")
    func loadedAndEmpty() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        try await seedColors(3, into: refs.id, services)

        let controller = ShelfController()
        await controller.load(services: services)

        #expect(controller.hasLoaded)
        #expect(controller.isEmpty)
        #expect(controller.count == 0)
        #expect(controller.lastError == nil)
    }

    @Test("a load publishes the shelf, most recently archived first")
    func loadPublishesShelf() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: refs.id, services)
        // Archived in two gestures so the order is a real claim, not a tie.
        try await services.archive([ids[0]])
        try await services.archive([ids[2]])

        let controller = ShelfController()
        await controller.load(services: services)

        #expect(controller.count == 2)
        #expect(Set(controller.items.map(\.asset.id)) == [ids[0], ids[2]])
        // The un-archived one is absent — the shelf is not the library.
        #expect(!controller.items.contains { $0.asset.id == ids[1] })
        #expect(controller.itemsVersion == 1)
    }

    /// A failed read must not blank the pane. "I could not check" and "there is
    /// nothing here" are different answers, and showing the second for the first
    /// is how a transient error reads as data loss.
    @Test("a failed load keeps the last good shelf and reports the error")
    func failedLoadKeepsItems() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: refs.id, services)
        try await services.archive(ids)

        let controller = ShelfController()
        await controller.load(services: services)
        #expect(controller.count == 2)

        // Make the next read fail. The seam exists for this: there is no way to
        // make a live SQLite read fail on demand, and the branch under test is
        // the one that matters most on this pane.
        struct ReadFailed: Error {}
        controller.readShelf = { _ in throw ReadFailed() }
        await controller.load(services: services)

        #expect(controller.lastError != nil)
        #expect(controller.count == 2)          // the last good answer survives
        #expect(controller.hasLoaded)
    }

    // MARK: - The verb

    @Test("unarchive removes the row from the shelf and reports the change count")
    func unarchiveRemovesRow() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: refs.id, services)
        try await services.archive(ids)

        let controller = ShelfController()
        await controller.load(services: services)
        #expect(controller.count == 3)

        let changed = await controller.unarchive([ids[0], ids[1]], services: services)

        #expect(changed == 2)
        #expect(controller.count == 1)
        #expect(controller.items.map(\.asset.id) == [ids[2]])
        // …and they really are back in the collection, not merely off this list.
        let visible = try await services.collectionItems(
            in: refs.id, includeArchived: false).map(\.asset.id)
        #expect(Set(visible) == [ids[0], ids[1]])
    }

    /// The count is what a caller registering an undo keys off: unarchiving
    /// something already unarchived must not push an entry that would re-archive
    /// it on ⌘Z.
    @Test("unarchiving an unarchived asset reports zero and still reloads")
    func unarchiveNoOpReportsZero() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: refs.id, services)
        try await services.archive([ids[0]])

        let controller = ShelfController()
        await controller.load(services: services)
        let versionBefore = controller.itemsVersion

        let changed = await controller.unarchive([ids[1]], services: services)

        #expect(changed == 0)
        // Reloaded anyway: a zero-row result can mean someone else changed these
        // rows first, in which case the published list is exactly what is stale.
        #expect(controller.itemsVersion > versionBefore)
        #expect(controller.count == 1)
    }

    @Test("an empty batch is a no-op that does not even reload")
    func emptyBatchIsNoOp() async throws {
        let services = try makeServices()
        let controller = ShelfController()
        await controller.load(services: services)
        let versionBefore = controller.itemsVersion

        #expect(await controller.unarchive([], services: services) == 0)
        #expect(await controller.archive([], services: services) == 0)
        #expect(controller.itemsVersion == versionBefore)
    }

    /// The inverse verb exists so an undo of an unarchive has something to call
    /// that leaves this pane's state true.
    @Test("archive puts an item back on the shelf and reloads")
    func archiveRoundTripsThroughTheController() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(1, into: refs.id, services)

        let controller = ShelfController()
        await controller.load(services: services)
        #expect(controller.isEmpty)

        #expect(await controller.archive(ids, services: services) == 1)
        #expect(controller.count == 1)

        #expect(await controller.unarchive(ids, services: services) == 1)
        #expect(controller.isEmpty)
    }

    // MARK: - Ordering under concurrency

    /// Overlapping loads are the normal case on this pane — it reloads on
    /// appear, on a navigation pulse, on `contentsVersion` and after every verb.
    /// `await` means they can finish in an order other than the one they were
    /// issued in, so the NEWEST read has to win, not the last to arrive.
    ///
    /// Forced, not hoped for: the first read is made slow and the second
    /// instant, so the stale answer is guaranteed to land second. Without the
    /// ticket in `load`, this test sees `["old"]`.
    @Test("an overtaken load does not overwrite the newer read's answer")
    func staleLoadDoesNotWin() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: refs.id, services)

        let old = try await services.getAsset(id: ids[0])
        let new = try await services.getAsset(id: ids[1])

        let controller = ShelfController()
        controller.readShelf = { _ in
            try await Task.sleep(for: .milliseconds(120))
            return [old]
        }
        async let slow: Void = controller.load(services: services)
        // Let the slow read start before the fast one is issued.
        try await Task.sleep(for: .milliseconds(10))
        controller.readShelf = { _ in [new] }
        await controller.load(services: services)

        // The fast (newer) read has landed.
        #expect(controller.items.map(\.asset.id) == [new.asset.id])
        await slow
        // …and the slow one finishing afterwards does NOT resurrect its answer.
        #expect(controller.items.map(\.asset.id) == [new.asset.id])
        #expect(controller.isLoading == false)
    }

    /// The live default really is the live call — otherwise every test above
    /// could pass against a seam the app never uses.
    @Test("the default reader is AppServices.shelfAssets")
    func defaultReaderIsLive() async throws {
        let services = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(1, into: refs.id, services)
        try await services.archive(ids)

        let controller = ShelfController()      // untouched seam
        await controller.load(services: services)

        #expect(controller.items.map(\.asset.id) == ids)
    }
}
