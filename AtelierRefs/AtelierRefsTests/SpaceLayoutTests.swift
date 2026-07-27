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
        let rects = SpaceLayout.flowIn(aspects: Array(repeating: 1.0, count: 8), originY: 0, startZ: 0)
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
        let rects = SpaceLayout.flowIn(aspects: [1.0, 1.0], originY: 500, startZ: 10)
        #expect(rects[0].y == 500)
        #expect(rects.map(\.z) == [10, 11])
    }

    @Test("originX shifts the whole flow right and moves the wrap boundary with it")
    func originXShiftsFlowAndWrap() {
        // 6 squares fit per row from x=0; the same must hold from any originX, i.e.
        // the wrap boundary travels with the origin (not pinned at absolute 1600).
        let rects = SpaceLayout.flowIn(
            aspects: Array(repeating: 1.0, count: 8), originX: 1000, originY: 50, startZ: 0)
        #expect(rects[0].x == 1000)          // first tile sits at the origin
        #expect(rects[0].y == 50)
        #expect(rects[5].y == 50)            // 6th still on the first row
        #expect(rects[6].y == 50 + SpaceLayout.rowHeight + SpaceLayout.spacing) // 7th wraps
        #expect(rects[6].x == 1000)          // wrapped tile returns to originX, not 0
    }
}

@Suite("SpaceLayout: centred drop-at-point flow (6A)")
struct SpaceLayoutCenteredFlowTests {

    @Test("a single item lands with its centre exactly on the drop point")
    func singleCentred() {
        // A 2:1 landscape aspect → w = 480, h = 240 (rowHeight).
        let rects = SpaceLayout.flowIn(aspects: [2.0], centeredOn: (x: 100, y: 200), startZ: 5)
        #expect(rects.count == 1)
        #expect(rects[0].w == SpaceLayout.rowHeight * 2)
        #expect(rects[0].h == SpaceLayout.rowHeight)
        #expect(rects[0].x + rects[0].w / 2 == 100)   // centre-x on the point
        #expect(rects[0].y + rects[0].h / 2 == 200)   // centre-y on the point
        #expect(rects[0].z == 5)
    }

    @Test("a block's bounding box is centred on the point; internal packing preserved")
    func blockCentred() {
        let aspects = Array(repeating: 1.0, count: 3)
        let centred = SpaceLayout.flowIn(aspects: aspects, centeredOn: (x: 0, y: 0), startZ: 0)
        // The bounding box of the centred block must straddle the origin evenly.
        let box = SpaceLayout.boundingBox(centred)!
        #expect(abs(box.minX + box.width / 2) < 1e-9)
        #expect(abs(box.minY + box.height / 2) < 1e-9)
        // Centring is a pure translation of the origin-packed block: relative
        // offsets between tiles are identical to the top-left flow.
        let packed = SpaceLayout.flowIn(aspects: aspects, originY: 0, startZ: 0)
        let dx = centred[0].x - packed[0].x, dy = centred[0].y - packed[0].y
        for (c, p) in zip(centred, packed) {
            #expect(abs((c.x - p.x) - dx) < 1e-9)
            #expect(abs((c.y - p.y) - dy) < 1e-9)
        }
    }

    @Test("empty input yields no placements (no crash, no phantom tile)")
    func emptyCentred() {
        #expect(SpaceLayout.flowIn(aspects: [], centeredOn: (x: 10, y: 10), startZ: 0).isEmpty)
    }

