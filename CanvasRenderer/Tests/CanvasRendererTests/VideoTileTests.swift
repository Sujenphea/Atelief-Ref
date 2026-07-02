import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

/// The two renderer additions for video assets (checkpoint D): a ▶ badge overlay
/// for badged tiles, and screen-point → tile hit-testing for double-click open.
/// Pure geometry / layer bookkeeping — no window needed.
@MainActor
@Suite("Video tiles (badge + hit-test)")
struct VideoTileTests {
    /// Explicit tiles where a chosen subset are "videos" (return a play badge).
    private struct BadgedProvider: TileProvider {
        let tiles: [Tile]
        let videoIDs: Set<Int>
        func badge(for tile: Tile) -> TileBadge? {
            videoIDs.contains(tile.id) ? .play : nil
        }
    }
    /// No thumbnails — this suite asserts layer bookkeeping, not pixels.
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private func makeEngine(_ provider: BadgedProvider) -> CanvasEngine {
        CanvasEngine(
            provider: provider, images: NoImages(),
            transform: CanvasTransform(), // identity: world == screen
            viewportSize: CGSize(width: 1_000, height: 1_000))
    }

    // Three 200×200 tiles in a row; ids 0 and 2 are videos.
    private let row = [
        Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 1, x: 220, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 2, x: 440, y: 0, w: 200, h: 200, z: 0),
    ]

    @Test("a ▶ badge layer is added only for video tiles")
    func badgesOnlyForVideos() {
        let engine = makeEngine(BadgedProvider(tiles: row, videoIDs: [0, 2]))
        engine.sync()
        #expect(engine.activeLayerCount == 3) // three tile layers
        // 3 tile layers + 2 badge layers (ids 0, 2).
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 5)
    }

    @Test("no badges when no tile is a video")
    func noBadges() {
        let engine = makeEngine(BadgedProvider(tiles: row, videoIDs: []))
        engine.sync()
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 3) // tiles only
    }

    @Test("badges are dropped when their tile is panned out of view")
    func badgesDroppedOffscreen() {
        let engine = makeEngine(BadgedProvider(tiles: row, videoIDs: [0, 2]))
        engine.sync()
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 5)
        // Pan far past all tiles: nothing visible → no tile or badge layers.
        engine.pan(byScreenDelta: CGSize(width: -5_000, height: 0))
        #expect(engine.activeLayerCount == 0)
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 0)
    }

    @Test("hit-test resolves a screen point to the tile under it")
    func hitTest() {
        let engine = makeEngine(BadgedProvider(tiles: row, videoIDs: [0]))
        engine.sync()
        #expect(engine.tile(atScreenPoint: CGPoint(x: 100, y: 100))?.id == 0)
        #expect(engine.tile(atScreenPoint: CGPoint(x: 320, y: 100))?.id == 1)
        #expect(engine.tile(atScreenPoint: CGPoint(x: 540, y: 100))?.id == 2)
        #expect(engine.tile(atScreenPoint: CGPoint(x: 210, y: 100)) == nil) // gap
        #expect(engine.tile(atScreenPoint: CGPoint(x: 100, y: 900)) == nil) // empty
    }

    @Test("hit-test picks the topmost tile when two overlap")
    func hitTestTopmost() {
        let stacked = [
            Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
            Tile(id: 1, x: 50, y: 50, w: 200, h: 200, z: 5), // higher z, on top
        ]
        let engine = makeEngine(BadgedProvider(tiles: stacked, videoIDs: []))
        engine.sync()
        // (100,100) is inside both; the higher-z tile wins.
        #expect(engine.tile(atScreenPoint: CGPoint(x: 100, y: 100))?.id == 1)
    }
}
