import CoreGraphics
import Foundation
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

    @Test("the same seed yields pixel-identical images (T12)")
    func deterministic() {
        // The seed deterministically controls the *pixels*, but ImageIO's PNG
        // encoder is not byte-deterministic on this platform (its filter/zlib
        // choices jitter the encoded size run-to-run). So assert determinism at
        // the layer the seed actually governs: decode both encodings back and
        // compare the raw pixel buffers (PNG is lossless, so identical source
        // pixels must decode identically) plus their dimensions.
        let a = FixtureImageSet(count: 6, seed: 5)
        let b = FixtureImageSet(count: 6, seed: 5)
        #expect(a.count == b.count)
        for (dataA, dataB) in zip(a.encoded, b.encoded) {
            guard let pixA = decodedPixels(dataA), let pixB = decodedPixels(dataB) else {
                Issue.record("fixture image failed to decode")
                continue
            }
            #expect(pixA.width == pixB.width)
            #expect(pixA.height == pixB.height)
            #expect(pixA.bytes == pixB.bytes)
        }
    }

    @Test("a different seed yields different images")
    func seedChangesImages() {
        // Guards the determinism test above from being trivially true: a
        // different seed must actually change the decoded pixels.
        let a = FixtureImageSet(count: 6, seed: 5)
        let b = FixtureImageSet(count: 6, seed: 6)
        let pixelsA = a.encoded.compactMap { decodedPixels($0)?.bytes }
        let pixelsB = b.encoded.compactMap { decodedPixels($0)?.bytes }
        #expect(pixelsA.count == a.count && pixelsB.count == b.count)
        #expect(pixelsA != pixelsB)
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

/// Decodes encoded image `data` into a normalised RGBA pixel buffer so two
/// independently-encoded images can be compared at the pixel layer (robust to
/// non-byte-deterministic encoders). Returns `nil` if decoding fails.
private func decodedPixels(_ data: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let ctx = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return ok ? (width, height, bytes) : nil
}
