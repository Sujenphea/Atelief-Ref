// AtelierIngestion — palette bucket assignment tests (085 · C0)
//
// Four layers, failing for different reasons:
//   1. The PIN — raw values are persisted in `asset_color.bucket`, so a renumber
//      must fail here rather than silently re-label every stored row.
//   2. The anchors — every bucket's own reference color files under itself, which
//      is what catches an anchor moved into a neighbour's sector.
//   3. The rules — the chroma gate, the brown pair and hue's independence from
//      lightness, each asserted with the case that breaks it if the rule is gone.
//   4. Parsing — everything that is not a color.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("ColorPalette")
struct ColorPaletteTests {

    // MARK: - The pin

    /// `asset_color.bucket` stores these integers. Renumbering a case re-labels
    /// every row already written — every "red" in the library becomes whatever
    /// now holds 3 — with no migration and no error. Pinned so that is a test
    /// failure instead.
    @Test("raw values are pinned — they are persisted, not incidental")
    func rawValuesArePinned() {
        #expect(ColorBucket.black.rawValue == 0)
        #expect(ColorBucket.gray.rawValue == 1)
        #expect(ColorBucket.white.rawValue == 2)
        #expect(ColorBucket.red.rawValue == 3)
        #expect(ColorBucket.orange.rawValue == 4)
        #expect(ColorBucket.brown.rawValue == 5)
        #expect(ColorBucket.yellow.rawValue == 6)
        #expect(ColorBucket.green.rawValue == 7)
        #expect(ColorBucket.teal.rawValue == 8)
        #expect(ColorBucket.blue.rawValue == 9)
        #expect(ColorBucket.purple.rawValue == 10)
        #expect(ColorBucket.pink.rawValue == 11)
        #expect(ColorBucket.allCases.count == 12, "a new case needs a pin above")
    }

    @Test("raw values and reference hexes are unique")
    func casesAreDistinct() {
        let raws = Set(ColorBucket.allCases.map(\.rawValue))
        #expect(raws.count == ColorBucket.allCases.count)
        let hexes = Set(ColorBucket.allCases.map(\.referenceHex))
        #expect(hexes.count == ColorBucket.allCases.count)
        let names = Set(ColorBucket.allCases.map(\.displayName))
        #expect(names.count == ColorBucket.allCases.count)
    }

    // MARK: - Anchors

    /// Each bucket's chip color must file under that bucket. This is the guard
    /// that fails when an anchor drifts into a neighbour's sector — the exact bug
    /// the measured `#2040e0` / `#a020c0` choice fixed, where the chip labelled
    /// "blue" would have searched for purple.
    @Test("every bucket's reference color files under itself", arguments: ColorBucket.allCases)
    func referenceColorRoundTrips(_ bucket: ColorBucket) {
        #expect(ColorPalette.bucket(forHex: bucket.referenceHex) == bucket)
    }

    /// Brown is decided by the lightness/chroma rule after a family is chosen, so
    /// it must not compete on angle with the orange it is a darker version of.
    @Test("hue anchors exclude brown and every neutral")
    func hueAnchorsAreChromaticOnly() {
        #expect(!ColorPalette.hueAnchors.contains(.brown))
        for bucket in ColorBucket.allCases where bucket.isNeutral {
            #expect(!ColorPalette.hueAnchors.contains(bucket))
        }
        #expect(ColorPalette.hueAnchors.count == 8)
    }

    // MARK: - Pure colors

    @Test("the sRGB primaries and secondaries file under their own name")
    func pureColors() {
        #expect(ColorPalette.bucket(forHex: "#ff0000") == .red)
        #expect(ColorPalette.bucket(forHex: "#00ff00") == .green)
        #expect(ColorPalette.bucket(forHex: "#0000ff") == .blue)
        #expect(ColorPalette.bucket(forHex: "#ffff00") == .yellow)
        #expect(ColorPalette.bucket(forHex: "#00ffff") == .teal)
    }

