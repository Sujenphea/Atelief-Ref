/// The spike's concrete ``TileProvider`` (decision A2): a fixed, deterministic
/// set of generated tiles. At build-order step 5 this is replaced by a
/// `CollectionItem`-backed provider; nothing above the seam changes.
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
