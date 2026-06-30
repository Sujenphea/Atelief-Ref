import CoreGraphics
import ImageIO
import Testing
@testable import CanvasRenderer

@Suite("SeededRandom")
struct SeededRandomTests {
    @Test("the same seed yields the same sequence")
    func deterministic() {
        var a = SeededRandom(seed: 42)
        var b = SeededRandom(seed: 42)
        let seqA = (0..<16).map { _ in a.next() }
        let seqB = (0..<16).map { _ in b.next() }
        #expect(seqA == seqB)
    }

    @Test("different seeds diverge")
    func differentSeeds() {
        var a = SeededRandom(seed: 1)
        var b = SeededRandom(seed: 2)
        #expect(a.next() != b.next())
    }

    @Test("seed 0 is handled (no all-zero fixed point)")
    func seedZero() {
        var a = SeededRandom(seed: 0)
        let values = (0..<8).map { _ in a.next() }
        #expect(Set(values).count > 1) // not stuck at a constant
    }
}

@Suite("DummyTileGenerator")
struct DummyTileGeneratorTests {
    let config = DummyTileGenerator.Config(count: 1_000, clusterCount: 20)

    @Test("produces exactly `count` tiles")
    func count() {
        let tiles = DummyTileGenerator().generate(seed: 7, config: config)
        #expect(tiles.count == 1_000)
    }

    @Test("output is deterministic for a fixed seed + config (T12)")
    func deterministic() {
        let a = DummyTileGenerator().generate(seed: 7, config: config)
        let b = DummyTileGenerator().generate(seed: 7, config: config)
        #expect(a == b)
    }

    @Test("a different seed produces a different layout")
    func seedChangesLayout() {
        let a = DummyTileGenerator().generate(seed: 7, config: config)
        let b = DummyTileGenerator().generate(seed: 8, config: config)
        #expect(a != b)
    }

    @Test("ids and z are unique and contiguous")
    func uniqueIdentity() {
        let tiles = DummyTileGenerator().generate(seed: 7, config: config)
        #expect(Set(tiles.map(\.id)) == Set(0..<1_000))
        #expect(Set(tiles.map(\.z)).count == 1_000)
    }

    @Test("no tile is degenerate and every edge is within configured bounds")
    func wellFormedSizes() {
        let tiles = DummyTileGenerator().generate(seed: 7, config: config)
        for tile in tiles {
            #expect(!tile.isDegenerate)
            #expect(tile.w >= config.minEdge - 1e-9 && tile.w <= config.maxEdge + 1e-9)
            #expect(tile.h >= config.minEdge - 1e-9 && tile.h <= config.maxEdge + 1e-9)
        }
    }

    @Test("an empty request yields no tiles")
    func emptyCount() {
        let tiles = DummyTileGenerator().generate(config: DummyTileGenerator.Config(count: 0))
        #expect(tiles.isEmpty)
    }
}

@Suite("DummyTileProvider")
struct DummyTileProviderTests {
    @Test("provider tiles match the generator for the same seed + config")
    func matchesGenerator() {
        let config = DummyTileGenerator.Config(count: 200)
        let provider = DummyTileProvider(seed: 99, config: config)
        let expected = DummyTileGenerator().generate(seed: 99, config: config)
        #expect(provider.tiles == expected)
    }
}

@Suite("FixtureImageSet")
struct FixtureImageSetTests {
    @Test("generates the requested number of source images")
    func count() {
        #expect(FixtureImageSet(count: 8).count == 8)
    }

    @Test("encoded bytes are deterministic for a fixed seed (T12)")
    func deterministic() {
        let a = FixtureImageSet(count: 6, seed: 5)
        let b = FixtureImageSet(count: 6, seed: 5)
        #expect(a.encoded == b.encoded)
    }

    @Test("every image is non-empty and decodes to a positive-size bitmap")
    func decodable() {
        let set = FixtureImageSet(count: 6, seed: 5)
        for data in set.encoded {
            #expect(!data.isEmpty)
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            #expect(image != nil)
            #expect((image?.width ?? 0) > 0 && (image?.height ?? 0) > 0)
        }
    }

    @Test("tile-id lookup wraps by modulo, including negative ids")
    func tileIDWrap() {
        let set = FixtureImageSet(count: 4, seed: 5)
        #expect(set.data(forTileID: 0) == set.data(forTileID: 4))
        #expect(set.data(forTileID: 1) == set.data(forTileID: 5))
        #expect(set.data(forTileID: -1) == set.data(forTileID: 3)) // -1 mod 4 -> 3
    }
}