    /// The blue/purple boundary is the tightest on the wheel and the one that was
    /// actually wrong: with the naive anchor pair the midpoint fell at 304.5° and
    /// pure blue (306.3°) filed as purple. Asserted from both sides so a drift in
    /// either anchor fails, not just the two of them moving together.
    @Test("the blue/purple boundary holds from both sides")
    func blueAndPurpleAreSeparated() {
        #expect(ColorPalette.bucket(forHex: "#0000ff") == .blue, "pure blue, 306.3°")
        #expect(ColorPalette.bucket(forHex: "#3020e0") == .blue, "a blue leaning violet")
        #expect(ColorPalette.bucket(forHex: "#7f00ff") == .purple, "violet")
        #expect(ColorPalette.bucket(forHex: "#8a2be2") == .purple, "blue-violet")
    }

    /// Pure red is L=53.2 — under ``ColorPalette/brownMaxLightness``. Only the
    /// chroma ceiling keeps it red, so this case fails the moment that ceiling
    /// is dropped and lightness decides alone.
    @Test("pure red is red, not brown, despite being dark enough to qualify")
    func pureRedIsNotBrown() {
        #expect(ColorPalette.bucket(forHex: "#ff0000") == .red)
    }

    // MARK: - The chroma gate

    /// The gate is the load-bearing rule: near-neutrals still have a confident
    /// hue angle, and without it every wall, floor and sheet of paper in the
    /// library files under some hue and that hue becomes a junk bucket.
    @Test("near-neutrals are neutral, not the hue their tint leans toward")
    func chromaGateSendsNearNeutralsToNeutrals() {
        #expect(ColorPalette.bucket(forHex: "#f5f2ec") == .white, "off-white wall")
        #expect(ColorPalette.bucket(forHex: "#b8b5b0") == .gray, "concrete")
        #expect(ColorPalette.bucket(forHex: "#2a2a2c") == .black, "charcoal")
        #expect(ColorPalette.bucket(forHex: "#e8dcc0") == .white, "beige")
    }

    @Test("neutrals split by lightness")
    func neutralsSplitByLightness() {
        #expect(ColorPalette.bucket(forHex: "#000000") == .black)
        #expect(ColorPalette.bucket(forHex: "#808080") == .gray)
        #expect(ColorPalette.bucket(forHex: "#ffffff") == .white)
    }

    /// A color ABOVE the gate must keep its hue — the gate must not be so greedy
    /// that it swallows genuinely colored things.
    @Test("colors just above the gate stay colored")
    func gateDoesNotSwallowRealColors() {
        #expect(ColorPalette.bucket(forHex: "#87ceeb") == .teal, "sky, C≈26")
        #expect(ColorPalette.bucket(forHex: "#101f4a") == .blue, "navy, C≈31")
        #expect(ColorPalette.bucket(forHex: "#008080") == .teal, "teal, C≈30")
    }

    // MARK: - Brown

    @Test("brown needs BOTH darkness and muteness")
    func brownRequiresDarkAndMuted() {
        // Dark and muted → brown.
        #expect(ColorPalette.bucket(forHex: "#5c3a21") == .brown, "chocolate")
        #expect(ColorPalette.bucket(forHex: "#b7410e") == .brown, "rust")
        // Dark but vivid → keeps its hue.
        #expect(ColorPalette.bucket(forHex: "#ff0000") == .red)
        // Muted but light → keeps its hue.
        #expect(ColorPalette.bucket(forHex: "#c96f4a") == .orange, "terracotta, L≈56")
    }

    /// Green and blue have no dark counterpart with its own everyday name, so the
    /// demotion must not reach them — a forest green is still green.
    @Test("only warm families can become brown")
    func brownIsWarmOnly() {
        #expect(ColorPalette.bucket(forHex: "#0b3d20") == .green, "forest")
        #expect(ColorPalette.bucket(forHex: "#101f4a") == .blue, "navy")
        #expect(ColorPalette.bucket(forHex: "#3b5b92") == .blue, "denim")
    }

    // MARK: - Hue is independent of lightness

