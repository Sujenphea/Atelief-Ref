// AtelierIngestion — color-extraction tests (feature 012, I1)
//
// Three layers: the sRGB→Lab conversion pinned against published Lab values;
// the pure k-means `swatches` behavior + determinism (the 012-required contract)
// plus randomized invariants; and the byte/CGImage adapters over lossless PNG
// fixtures (solid, two-tone, transparent, degenerate) asserting decoded behavior.

import CoreGraphics
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("ColorExtractor")
struct ColorExtractorTests {
    private typealias RGB = ColorExtractor.RGB

    // MARK: - sRGB → Lab (10A)

    /// Assert a Lab tuple matches published values within `tol`.
    private func expectLab(
        _ c: RGB, _ L: Double, _ a: Double, _ b: Double, tol: Double = 0.1,
        _ comment: Comment? = nil
    ) {
        let lab = ColorExtractor.srgbToLab(c)
        #expect(abs(lab.L - L) < tol, comment ?? "L")
        #expect(abs(lab.a - a) < tol, comment ?? "a")
        #expect(abs(lab.b - b) < tol, comment ?? "b")
    }

    @Test("srgbToLab matches published Lab for black, white, and the primaries")
    func labAnchors() {
        expectLab(RGB(r: 0, g: 0, b: 0), 0, 0, 0, "black")
        expectLab(RGB(r: 255, g: 255, b: 255), 100, 0, 0, tol: 0.02, "white")
        expectLab(RGB(r: 255, g: 0, b: 0), 53.2408, 80.0925, 67.2032, "red")
        expectLab(RGB(r: 0, g: 255, b: 0), 87.7347, -86.1827, 83.1793, "green")
        expectLab(RGB(r: 0, g: 0, b: 255), 32.2970, 79.1875, -107.8602, "blue")
    }

    @Test("L increases monotonically with brightness for grays")
    func labMonotoneLightness() {
        let grays = [0, 32, 64, 128, 192, 255].map { RGB(r: UInt8($0), g: UInt8($0), b: UInt8($0)) }
        let lightness = grays.map { ColorExtractor.srgbToLab($0).L }
        for i in 1 ..< lightness.count {
            #expect(lightness[i] > lightness[i - 1])
        }
        // Neutral grays carry ~no chroma.
        for gray in grays {
            let lab = ColorExtractor.srgbToLab(gray)
            #expect(abs(lab.a) < 0.01)
            #expect(abs(lab.b) < 0.01)
        }
    }

    // MARK: - Pure swatches: behavior (11A)

    private func pixels(_ color: (UInt8, UInt8, UInt8), _ count: Int) -> [RGB] {
        [RGB](repeating: RGB(r: color.0, g: color.1, b: color.2), count: count)
    }

    @Test("empty pixels or maxColors<1 yields no swatches")
    func degenerateInputs() {
        #expect(ColorExtractor.swatches(fromPixels: [], maxColors: 5).isEmpty)
        #expect(ColorExtractor.swatches(fromPixels: pixels((255, 0, 0), 10), maxColors: 0).isEmpty)
    }

    @Test("a solid color yields exactly one swatch at full coverage")
    func solidColor() {
        let result = ColorExtractor.swatches(fromPixels: pixels((10, 20, 30), 500), maxColors: 5)
        #expect(result.count == 1)
        #expect(result[0].hex == "#0a141e")
        #expect(abs(result[0].coverage - 1.0) < 1e-9)
    }

    @Test("a 50/50 two-tone yields two swatches at ~half coverage each")
    func twoToneEvenSplit() {
        let px = pixels((255, 0, 0), 200) + pixels((0, 0, 255), 200)
        let result = ColorExtractor.swatches(fromPixels: px, maxColors: 5)
        #expect(result.count == 2)
        #expect(Set(result.map(\.hex)) == ["#ff0000", "#0000ff"])
        for swatch in result { #expect(abs(swatch.coverage - 0.5) < 1e-9) }
    }

    @Test("the most-dominant color sorts first (70/30 split)")
    func dominantSortsFirst() {
        let px = pixels((255, 0, 0), 70) + pixels((0, 0, 255), 30)
        let result = ColorExtractor.swatches(fromPixels: px, maxColors: 5)
        #expect(result.first?.hex == "#ff0000")
        #expect(abs((result.first?.coverage ?? 0) - 0.7) < 1e-9)
    }

    @Test("fewer distinct colors than maxColors → one swatch each, coverage sums to 1")
    func fewerColorsThanClusters() {
        let px = pixels((200, 0, 0), 30) + pixels((0, 200, 0), 20) + pixels((0, 0, 200), 10)
        let result = ColorExtractor.swatches(fromPixels: px, maxColors: 5)
        #expect(result.count == 3)
        #expect(abs(result.reduce(0) { $0 + $1.coverage } - 1.0) < 1e-9)
    }

    @Test("more colors than maxColors → exactly maxColors swatches, coverage sums to ~1")
    func moreColorsThanClusters() {
        // Three tight color pairs → k=3 should recover exactly three clusters.
        let px =
            pixels((250, 0, 0), 40) + pixels((255, 10, 10), 40)
            + pixels((0, 250, 0), 30) + pixels((10, 255, 10), 30)
            + pixels((0, 0, 250), 20) + pixels((10, 10, 255), 20)
        let result = ColorExtractor.swatches(fromPixels: px, maxColors: 3)
        #expect(result.count == 3)
        #expect(abs(result.reduce(0) { $0 + $1.coverage } - 1.0) < 1e-9)
    }

    // MARK: - Determinism + fuzz (11A + 11C)

    /// Deterministic LCG so "random" fixtures are reproducible without Date/random.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func int(_ bound: Int) -> Int { Int((next() >> 33) % UInt64(bound)) }
        mutating func byte() -> UInt8 { UInt8((next() >> 40) & 0xFF) }
    }

