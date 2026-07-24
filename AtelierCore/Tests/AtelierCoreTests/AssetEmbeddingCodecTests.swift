// AtelierCore — embedding vector BLOB codec ([Float] ↔ Data), 047 · 3a.
//
// Pins the exact byte layout (512 × Float32 little-endian) so a library file
// stays readable across runs / architectures and a regression names the rule.

import Foundation
import Testing
@testable import AtelierCore

@Suite("AssetEmbedding vector codec (047)")
struct AssetEmbeddingCodecTests {

    @Test("round-trips an arbitrary vector exactly (Float32 is bit-stable)")
    func roundTrip() {
        let v: [Float] = [0, 1, -1, 3.5, -2.25, 1e-8, 1e8, .pi]
        let data = AssetEmbedding.encode(v)
        #expect(data.count == v.count * 4)
        #expect(AssetEmbedding.vectorFloats(data) == v)
    }

    @Test("packs little-endian Float32 bytes (host-independent)")
    func littleEndianLayout() {
        // Float32(1.0).bitPattern == 0x3F80_0000 → LE bytes 00 00 80 3F.
        let data = AssetEmbedding.encode([1.0])
        #expect(Array(data) == [0x00, 0x00, 0x80, 0x3F])
    }

    @Test("empty vector ↔ empty data")
    func empty() {
        #expect(AssetEmbedding.encode([]).isEmpty)
        #expect(AssetEmbedding.vectorFloats(Data()) == [])
    }

    @Test("a realistic 512-d unit vector survives the round-trip")
    func fullWidth() {
        let raw = (0..<512).map { Float($0) * 0.001 - 0.25 }
        let norm = raw.map { $0 / (raw.map { $0 * $0 }.reduce(0, +)).squareRoot() }
        let back = AssetEmbedding.vectorFloats(AssetEmbedding.encode(norm))
        #expect(back.count == 512)
        #expect(back == norm)
    }

    @Test("trailing partial-lane bytes are ignored, not crashed on")
    func trailingBytesIgnored() {
        var data = AssetEmbedding.encode([1, 2])   // 8 bytes
        data.append(0x42)                           // a stray 9th byte
        #expect(AssetEmbedding.vectorFloats(data) == [1, 2])
    }
}
