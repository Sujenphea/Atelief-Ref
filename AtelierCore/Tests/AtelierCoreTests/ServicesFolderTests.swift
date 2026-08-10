// AtelierCore — App Services folder-operation tests (chunk 2, decisions F3/F4/F6)
//
// Nested-folder services over the collection surface: create-with-parent,
// reparent with cycle prevention (F6), subtree delete via cascade (F4), the
// protected-Unsorted guards (F3), and direct-children listing (F5). House style
// mirrors `ServicesInvariantTests` — temp DB fixture, async `#expect(throws:)`.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: folder operations (F3/F4/F6)")
struct ServicesFolderTests {

    // MARK: Fixtures

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String = "abc123") -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    private func sourceDraft(url: String? = "https://example.com/a", platform: Platform = .web) -> SourceDraft {
        SourceDraft(platform: platform, originalURL: url, capturedAt: Date())
    }

    // MARK: create with parent

    @Test("createCollection(parent:) nests under the parent; no-parent is a root")
    func createWithParent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let root = try await services.createCollection(name: "Root")
        #expect(root.parentCollectionID == nil)
        let child = try await services.createCollection(name: "Child", parent: root.id)
        #expect(child.parentCollectionID == root.id)
    }

    @Test("createCollection under a missing parent throws notFound")
    func createUnderMissingParent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.createCollection(name: "Orphan", parent: ghost)
        }
    }

    // MARK: duplicate-name auto-disambiguation (043 · 2c)

    @Test("a duplicate sibling name is auto-suffixed on create")
    func createDisambiguatesSibling() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "Refs")
        let b = try await services.createCollection(name: "Refs")
        let c = try await services.createCollection(name: "refs")   // case-insensitive
        #expect(a.name == "Refs")
        #expect(b.name == "Refs 2")
        #expect(c.name == "refs 3")
    }

    @Test("the same name under DIFFERENT parents does not collide")
    func createNoCollisionAcrossParents() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p1 = try await services.createCollection(name: "P1")
        let p2 = try await services.createCollection(name: "P2")
        let a = try await services.createCollection(name: "Refs", parent: p1.id)
        let b = try await services.createCollection(name: "Refs", parent: p2.id)
        #expect(a.name == "Refs")
        #expect(b.name == "Refs")           // sibling scope is per-parent
    }

    @Test("rename onto a sibling name is auto-suffixed")
    func renameDisambiguatesSibling() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await services.createCollection(name: "Refs")
        let other = try await services.createCollection(name: "Notes")
        let renamed = try await services.renameCollection(id: other.id, to: "Refs")
        #expect(renamed.name == "Refs 2")
    }

    @Test("renaming a folder to its OWN current name is a no-op, not a drift to ` 2`")
    func renameToSelfDoesNotDrift() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let f = try await services.createCollection(name: "Refs")
        let renamed = try await services.renameCollection(id: f.id, to: "Refs")
        #expect(renamed.name == "Refs")     // excludes self → no self-collision
    }

    // MARK: protected Unsorted (F3)

    @Test("the protected Unsorted folder exists on a fresh store")
    func unsortedExists() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let unsorted = try await services.getCollection(id: services.unsortedFolderID)
        #expect(unsorted.id == Collection.unsortedID)
        #expect(unsorted.name == "Unsorted")
        #expect(unsorted.parentCollectionID == nil)
    }

    @Test("rename / delete / move on Unsorted throw protectedCollection")
    func protectedGuards() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let unsorted = Collection.unsortedID
        let other = try await services.createCollection(name: "Other")
        await #expect(throws: AtelierError.protectedCollection(id: unsorted)) {
            try await services.renameCollection(id: unsorted, to: "Renamed")
        }
        await #expect(throws: AtelierError.protectedCollection(id: unsorted)) {
            try await services.deleteCollection(id: unsorted)
        }
        await #expect(throws: AtelierError.protectedCollection(id: unsorted)) {
            try await services.moveCollection(id: unsorted, toParent: other.id)
        }
    }

    // MARK: move / reparent

    @Test("moveCollection reparents a folder; move to nil makes it a root")
    func moveReparents() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "A")
        let b = try await services.createCollection(name: "B")
        let child = try await services.createCollection(name: "Child", parent: a.id)

        try await services.moveCollection(id: child.id, toParent: b.id)
        #expect(try await services.getCollection(id: child.id).parentCollectionID == b.id)

        try await services.moveCollection(id: child.id, toParent: nil)
        #expect(try await services.getCollection(id: child.id).parentCollectionID == nil)
    }

    @Test("moveCollection under a missing parent throws notFound")
    func moveMissingParent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "A")
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.moveCollection(id: a.id, toParent: ghost)
        }
    }

    // MARK: cycle prevention (F6)

    @Test("cycle prevention: a folder cannot move under itself or a descendant")
    func cyclePrevention() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        // P → C → G
        let p = try await services.createCollection(name: "P")
        let c = try await services.createCollection(name: "C", parent: p.id)
        let g = try await services.createCollection(name: "G", parent: c.id)

        await #expect(throws: AtelierError.folderCycle) {
            try await services.moveCollection(id: p.id, toParent: c.id)   // direct child
        }
        await #expect(throws: AtelierError.folderCycle) {
            try await services.moveCollection(id: p.id, toParent: g.id)   // grandchild
        }
        await #expect(throws: AtelierError.folderCycle) {
            try await services.moveCollection(id: p.id, toParent: p.id)   // self
        }

        // A legal move: C under a sibling of P succeeds.
        let sibling = try await services.createCollection(name: "Sibling")
        try await services.moveCollection(id: c.id, toParent: sibling.id)
        #expect(try await services.getCollection(id: c.id).parentCollectionID == sibling.id)
    }

    // MARK: subtree delete (F4)

    @Test("deleteCollection removes the whole subtree; filed asset survives")
    func subtreeDelete() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let c = try await services.createCollection(name: "C", parent: p.id)
        let ingest = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)

        try await services.deleteCollection(id: p.id)

        // P and C are both gone (parent FK cascade recurses).
        await #expect(throws: AtelierError.notFound(entity: "collection", id: p.id)) {
            try await services.getCollection(id: p.id)
        }
        await #expect(throws: AtelierError.notFound(entity: "collection", id: c.id)) {
            try await services.getCollection(id: c.id)
        }
        // The asset survives as a library row.
        let asset = try await services.getAsset(id: ingest.asset.id)
        #expect(asset.asset.id == ingest.asset.id)
    }

    // MARK: childCollections (F5)

    @Test("childCollections: nil returns roots (incl. Unsorted); a parent returns only direct children")
    func childListing() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let p = try await services.createCollection(name: "P")
        let c1 = try await services.createCollection(name: "C1", parent: p.id)
        let c2 = try await services.createCollection(name: "C2", parent: p.id)
        _ = try await services.createCollection(name: "G", parent: c1.id) // grandchild

        let roots = try await services.childCollections(of: nil)
        let rootIDs = Set(roots.map(\.id))
        #expect(rootIDs.contains(Collection.unsortedID)) // the seeded root
        #expect(rootIDs.contains(p.id))
        #expect(!rootIDs.contains(c1.id))                // not a root

        let children = try await services.childCollections(of: p.id)
        #expect(children.map(\.id) == [c1.id, c2.id])    // direct only, name-ordered
    }

    // MARK: ingest into a created folder

    @Test("ingest lands the asset in the chosen created folder")
    func ingestIntoCreatedFolder() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let folder = try await services.createCollection(name: "Refs")
        let result = try await services.ingest(assetDraft(), from: sourceDraft(), into: folder.id)
        let items = try await services.collectionItems(in: folder.id, includeArchived: false)
        #expect(items.map(\.asset.id) == [result.asset.id])
    }
}