    private func shuffled(_ input: [RGB], seed: UInt64) -> [RGB] {
        var rng = LCG(state: seed)
        var a = input
        var i = a.count - 1
        while i > 0 {
            a.swapAt(i, rng.int(i + 1))
            i -= 1
        }
        return a
    }

    @Test("swatches are order-independent — a shuffle yields identical output")
    func determinismUnderShuffle() {
        let px = pixels((255, 0, 0), 70) + pixels((0, 0, 255), 20) + pixels((0, 255, 0), 10)
        let base = ColorExtractor.swatches(fromPixels: px, maxColors: 3)
        for seed: UInt64 in [1, 2, 0xABCD, 0xF00D_1234] {
            #expect(ColorExtractor.swatches(fromPixels: shuffled(px, seed: seed), maxColors: 3) == base)
        }
    }

    @Test("randomized palettes satisfy the invariants (count ≤ max, coverage ≤ 1, deterministic)")
    func randomizedInvariants() {
        var rng = LCG(state: 0x0C0F_FEE0_1234_5678)
        for _ in 0 ..< 40 {
            let distinct = 1 + rng.int(12)
            var palette: [RGB] = []
            for _ in 0 ..< distinct {
                palette.append(RGB(r: rng.byte(), g: rng.byte(), b: rng.byte()))
            }
            var px: [RGB] = []
            for color in palette { px += [RGB](repeating: color, count: 1 + rng.int(50)) }
            let maxColors = 1 + rng.int(6)

            let result = ColorExtractor.swatches(fromPixels: px, maxColors: maxColors)
            #expect(result.count <= maxColors)
            #expect(!result.isEmpty)
            let sum = result.reduce(0) { $0 + $1.coverage }
            #expect(sum <= 1.0 + 1e-9)
            #expect(sum > 0)
            // Deterministic across a shuffle.
            #expect(ColorExtractor.swatches(fromPixels: shuffled(px, seed: 42), maxColors: maxColors) == result)
        }
    }

    // MARK: - Adapters (12A)

    private func parseHex(_ hex: String) -> (r: Int, g: Int, b: Int) {
        var v = hex
        v.removeFirst()  // drop '#'
        let n = Int(v, radix: 16) ?? 0
        return ((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
    }

    private func expectHexNear(_ hex: String, _ target: (Int, Int, Int), tol: Int = 3) {
        let (r, g, b) = parseHex(hex)
        #expect(abs(r - target.0) <= tol)
        #expect(abs(g - target.1) <= tol)
        #expect(abs(b - target.2) <= tol)
    }

    @Test("a solid PNG extracts one dominant swatch near its color")
    func extractSolid() throws {
        let data = try FixtureImages.solidColorImage(width: 64, height: 64, red: 40, green: 120, blue: 200)
        let result = try ColorExtractor.extract(from: data, maxColors: 5)
        #expect(result.count == 1)
        expectHexNear(result[0].hex, (40, 120, 200))
        #expect(abs(result[0].coverage - 1.0) < 1e-9)
    }

    @Test("a solid CGImage extracts through the CGImage seam")
    func extractCGImageSeam() throws {
        let image = try FixtureImages.makeFilledCGImage(width: 48, height: 48) { context in
            context.setFillColor(red: 200 / 255, green: 40 / 255, blue: 120 / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let result = try ColorExtractor.swatches(fromCGImage: image, maxColors: 5)
        #expect(result.count == 1)
        expectHexNear(result[0].hex, (200, 40, 120))
    }

    @Test("a 50/50 two-tone PNG extracts the two colors at ~half coverage")
    func extractTwoTone() throws {
        let data = try FixtureImages.twoToneImage(
            width: 64, height: 64, left: (255, 0, 0), right: (0, 0, 255))
        // maxColors: 2 forces two clusters, robust against boundary-blend pixels.
        let result = try ColorExtractor.extract(from: data, maxColors: 2)
        #expect(result.count == 2)
        for swatch in result { #expect(abs(swatch.coverage - 0.5) < 0.15) }
        let hexes = result.map(\.hex)
        #expect(hexes.contains { parseHex($0).r > 200 && parseHex($0).b < 55 })  // red-ish
        #expect(hexes.contains { parseHex($0).b > 200 && parseHex($0).r < 55 })  // blue-ish
    }

    @Test("a fully-transparent PNG extracts no swatches")
    func extractTransparent() throws {
        let data = try FixtureImages.transparentImage(width: 40, height: 40)
        #expect(try ColorExtractor.extract(from: data).isEmpty)
    }

    @Test("zero bytes throw unreadable")
    func zeroBytesThrows() {
        #expect(throws: ImageError.unreadable) {
            try ColorExtractor.extract(from: FixtureImages.zeroBytes)
        }
    }

    @Test("non-image bytes throw an ImageError")
    func nonImageThrows() {
        #expect {
            try ColorExtractor.extract(from: FixtureImages.nonImageBytes())
        } throws: { error in
            error is ImageError
        }
    }
}
