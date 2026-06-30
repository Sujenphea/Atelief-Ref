import CoreGraphics

/// Generates a deterministic, realistically-distributed set of dummy ``Tile``s
/// for the spike (decisions T12 + C8). "Realistic" matters: a real board is
/// *clustered* with *varied* sizes/aspect ratios, not a uniform grid, so the
/// benchmark must stress overlap and mixed LOD — otherwise it green-lights a
/// renderer that stutters on real data.
public struct DummyTileGenerator {
    public struct Config: Sendable {
        /// Total tiles to generate (decision P13 target: ~5,000).
        public var count: Int
        /// Number of spatial clusters the tiles gather around.
        public var clusterCount: Int
        /// Spread of tiles around their cluster centre (world units).
        public var clusterSpread: Double
        /// Half-extent of the square region cluster centres are drawn from.
        public var worldExtent: Double
        /// Smallest tile edge (world units).
        public var minEdge: Double
        /// Largest tile edge (world units).
        public var maxEdge: Double

        public init(
            count: Int = 5_000,
            clusterCount: Int = 40,
            clusterSpread: Double = 700,
            worldExtent: Double = 20_000,
            minEdge: Double = 80,
            maxEdge: Double = 600
        ) {
            self.count = count
            self.clusterCount = clusterCount
            self.clusterSpread = clusterSpread
            self.worldExtent = worldExtent
            self.minEdge = minEdge
            self.maxEdge = maxEdge
        }
    }

    public init() {}

    /// Produces `config.count` tiles. Identical `seed` + `config` ⇒ identical
    /// output. Tiles have unique ids `0..<count`, unique `z` (creation order),
    /// and are guaranteed non-degenerate.
    public func generate(seed: UInt64 = 0xA7E1, config: Config = Config()) -> [Tile] {
        precondition(config.count >= 0)
        precondition(config.clusterCount >= 1)
        precondition(config.minEdge > 0 && config.maxEdge >= config.minEdge)

        var rng = SeededRandom(seed: seed)

        var centres: [(x: Double, y: Double)] = []
        centres.reserveCapacity(config.clusterCount)
        for _ in 0..<config.clusterCount {
            centres.append((
                Double.random(in: -config.worldExtent...config.worldExtent, using: &rng),
                Double.random(in: -config.worldExtent...config.worldExtent, using: &rng)
            ))
        }

        var tiles: [Tile] = []
        tiles.reserveCapacity(config.count)
        for i in 0..<config.count {
            let centre = centres[Int.random(in: 0..<config.clusterCount, using: &rng)]
            let x = centre.x + gaussianUnit(&rng) * config.clusterSpread
            let y = centre.y + gaussianUnit(&rng) * config.clusterSpread

            let w = Double.random(in: config.minEdge...config.maxEdge, using: &rng)
            let aspect = Double.random(in: 0.5...2.0, using: &rng)
            let h = min(config.maxEdge, max(config.minEdge, w / aspect))

            tiles.append(Tile(id: i, x: x, y: y, w: w, h: h, z: i))
        }
        return tiles
    }

    /// Approximately-normal sample in ~[-3, 3] via Irwin–Hall (sum of 6 uniforms
    /// minus 3). Good enough to cluster tiles believably; no Foundation needed.
    private func gaussianUnit(_ rng: inout SeededRandom) -> Double {
        var sum = 0.0
        for _ in 0..<6 { sum += Double.random(in: 0...1, using: &rng) }
        return sum - 3.0
    }
}