    @Test("boundingBox spans the union of all rects; nil when empty")
    func boundingBoxSpansUnion() {
        #expect(SpaceLayout.boundingBox([]) == nil)
        let rects = [
            PlacedRect(x: 10, y: 20, w: 30, h: 40, z: 0),
            PlacedRect(x: -5, y: 100, w: 15, h: 10, z: 1),
        ]
        let box = SpaceLayout.boundingBox(rects)!
        #expect(box.minX == -5)
        #expect(box.minY == 20)
        #expect(box.width == 45)   // from -5 to 40
        #expect(box.height == 90)  // from 20 to 110
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

    private func assetDetail(z: Int, dim: Int,
                             x: Double? = nil, y: Double = 0, w: Double = 120, h: Double = 90) -> SpaceItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: UUID().uuidString,
            mimeType: "image/png", width: dim, height: 100, duration: nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
        let item = SpaceItem(
            id: UUID(), spaceID: UUID(), kind: .asset, assetID: assetID,
            x: x ?? Double(z) * 10, y: y, w: w, h: h, z: z, style: nil,
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

    private func frameDetail(x: Double, y: Double, w: Double, h: Double) -> SpaceItemDetail {
        let item = SpaceItem(
            id: UUID(), spaceID: UUID(), kind: .frame, assetID: nil,
            x: x, y: y, w: w, h: h, z: -1,
            style: ElementStyle(strokeColor: "#000000", strokeWidth: 2).jsonString(),
            createdAt: Date(), updatedAt: Date())
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

    @Test("element rows now draw as vector tiles (E3), mapped to .text/.frame")
    func drawsElementRows() {
        let asset = assetDetail(z: 0, dim: 120)
        let element = elementDetail()
        let content = makeContent([asset, element])
        #expect(content.tiles.count == 2) // asset + text element both draw
        // The element tile carries text content; the asset tile stays an image.
        let assetTile = content.tiles[content.tileID(forSpaceItemID: asset.item.id)!]
        let textTile = content.tiles[content.tileID(forSpaceItemID: element.item.id)!]
        #expect(content.content(for: assetTile) == .image)
        if case .text(let style) = content.content(for: textTile) {
            #expect(style.string == "hi")
        } else {
            Issue.record("element row should map to .text content")
        }
    }

    @Test("dragging a frame carries the tiles whose centre it contains")
    func frameGroupsContainedTiles() {
        // A frame covering the origin region; an asset tile inside it; one outside.
        let frame = frameDetail(x: 0, y: 0, w: 400, h: 400)
        let inside = assetDetail(z: 1, dim: 120, x: 50, y: 50, w: 100, h: 100)
        let outside = assetDetail(z: 2, dim: 120, x: 900, y: 900, w: 100, h: 100)
        let content = makeContent([frame, inside, outside])
        let frameTile = content.tileID(forSpaceItemID: frame.item.id)!
        let insideTile = content.tileID(forSpaceItemID: inside.item.id)!
        let members = content.groupMembers(forDraggedTileID: frameTile)
        #expect(members == [insideTile])
    }

    @Test("selection round-trips tile id ↔ space_item id")
    func selectionMapping() {
        let a = assetDetail(z: 0, dim: 120)
        let content = makeContent([a])
        let tileID = content.tileID(forSpaceItemID: a.item.id)
        #expect(tileID == 0)
        #expect(content.spaceItemID(forTileID: 0) == a.item.id)
    }

    @Test("dragOutPayload: z-ordered asset ids, membership-less source, skips elements")
    func dragOutPayloadAssetsOnly() {
        let a = assetDetail(z: 1, dim: 120)   // z 1
        let b = assetDetail(z: 0, dim: 120)   // z 0 — earlier in z-order
        let element = elementDetail()          // no asset — skipped
        let content = makeContent([a, b, element])
        let allTiles = Set(0..<3)

        let payload = content.dragOutPayload(forTileIDs: allTiles)
        #expect(payload != nil)
        // z-ordered (b z0 before a z1); the element contributes nothing.
        #expect(payload?.assetIDs == [b.asset!.id, a.asset!.id])
        // Membership-less, so a drop on a board / collection COPIES (never moves).
        #expect(payload?.sourceCollectionID == AssetDragPayload.nilSourceID)
    }

    @Test("dragOutPayload is nil when no dragged tile carries an asset")
    func dragOutPayloadNilForElementsOnly() {
        let content = makeContent([elementDetail(), frameDetail(x: 0, y: 0, w: 10, h: 10)])
        #expect(content.dragOutPayload(forTileIDs: Set(0..<2)) == nil)
        #expect(content.dragOutPayload(forTileIDs: []) == nil)
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
