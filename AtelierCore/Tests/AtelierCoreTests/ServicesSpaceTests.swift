// AtelierCore — App Services space-operation tests (005 · decision O1)
//
// The first-class Space surface over the discriminated `space` / `space_item`
// tables: create / rename / delete / list / get, asset placement + element
// insert with discriminator + placement validation, move / restyle / remove,
// the LEFT-joined board read (asset rows carry media, element rows don't), and
// the ElementStyle JSON round-trip. House style mirrors `ServicesFolderTests` —
// temp DB fixture, async `#expect(throws:)`.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: space operations (005 · O1)")
struct ServicesSpaceTests {

    // MARK: Fixtures

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one asset into the Unsorted folder and return its id (spaces mix
    /// assets from any collection; ingest is the only way to mint a real asset).
    private func makeAsset(_ services: AppServices, hash: String = "abc123", url: String = "https://example.com/a") async throws -> UUID {
        let asset = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096, downloadState: .downloaded)
        let source = SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
        let result = try await services.ingest(asset, from: source, into: services.unsortedFolderID)
        return result.asset.id
    }

    // MARK: create / rename / delete / list / get

    @Test("createSpace trims the name and generates identity + timestamps")
    func createTrims() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "  Moodboard  ")
        #expect(space.name == "Moodboard")
        // Round-trip identity + name (not full `==`: GRDB truncates the stored
        // `Date()` to millisecond precision, so a re-fetched row's timestamps
        // won't equal the in-memory sub-ms value bit-for-bit).
        let fetched = try await services.getSpace(id: space.id)
        #expect(fetched.id == space.id)
        #expect(fetched.name == "Moodboard")
    }

    @Test("createSpace rejects an empty / whitespace name")
    func createRejectsEmpty() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.invalidName) {
            try await services.createSpace(name: "   ")
        }
    }

    @Test("renameSpace updates the name; missing space throws notFound")
    func rename() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "A")
        let renamed = try await services.renameSpace(id: space.id, to: "B")
        #expect(renamed.name == "B")
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "space", id: ghost)) {
            try await services.renameSpace(id: ghost, to: "X")
        }
    }

    @Test("listSpaces returns every space in manual (append) order")
    func list() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let first = try await services.createSpace(name: "First")
        let second = try await services.createSpace(name: "Second")
        let spaces = try await services.listSpaces()
        #expect(spaces.count == 2)
        // Manual order (043 · 2B): `createSpace` APPENDS, so the earlier-created
        // space keeps the lower `sort_index` and sorts first (parity with folders).
        #expect(spaces.first?.id == first.id)
        #expect(spaces.last?.id == second.id)
        #expect(spaces.map(\.sortIndex) == [0, 1])
    }

    @Test("deleteSpace removes it; a second delete throws notFound")
    func delete() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Trash me")
        try await services.deleteSpace(id: space.id)
        #expect(try await services.listSpaces().isEmpty)
        await #expect(throws: AtelierError.notFound(entity: "space", id: space.id)) {
            try await services.deleteSpace(id: space.id)
        }
    }

    // MARK: asset placement

    @Test("addAssetToSpace creates an asset row the board read joins to media")
    func addAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        let item = try await services.addAssetToSpace(
            assetID: assetID, to: space.id, x: 10, y: 20, w: 300, h: 200, z: 0)
        #expect(item.kind == .asset)
        #expect(item.assetID == assetID)

        let details = try await services.spaceItems(in: space.id)
        #expect(details.count == 1)
        #expect(details[0].item.id == item.id)
        #expect(details[0].asset?.id == assetID)      // asset row carries media
        #expect(details[0].source != nil)
    }

    @Test("spaceStackPreviews: counts every row, fans asset hashes, skips elements")
    func stackPreviews() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let board = try await services.createSpace(name: "Board")
        let empty = try await services.createSpace(name: "Empty")
        let a1 = try await makeAsset(services, hash: "abc123", url: "https://example.com/1")
        let a2 = try await makeAsset(services, hash: "def456", url: "https://example.com/2")
        _ = try await services.addAssetToSpace(assetID: a1, to: board.id, x: 0, y: 0, w: 10, h: 10, z: 0)
        _ = try await services.addAssetToSpace(assetID: a2, to: board.id, x: 20, y: 0, w: 10, h: 10, z: 1)
        // An element row: counted, but NULL asset_id so it fans no thumbnail.
        _ = try await services.addElement(
            to: board.id, kind: .text,
            style: ElementStyle(text: "Note", fontSize: 18, textColor: "#000000"),
            x: 0, y: 40, w: 100, h: 40, z: 2)

        let previews = try await services.spaceStackPreviews()
        let byID = Dictionary(uniqueKeysWithValues: previews.map { ($0.space.id, $0) })

        #expect(byID[board.id]?.itemCount == 3)                          // 2 assets + 1 element
        #expect(Set(byID[board.id]?.recentBlobHashes ?? []) == ["abc123", "def456"])
        #expect(byID[empty.id]?.itemCount == 0)
        #expect(byID[empty.id]?.recentBlobHashes == [])
    }

    @Test("the same asset may be added twice — each row has its own id")
    func addAssetTwice() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        let a = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 100, h: 100, z: 0)
        let b = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 200, y: 0, w: 100, h: 100, z: 1)
        #expect(a.id != b.id)
        #expect(try await services.spaceItems(in: space.id).count == 2)
    }

    @Test("addAssetToSpace on a missing space / asset throws notFound")
    func addAssetMissing() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let ghostAsset = UUID()
        await #expect(throws: AtelierError.notFound(entity: "asset", id: ghostAsset)) {
            try await services.addAssetToSpace(assetID: ghostAsset, to: space.id, x: 0, y: 0, w: 1, h: 1, z: 0)
        }
        let assetID = try await makeAsset(services)
        let ghostSpace = UUID()
        await #expect(throws: AtelierError.notFound(entity: "space", id: ghostSpace)) {
            try await services.addAssetToSpace(assetID: assetID, to: ghostSpace, x: 0, y: 0, w: 1, h: 1, z: 0)
        }
    }

    @Test("addAssetToSpace rejects a non-positive / non-finite placement")
    func addAssetBadPlacement() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        await #expect(throws: AtelierError.invalidPlacement) {
            try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 0, h: 100, z: 0)
        }
        await #expect(throws: AtelierError.invalidPlacement) {
            try await services.addAssetToSpace(assetID: assetID, to: space.id, x: .nan, y: 0, w: 1, h: 1, z: 0)
        }
    }

    // MARK: elements (E3 surface, validated now)

    @Test("addElement creates an element row with no asset and a decoded style")
    func addElement() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let style = ElementStyle(text: "Section A", fontSize: 24, textColor: "#112233")
        let item = try await services.addElement(
            to: space.id, kind: .text, style: style, x: 0, y: 0, w: 300, h: 80, z: 0)
        #expect(item.kind == .text)
        #expect(item.assetID == nil)

        let details = try await services.spaceItems(in: space.id)
        #expect(details.count == 1)
        #expect(details[0].asset == nil)              // element row carries no media
        #expect(details[0].source == nil)
        #expect(ElementStyle(jsonString: details[0].item.style) == style)
    }

    // MARK: move / restyle / remove

    @Test("setSpaceItemPlacement moves the row and keeps its kind")
    func movePlacement() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        let item = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 100, h: 100, z: 0)
        try await services.setSpaceItemPlacement(itemID: item.id, x: 500, y: 600, w: 120, h: 90, z: 5)
        let moved = try await services.spaceItems(in: space.id).first
        #expect(moved?.item.x == 500)
        #expect(moved?.item.y == 600)
        #expect(moved?.item.w == 120)
        #expect(moved?.item.z == 5)
        #expect(moved?.item.kind == .asset)
    }

    @Test("setSpaceItemPlacement on a missing row throws notFound")
    func moveMissing() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "space_item", id: ghost)) {
            try await services.setSpaceItemPlacement(itemID: ghost, x: 0, y: 0, w: 1, h: 1, z: 0)
        }
    }

    @Test("setSpaceItemPlacements moves MANY rows in one transaction (049 · D13)")
    func batchMove() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        let a = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 10, h: 10, z: 0)
        let b = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 20, y: 0, w: 10, h: 10, z: 1)

        try await services.setSpaceItemPlacements([
            SpaceItemPlacement(itemID: a.id, x: 100, y: 100, w: 10, h: 10, z: 5),
            SpaceItemPlacement(itemID: b.id, x: 200, y: 200, w: 10, h: 10, z: 6),
        ])

        let rows = try await services.spaceItems(in: space.id)
        #expect(rows.first { $0.item.id == a.id }?.item.x == 100)
        #expect(rows.first { $0.item.id == b.id }?.item.x == 200)
        #expect(rows.first { $0.item.id == b.id }?.item.z == 6)
    }

    @Test("setSpaceItemPlacements is all-or-nothing: an unknown id rolls the batch back")
    func batchMoveAtomic() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        let a = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 10, h: 10, z: 0)
        let ghost = UUID()

        // A batch with one valid + one missing id must throw AND leave `a` untouched.
        await #expect(throws: AtelierError.notFound(entity: "space_item", id: ghost)) {
            try await services.setSpaceItemPlacements([
                SpaceItemPlacement(itemID: a.id, x: 999, y: 999, w: 10, h: 10, z: 9),
                SpaceItemPlacement(itemID: ghost, x: 0, y: 0, w: 10, h: 10, z: 0),
            ])
        }
        let rows = try await services.spaceItems(in: space.id)
        #expect(rows.first { $0.item.id == a.id }?.item.x == 0) // rolled back, not 999
    }

    @Test("setSpaceItemPlacements rejects a non-finite / non-positive placement")
    func batchMoveValidation() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        let a = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 10, h: 10, z: 0)

        await #expect(throws: (any Error).self) {
            try await services.setSpaceItemPlacements([
                SpaceItemPlacement(itemID: a.id, x: .nan, y: 0, w: 10, h: 10, z: 0),
            ])
        }
        // The row is untouched (validation ran before the write).
        #expect(try await services.spaceItems(in: space.id).first?.item.x == 0)
    }

    @Test("setSpaceItemPlacements with an empty batch is a no-op")
    func batchMoveEmpty() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        try await services.setSpaceItemPlacements([]) // must not throw
    }

    @Test("removeSpaceItem drops one placement (idempotent) and leaves the asset")
    func remove() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        let item = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 100, h: 100, z: 0)
        try await services.removeSpaceItem(itemID: item.id)
        #expect(try await services.spaceItems(in: space.id).isEmpty)
        // Idempotent — removing again is a no-op, not an error.
        try await services.removeSpaceItem(itemID: item.id)
        // The underlying asset survives (still fetchable).
        _ = try await services.getAsset(id: assetID)
    }

    @Test("restoreSpaceItem re-inserts a removed row verbatim (undo primitive)")
    func restore() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let element = try await services.addElement(
            to: space.id, kind: .text, style: ElementStyle(text: "hi"),
            x: 10, y: 20, w: 200, h: 60, z: 3)
        try await services.removeSpaceItem(itemID: element.id)
        #expect(try await services.spaceItems(in: space.id).isEmpty)

        // Restore brings it back with the SAME id, kind, geometry, and style.
        try await services.restoreSpaceItem(element)
        let rows = try await services.spaceItems(in: space.id)
        #expect(rows.count == 1)
        #expect(rows.first?.item.id == element.id)
        #expect(rows.first?.item.kind == .text)
        #expect(rows.first?.item.z == 3)
        #expect(ElementStyle(jsonString: rows.first?.item.style ?? nil)?.text == "hi")

        // Idempotent — restoring an already-present row is a no-op (redo safety).
        try await services.restoreSpaceItem(element)
        #expect(try await services.spaceItems(in: space.id).count == 1)
    }

    @Test("restoreSpaceItem into a missing space throws notFound")
    func restoreMissingSpace() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghostSpace = UUID()
        let orphan = SpaceItem(
            id: UUID(), spaceID: ghostSpace, kind: .frame, assetID: nil,
            x: 0, y: 0, w: 100, h: 100, z: 0, style: nil, createdAt: Date(), updatedAt: Date())
        await #expect(throws: AtelierError.notFound(entity: "space", id: ghostSpace)) {
            try await services.restoreSpaceItem(orphan)
        }
    }

    // MARK: cover

    @Test("setSpaceCover points the space at an asset; missing asset throws notFound")
    func cover() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        try await services.setSpaceCover(spaceID: space.id, assetID: assetID)
        #expect(try await services.getSpace(id: space.id).coverAssetID == assetID)
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "asset", id: ghost)) {
            try await services.setSpaceCover(spaceID: space.id, assetID: ghost)
        }
    }

    // MARK: read guards + ordering

    @Test("spaceItems on a missing space throws notFound")
    func readMissingSpace() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "space", id: ghost)) {
            _ = try await services.spaceItems(in: ghost)
        }
    }

    @Test("spaceItems is ordered by z ascending")
    func readOrder() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let space = try await services.createSpace(name: "Board")
        let assetID = try await makeAsset(services)
        _ = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 1, h: 1, z: 5)
        _ = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 1, h: 1, z: 1)
        _ = try await services.addAssetToSpace(assetID: assetID, to: space.id, x: 0, y: 0, w: 1, h: 1, z: 3)
        let zs = try await services.spaceItems(in: space.id).map(\.item.z)
        #expect(zs == [1, 3, 5])
    }

    @Test("spaceCovers maps only spaces with a (surviving) cover")
    func covers() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let withCover = try await services.createSpace(name: "Has cover")
        let withoutCover = try await services.createSpace(name: "No cover")
        let assetID = try await makeAsset(services, hash: "aa11bb")
        try await services.setSpaceCover(spaceID: withCover.id, assetID: assetID)
        let covers = try await services.spaceCovers([withCover.id, withoutCover.id])
        #expect(covers[withCover.id] == "aa11bb")
        #expect(covers[withoutCover.id] == nil)
    }
}

@Suite("Services: collection covers read (004-P2)")
struct ServicesCollectionCoverTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    @Test("collectionCovers maps only collections that have a (surviving) cover")
    func covers() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let withCover = try await services.createCollection(name: "Has cover")
        let withoutCover = try await services.createCollection(name: "No cover")
        let asset = AssetDraft(
            kind: .image, blobHash: "ff00ab", mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 100, downloadState: .downloaded)
        let source = SourceDraft(platform: .web, originalURL: "https://example.com/x", capturedAt: Date())
        let assetID = try await services.ingest(asset, from: source, into: withCover.id).asset.id
        try await services.setCollectionCover(collectionID: withCover.id, assetID: assetID)

        let covers = try await services.collectionCovers([withCover.id, withoutCover.id])
        #expect(covers[withCover.id] == "ff00ab")
        #expect(covers[withoutCover.id] == nil)
    }

    @Test("collectionCovers of an empty id list returns empty")
    func emptyInput() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        #expect(try await services.collectionCovers([]).isEmpty)
    }
}
