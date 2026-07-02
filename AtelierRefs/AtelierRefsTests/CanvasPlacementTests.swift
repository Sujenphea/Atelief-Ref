//
//  CanvasPlacementTests.swift
//  AtelierRefsTests
//
//  Guards the in-memory half of canvas drag-to-place: `CanvasContent.setPlacement`
//  must move the RIGHT tile to the new origin while preserving its `w/h/z` (so a
//  later provider rebuild reproduces the dropped size), and leave every other
//  tile untouched. The tile ↔ asset mapping the move persists through must stay
//  correct — a mismatch here would persist a placement against the wrong asset.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("CanvasContent drag-to-place")
struct CanvasPlacementTests {

    /// A detail with distinct membership + asset ids and no canvas placement
    /// (so tiles auto-lay in order, `tile.id == index`). `dim` sets the asset's
    /// pixel size so tiles get distinct aspect-driven widths.
    private func detail(order: Int, dim: Int) -> CollectionItemDetail {
        let sourceID = UUID()
        let assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: String(format: "%08x", order),
            mimeType: "image/png", width: dim, height: 100, duration: nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(),
            sourceId: sourceID)
        let item = CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date())
        return CollectionItemDetail(item: item, asset: asset, source: source)
    }

    private func makeContent(_ details: [CollectionItemDetail]) -> CanvasContent {
        CanvasContent(items: details, store: MediaStore(root: FileManager.default.temporaryDirectory))
    }

    @Test("setPlacement moves the right tile to the new origin")
    func movesTargetTile() {
        let details = (0..<3).map { detail(order: $0, dim: 100 + $0 * 40) }
        let content = makeContent(details)

        content.setPlacement(tileID: 1, x: 900, y: -250)

        #expect(content.tiles[1].x == 900)
        #expect(content.tiles[1].y == -250)
    }

    @Test("setPlacement preserves the tile's w / h / z")
    func preservesSize() {
        let details = (0..<3).map { detail(order: $0, dim: 100 + $0 * 40) }
        let content = makeContent(details)
        let before = content.tiles[1]

        content.setPlacement(tileID: 1, x: 900, y: -250)

        let after = content.tiles[1]
        #expect(after.w == before.w)
        #expect(after.h == before.h)
        #expect(after.z == before.z)
        #expect(after.id == before.id)
    }

    @Test("setPlacement leaves other tiles untouched")
    func othersUnchanged() {
        let details = (0..<3).map { detail(order: $0, dim: 100 + $0 * 40) }
        let content = makeContent(details)
        let before0 = content.tiles[0]
        let before2 = content.tiles[2]

        content.setPlacement(tileID: 1, x: 900, y: -250)

        #expect(content.tiles[0] == before0)
        #expect(content.tiles[2] == before2)
    }

    @Test("out-of-range tile id is a safe no-op")
    func outOfRangeNoOp() {
        let details = (0..<2).map { detail(order: $0, dim: 100) }
        let content = makeContent(details)
        let snapshot = content.tiles

        content.setPlacement(tileID: 5, x: 10, y: 10)
        content.setPlacement(tileID: -1, x: 10, y: 10)

        #expect(content.tiles == snapshot)
    }

    @Test("the moved tile still resolves to its own asset (persist targets it)")
    func mappingStaysCorrect() {
        let details = (0..<3).map { detail(order: $0, dim: 100 + $0 * 40) }
        let content = makeContent(details)

        content.setPlacement(tileID: 2, x: 12, y: 34)
        // The origin the move persists must belong to tile 2's asset.
        #expect(content.detail(forTileID: 2)?.asset.id == details[2].asset.id)
        #expect(content.tiles[2].x == 12)
        #expect(content.tiles[2].y == 34)
    }
}