    /// Matching on hue ANGLE rather than nearest-anchor-in-Lab is what lets a
    /// dark and a pale version of one color file together. Nearest-in-Lab would
    /// let lightness pull one of these to a different bucket entirely.
    @Test("a dark and a pale version of one hue file together")
    func hueSurvivesLightness() {
        #expect(ColorPalette.bucket(forHex: "#101f4a") == .blue, "navy")
        #expect(ColorPalette.bucket(forHex: "#6f8fe0") == .blue, "pale blue")
        #expect(ColorPalette.bucket(forHex: "#0b3d20") == .green, "forest")
        #expect(ColorPalette.bucket(forHex: "#7fd89a") == .green, "mint")
    }

    // MARK: - Parsing

    @Test("accepts the stored form, uppercase, and a missing hash")
    func parsingIsLiberal() {
        #expect(ColorPalette.bucket(forHex: "#ff0000") == .red)
        #expect(ColorPalette.bucket(forHex: "#FF0000") == .red)
        #expect(ColorPalette.bucket(forHex: "ff0000") == .red)
        #expect(ColorPalette.bucket(forHex: " #ff0000 ") == .red)
    }

    @Test("anything that is not a six-digit hex color is nil", arguments: [
        "", "#", "fff", "#fff", "12345", "#12345", "1234567", "#1234567",
        "#gggggg", "gggggg", "#ff00 0", "not a color", "#ff000g",
    ])
    func malformedInputIsNil(_ input: String) {
        #expect(ColorPalette.bucket(forHex: input) == nil)
    }

    // MARK: - Swatch lists

