/// The spike's concrete ``TileProvider`` (decision A2): a fixed, deterministic
/// set of generated tiles. At build-order step 5 this is replaced by a
/// `CollectionItem`-backed provider; nothing above the seam changes.
//
//  099 · 8A — the spike's fixture data is DEBUG-only.
//
//  `Spike/` exists to feed the canvas harnesses: a seeded PRNG, a dummy tile
//  generator and a handful of procedurally-drawn fixture images. Its only
//  consumers are `CanvasRendererTests` (`CanvasBenchmark`, `CanvasPinchTests`,
//  `SpikeDataTests`) and the app's own `Debug/` bake-off — both of which build
//  in debug. Nothing in a shipped app draws a dummy tile, and the one mention
//  of these types outside the spike and its tests is a doc comment.
//

#if DEBUG

public struct DummyTileProvider: TileProvider {
    public let tiles: [Tile]

    public init(tiles: [Tile]) {
        self.tiles = tiles
    }

    /// Convenience: generate tiles directly from a seed + config.
    public init(seed: UInt64 = 0xA7E1, config: DummyTileGenerator.Config = DummyTileGenerator.Config()) {
        self.tiles = DummyTileGenerator().generate(seed: seed, config: config)
    }
}

#endif  // DEBUG
