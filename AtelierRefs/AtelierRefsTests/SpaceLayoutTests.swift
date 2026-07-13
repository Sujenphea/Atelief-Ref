//
//  SpaceLayoutTests.swift
//  AtelierRefsTests
//
//  005-E2 — the pure placement math for spaces: justified-rows flow-in for a
//  batch of added assets, and the "New Space from collection" seeding that
//  honours explicit folder-canvas placement and flows the rest below.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import Foundation
import Testing
@testable import AtelierRefs

@Suite("SpaceLayout: flow-in")
struct SpaceLayoutFlowTests {

    @Test("square aspects pack into rows, wrap at maxRowWidth, and z increments")
    func packsAndWraps() {
        // width per square = rowHeight (240); 6 fit before the 7th wraps
        // (240*6 + 16*5 = 1520 ≤ 1600; a 7th would exceed).
        let rects = SpaceLayout.flowIn(aspects: Array(repeating: 1.0, count: 8), startY: 0, startZ: 0)
        #expect(rects.count == 8)
        // First row shares startY; the 7th drops to the next row.
        #expect(rects[0].y == 0)
        #expect(rects[5].y == 0)
        #expect(rects[6].y == SpaceLayout.rowHeight + SpaceLayout.spacing)
        // z runs from startZ upward in order.
        #expect(rects.map(\.z) == Array(0..<8))
        // The first tile starts at x = 0.
        #expect(rects[0].x == 0)
        #expect(rects[0].w == SpaceLayout.rowHeight) // square → w == h
    }

    @Test("flow-in honours startY and startZ offsets")
    func offsets() {
        let rects = SpaceLayout.flowIn(aspects: [1.0, 1.0], startY: 500, startZ: 10)
        #expect(rects[0].y == 500)
        #expect(rects.map(\.z) == [10, 11])
    }
}

@Suite("SpaceLayout: seeding from a collection")
struct SpaceLayoutSeedTests {

    private func detail(dim: Int, x: Double? = nil, y: Double? = nil, w: Double? = nil, h: Double? = nil, z: Int? = nil) -> CollectionItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: UUID().uuidString,
            mimeType: "image/png", width: dim, height: 100, duration: nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
        let item = CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date(),
            canvasX: x, canvasY: y, canvasW: w, canvasH: h, canvasZ: z)
        return CollectionItemDetail(item: item, asset: asset, source: source)
    }

    @Test("explicitly-placed items keep their rect; unplaced items flow below")
    func honoursPlacementAndFlowsBelow() {
        let placed = detail(dim: 100, x: 100, y: 100, w: 300, h: 200, z: 7)
        let unplaced = detail(dim: 100)
        let rects = SpaceLayout.placements(seedingFrom: [placed, unplaced])
        // Placed one is verbatim.
        #expect(rects[0] == PlacedRect(x: 100, y: 100, w: 300, h: 200, z: 7))
        // Flowed one starts BELOW the placed bounding box (y+h+spacing = 316).
        #expect(rects[1].y == 100 + 200 + SpaceLayout.spacing)
    }

    @Test("all-unplaced items flow from the origin")
    func allUnplaced() {
        let rects = SpaceLayout.placements(seedingFrom: [detail(dim: 100), detail(dim: 100)])
        #expect(rects[0].y == 0)
        #expect(rects[0].x == 0)
        #expect(rects[1].x > 0)   // second packs to the right of the first
    }
}

@MainActor
@Suite("SpaceContent: tile mapping")
struct SpaceContentTests {

    private func assetDetail(z: Int, dim: Int) -> SpaceItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: UUID().uuidString,
            mimeType: "image/png", width: dim, height: 100, duration: nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
        let item = SpaceItem(
            id: UUID(), spaceID: UUID(), kind: .asset, assetID: assetID,
            x: Double(z) * 10, y: 0, w: 120, h: 90, z: z, style: nil,
            createdAt: Date(), updatedAt: Date())
        return SpaceItemDetail(item: item, asset: asset, source: source)
    }

    private func elementDetail() -> SpaceItemDetail {
        let item = SpaceItem(
            id: UUID(), spaceID: UUID(), kind: .text, assetID: nil,
            x: 0, y: 0, w: 200, h: 60, z: 99,
            style: ElementStyle(text: "hi").jsonString(), createdAt: Date(), updatedAt: Date())
        return SpaceItemDetail(item: item, asset: nil, source: nil)
    }

    private func makeContent(_ details: [SpaceItemDetail]) -> SpaceContent {
        SpaceContent(items: details, store: MediaStore(root: FileManager.default.temporaryDirectory))
    }

    @Test("asset rows become tiles reading their persisted placement")
    func mapsAssetRows() {
        let a = assetDetail(z: 0, dim: 120), b = assetDetail(z: 1, dim: 120)
        let content = makeContent([a, b])
        #expect(content.tiles.count == 2)
        #expect(content.tiles[1].x == 10)   // z*10
        #expect(content.tiles[0].w == 120)
        #expect(content.spaceItemID(forTileID: 0) == a.item.id)
    }

    @Test("element rows are skipped in v1 (no vector tile path yet)")
    func skipsElementRows() {
        let content = makeContent([assetDetail(z: 0, dim: 120), elementDetail()])
        #expect(content.tiles.count == 1)   // only the asset row draws
    }

    @Test("selection round-trips tile id ↔ space_item id")
    func selectionMapping() {
        let a = assetDetail(z: 0, dim: 120)
        let content = makeContent([a])
        let tileID = content.tileID(forSpaceItemID: a.item.id)
        #expect(tileID == 0)
        #expect(content.spaceItemID(forTileID: 0) == a.item.id)
    }

    @Test("in-memory setPlacement moves a tile, keeping w/h/z")
    func setPlacement() {
        let a = assetDetail(z: 3, dim: 120)
        let content = makeContent([a])
        let before = content.tiles[0]
        content.setPlacement(tileID: 0, x: 800, y: -200)
        let after = content.tiles[0]
        #expect(after.x == 800)
        #expect(after.y == -200)
        #expect(after.w == before.w)
        #expect(after.z == before.z)
    }
}