    /// The merge is the reason this function exists. Two reds at 12% and 8% must
    /// become one red at 20%, or the reddest image in the library fails a search
    /// for red at any floor above 12%.
    @Test("swatches landing in one bucket merge their coverage")
    func sameBucketSwatchesMerge() {
        let merged = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "#ff0000", coverage: 0.12),
            ColorSwatch(hex: "#e02020", coverage: 0.08),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.bucket == .red)
        #expect(abs((merged.first?.coverage ?? 0) - 0.20) < 1e-9)
    }

    @Test("distinct buckets are kept apart and ordered by coverage")
    func distinctBucketsAreOrdered() {
        let result = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "#0000ff", coverage: 0.20),
            ColorSwatch(hex: "#00ff00", coverage: 0.50),
            ColorSwatch(hex: "#ffff00", coverage: 0.30),
        ])
        #expect(result.map(\.bucket) == [.green, .yellow, .blue])
    }

    /// This is the order the detail chips are drawn in, so equal coverages must
    /// not order by whatever the dictionary happened to iterate.
    @Test("ties break deterministically by bucket, not by dictionary order")
    func tiesAreDeterministic() {
        let swatches = [
            ColorSwatch(hex: "#0000ff", coverage: 0.25),
            ColorSwatch(hex: "#ff0000", coverage: 0.25),
            ColorSwatch(hex: "#00ff00", coverage: 0.25),
        ]
        let first = ColorPalette.bucketCoverages(for: swatches).map(\.bucket)
        for _ in 0..<20 {
            #expect(ColorPalette.bucketCoverages(for: swatches).map(\.bucket) == first)
        }
        // red(3) < green(7) < blue(9) — ascending raw value on equal coverage.
        #expect(first == [.red, .green, .blue])
    }

    @Test("an unparseable swatch costs its own row, not the whole list")
    func badSwatchIsSkipped() {
        let result = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "not a color", coverage: 0.40),
            ColorSwatch(hex: "#00ff00", coverage: 0.60),
        ])
        #expect(result.map(\.bucket) == [.green])
    }

    @Test("an empty extraction yields no buckets")
    func emptyIsEmpty() {
        #expect(ColorPalette.bucketCoverages(for: []).isEmpty)
    }

    // MARK: - The representative hex

    /// The detail chip paints with the image's own color, so the merge has to name
    /// WHICH of the merged swatches it shows — the dominant one, not the last one
    /// the loop happened to see.
    @Test("the representative hex is the bucket's most dominant swatch")
    func representativeIsTheDominantSwatch() {
        let merged = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "#e02020", coverage: 0.08),
            ColorSwatch(hex: "#ff0000", coverage: 0.12),
            // Dark but SATURATED, so it stays red rather than falling to brown.
            ColorSwatch(hex: "#d01010", coverage: 0.05),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.representativeHex == "#ff0000")
    }

    /// Input order must not decide it — the same swatches reversed name the same
    /// color, or the chip changes hue when the extractor's ordering shifts.
    @Test("input order does not change the representative hex")
    func representativeIgnoresInputOrder() {
        let swatches = [
            ColorSwatch(hex: "#ff0000", coverage: 0.12),
            ColorSwatch(hex: "#e02020", coverage: 0.08),
        ]
        let forward = ColorPalette.bucketCoverages(for: swatches)
        let reversed = ColorPalette.bucketCoverages(for: swatches.reversed())
        #expect(forward == reversed)
        #expect(forward.first?.representativeHex == "#ff0000")
    }

    /// Two swatches tied at the top resolve by input order, which `ColorExtractor`
    /// defines as most-dominant-first. Deterministic beats arbitrary.
    @Test("a tie takes the earlier swatch")
    func representativeTieTakesTheFirst() {
        let merged = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "#ff0000", coverage: 0.10),
            ColorSwatch(hex: "#e02020", coverage: 0.10),
        ])
        #expect(merged.first?.representativeHex == "#ff0000")
    }

    /// The hex reaches the chip UNCHANGED. It is the image's color, not the
    /// palette's — a chip painted `ColorBucket.referenceHex` would make every red
    /// picture in the library show the identical red.
    @Test("the representative hex is the swatch's, not the palette anchor's")
    func representativeIsNotTheAnchor() {
        let merged = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "#b76e79", coverage: 0.4)  // rose gold → pink
        ])
        #expect(merged.first?.bucket == .pink)
        #expect(merged.first?.representativeHex == "#b76e79")
        #expect(merged.first?.representativeHex != ColorBucket.pink.referenceHex)
    }

    /// A skipped swatch must not become a bucket's representative either — the
    /// unparseable row costs itself, and the surviving green names the green chip.
    @Test("an unparseable swatch never names a bucket")
    func unparseableNeverRepresents() {
        let merged = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "not a color", coverage: 0.9),
            ColorSwatch(hex: "#00ff00", coverage: 0.1),
        ])
        #expect(merged.map(\.representativeHex) == ["#00ff00"])
    }

    /// Every returned hex must render. The chip has no fallback beyond the palette
    /// anchor, so a representative that cannot be parsed is a colorless chip.
    @Test("every representative hex parses back to a color")
    func representativesParse() {
        let merged = ColorPalette.bucketCoverages(for: [
            ColorSwatch(hex: "#FF0000", coverage: 0.3),  // uppercase, as tolerated
            ColorSwatch(hex: "00ff00", coverage: 0.3),  // no leading #
            ColorSwatch(hex: "#0000ff", coverage: 0.3),
        ])
        #expect(merged.count == 3)
        for share in merged {
            #expect(ColorPalette.bucket(forHex: share.representativeHex) == share.bucket)
        }
    }

    // MARK: - Purity

    @Test("assignment is deterministic")
    func assignmentIsDeterministic() {
        for bucket in ColorBucket.allCases {
            let first = ColorPalette.bucket(forHex: bucket.referenceHex)
            let second = ColorPalette.bucket(forHex: bucket.referenceHex)
            #expect(first == second)
        }
    }

    /// Every bucket must be reachable from some real color — a bucket nothing can
    /// ever land in is a chip that always returns nothing. The anchor round trip
    /// proves reachability; this pins that the set it covers is the whole enum.
    @Test("every bucket is reachable")
    func everyBucketIsReachable() {
        let reached = Set(ColorBucket.allCases.compactMap {
            ColorPalette.bucket(forHex: $0.referenceHex)
        })
        #expect(reached == Set(ColorBucket.allCases))
    }
}
