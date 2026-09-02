// AtelierCore — the one-row half of the P14 collection read (098 · finding 13).
//
// `collectionItems(in:sort:includeArchived:)` is the grid's read and returns the whole
// collection. `collectionItem(in:id:includeArchived:)` is the SAME join asked for one
// membership, and the reason it exists is a measurement rather than a preference: the
// phone's item screen resolved a tapped tile by reading the collection and keeping one
// row, which `.change-log/450` timed at 0.293 s for 5,000 items — per tap.
//
// So what these tests pin is not the speed (that is `BrowseScaleTests`' job, where a
// library big enough to show it can be seeded) but that the one-row read answers
// EXACTLY what the whole-collection read would have answered for that row, in every
// case where the two could disagree: an archived asset, an id that belongs to another
// collection, an id that belongs to nothing, and a collection that is not there at all.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Services: one collection item (098 · 13)")
struct ServicesCollectionItemTests {

    // MARK: - Present

    @Test("the row comes back with the same asset and source the collection read gives")
    func present() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        let item = try await rig.add(hash: 1, title: "Concrete")
        let one = try await rig.services.collectionItem(
            in: rig.collection, id: item.item.id, includeArchived: false)

        #expect(one?.item == item.item)
        #expect(one?.asset.id == item.asset.id)
        #expect(one?.source.id == item.source.id)
        // The whole point: byte for byte what the grid's own read produced for that row,
        // so a screen opened from a tile shows what the tile showed.
        let fromCollection = try await rig.services.collectionItems(
            in: rig.collection, includeArchived: false)
            .first { $0.item.id == item.item.id }
        #expect(one == fromCollection)
    }

    @Test("the source is joined, not left for a second query")
    func sourceIsJoined() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        let item = try await rig.add(hash: 2, title: "Fabric")
        let one = try await rig.services.collectionItem(
            in: rig.collection, id: item.item.id, includeArchived: false)
        #expect(one?.source.title == "Fabric")
        #expect(one?.source.platform == .web)
    }

    // MARK: - Absent

    @Test("an id nothing owns is nil, not a throw")
    func absent() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try await rig.add(hash: 3, title: "One")

        let one = try await rig.services.collectionItem(
            in: rig.collection, id: UUID(), includeArchived: false)
        #expect(one == nil)
    }

    @Test("an empty collection answers nil for any id")
    func emptyCollection() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let empty = try await rig.services.createCollection(name: "Empty")

        let one = try await rig.services.collectionItem(
            in: empty.id, id: UUID(), includeArchived: false)
        #expect(one == nil)
    }

    // MARK: - Archived

    @Test("an archived item is hidden from browse and visible to a backup")
    func archivedHidden() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        let item = try await rig.add(hash: 4, title: "Shelved")
        _ = try await rig.services.archive([item.asset.id])

        // 023 · A: the membership row stays, and the READ is what hides it — which is
        // what lets unarchiving put the item back exactly where it was.
        let browsing = try await rig.services.collectionItem(
            in: rig.collection, id: item.item.id, includeArchived: false)
        #expect(browsing == nil)

        let backingUp = try await rig.services.collectionItem(
            in: rig.collection, id: item.item.id, includeArchived: true)
        #expect(backingUp?.item.id == item.item.id)
        #expect(backingUp?.asset.archivedAt != nil)
    }

    @Test("unarchiving makes the same id resolve again, unmoved")
    func unarchiveRestores() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        let item = try await rig.add(hash: 5, title: "Back")
        _ = try await rig.services.archive([item.asset.id])
        _ = try await rig.services.unarchive([item.asset.id])

        let one = try await rig.services.collectionItem(
            in: rig.collection, id: item.item.id, includeArchived: false)
        #expect(one?.item == item.item)
    }

    // MARK: - The pair is the key

    @Test("an id belonging to a different collection is nil in this one")
    func wrongCollection() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        let other = try await rig.services.createCollection(name: "Other")
        let mine = try await rig.add(hash: 6, title: "Mine")
        let theirs = try await rig.add(hash: 7, title: "Theirs", into: other.id)

        #expect(try await rig.services.collectionItem(
            in: rig.collection, id: theirs.item.id, includeArchived: false) == nil)
        #expect(try await rig.services.collectionItem(
            in: other.id, id: mine.item.id, includeArchived: false) == nil)
        // …and each resolves in its own.
        #expect(try await rig.services.collectionItem(
            in: other.id, id: theirs.item.id, includeArchived: false)?.item.id
            == theirs.item.id)
    }

    @Test("one asset in two collections is two memberships, each found by its own pair")
    func sameAssetTwoMemberships() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        let other = try await rig.services.createCollection(name: "Other")
        let first = try await rig.add(hash: 8, title: "Shared")
        _ = try await rig.services.addAssets([first.asset.id], to: other.id)

        let inOther = try await rig.services.collectionItems(
            in: other.id, includeArchived: false)
        let secondMembership = try #require(inOther.first)
        #expect(secondMembership.item.id != first.item.id)
        #expect(secondMembership.asset.id == first.asset.id)

        let one = try await rig.services.collectionItem(
            in: other.id, id: secondMembership.item.id, includeArchived: false)
        #expect(one?.item.id == secondMembership.item.id)
        #expect(one?.asset.id == first.asset.id)
    }

    // MARK: - No such collection

    @Test("a collection that is gone is .notFound, not an item that is gone")
    func unknownCollection() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let item = try await rig.add(hash: 9, title: "Orphan")

        // The distinction the caller renders as two different sentences: "that item is
        // no longer in the library" against "that collection is no longer in the
        // library". A `nil` for both would collapse them.
        await #expect(throws: AtelierError.self) {
            _ = try await rig.services.collectionItem(
                in: UUID(), id: item.item.id, includeArchived: false)
        }
    }

    @Test("a deleted collection stops resolving its items")
    func deletedCollection() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }

        let doomed = try await rig.services.createCollection(name: "Doomed")
        let item = try await rig.add(hash: 10, title: "Inside", into: doomed.id)
        _ = try await rig.services.deleteCollection(id: doomed.id)

        await #expect(throws: AtelierError.self) {
            _ = try await rig.services.collectionItem(
                in: doomed.id, id: item.item.id, includeArchived: false)
        }
    }

    // MARK: - Rig

    private struct Rig {
        let services: AppServices
        let temp: TempDatabase
        let collection = Collection.unsortedID

        init() throws {
            temp = try makeTempDatabase()
            services = AppServices(database: temp.database)
        }

        func cleanup() { temp.cleanup() }

        /// One byte-backed capture. Every `hash` yields a distinct blob so 18A dedup
        /// never collapses two of them into one asset.
        func add(
            hash: Int, title: String, into collectionID: UUID? = nil
        ) async throws -> CollectionItemDetail {
            let target = collectionID ?? collection
            let result = try await services.ingest(
                AssetDraft(
                    kind: .image, blobHash: String(format: "%064x", hash),
                    mimeType: "image/jpeg", width: 800, height: 600, fileSize: 1234,
                    downloadState: .downloaded),
                from: SourceDraft(
                    platform: .web, originalURL: "https://example.com/\(hash)",
                    title: title, capturedAt: Date()),
                into: target)
            let items = try await services.collectionItems(
                in: target, includeArchived: true)
            return try #require(items.first { $0.asset.id == result.asset.id })
        }
    }
}
