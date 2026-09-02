/// A deterministic `RandomNumberGenerator` (SplitMix64) so the spike's tile
/// layout and fixture images are **byte-for-byte reproducible** across runs
/// (decision T12). Reproducibility is what lets the benchmark detect regressions
/// and lets culling tests assert exact sets.
///
/// Not cryptographic — purely for reproducible test/benchmark data.
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

public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // Avoid the all-zero fixed point.
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

#endif  // DEBUG
