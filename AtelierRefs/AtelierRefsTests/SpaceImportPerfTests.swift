//
//  SpaceImportPerfTests.swift
//  AtelierRefsTests
//
//  059 · SP6 / 15A — perf VERIFICATION for a large on-screen drop. Point placement
//  lands imported tiles on-screen (unlike the flow-below add), so the worry was a
//  100-image drop bursting 100 simultaneous thumbnail decodes. Imported items are
//  ordinary `space_item`s rendered by the SAME `SpaceContent` → `CanvasEngine`
//  path as any board, so the existing culler + `DecodeScheduler` already bound the
//  working set to what's VISIBLE. These tests pin that: a normal viewport activates
//  far fewer than 100 layers (bounded decode, no bespoke throttle), while a viewport
//  large enough to see everything activates all 100 (proving the bound is real
//  culling, not an artificial cap).
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Space import: 100-drop culling (SP6 · 15A)")
struct SpaceImportPerfTests {

    /// One asset row placed at an explicit rect, mirroring an imported `space_item`.
    private func placedAsset(z: Int, rect: PlacedRect) -> SpaceItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: UUID().uuidString,
            mimeType: "image/png", width: 240, height: 240, duration: nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
        let item = SpaceItem(
            id: UUID(), spaceID: UUID(), kind: .asset, assetID: assetID,
            x: rect.x, y: rect.y, w: rect.w, h: rect.h, z: rect.z, style: nil,
            createdAt: Date(), updatedAt: Date())
        return SpaceItemDetail(item: item, asset: asset, source: source)
    }

    /// 100 square tiles flowed into a justified block from the origin — the exact
    /// shape `insertPlaced` produces for a 100-image drop.
    private func hundredTileContent() -> SpaceContent {
        let rects = SpaceLayout.flowIn(
            aspects: Array(repeating: 1.0, count: 100), originY: 0, startZ: 0)
        let details = rects.enumerated().map { placedAsset(z: $0.offset, rect: $0.element) }
        return SpaceContent(
            items: details, store: MediaStore(root: FileManager.default.temporaryDirectory))
    }

    private func engine(over content: SpaceContent, viewport: CGSize) -> CanvasEngine {
        CanvasEngine(
            provider: content, images: content,
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: viewport,
            prefetchMarginScreen: 0) // deterministic visible set — no prefetch halo
    }

    @Test("a 100-image drop places 100 tiles but a normal viewport activates far fewer")
    func normalViewportBoundsActiveLayers() {
        let content = hundredTileContent()
        #expect(content.tiles.count == 100)

        // A typical board viewport sees only a slice of the ~1520×4300 block.
        let engine = engine(over: content, viewport: CGSize(width: 1280, height: 800))
        engine.sync()
        // The whole point of 15A: the culler bounds the working set (→ bounded
        // decode), so an on-screen 100-drop never activates all 100 at once.
        #expect(engine.activeLayerCount < 100)
        #expect(engine.activeLayerCount > 0)
    }

    @Test("the bound is real culling: a viewport large enough activates all 100")
    func hugeViewportActivatesEverything() {
        let content = hundredTileContent()
        // A viewport that comfortably contains the entire block → every tile visible,
        // so all 100 activate. Proves the small-viewport bound is culling, not a cap.
        let engine = engine(over: content, viewport: CGSize(width: 4000, height: 6000))
        engine.sync()
        #expect(engine.activeLayerCount == 100)
    }
}
