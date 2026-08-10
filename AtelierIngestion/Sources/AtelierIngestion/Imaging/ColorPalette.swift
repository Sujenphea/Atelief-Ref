//
//  ColorPalette.swift
//  AtelierIngestion
//
//  085 · C0 — the fixed palette a dominant-color swatch is filed under, and the
//  rule that files it.
//
//  This is the ONE definition of "what colors the library can be filtered by".
//  The analyzer assigns a bucket at index time and `asset_color.bucket` stores
//  its raw value; AtelierCore filters on that integer and never learns what a
//  color is (085 — Ingestion owns the shape, Core stores it opaquely, the same
//  discipline `asset_analysis.colors` and `SearchRules.rules` already follow).
//  The chip UI reads the same cases, so the thing a user clicks and the thing
//  the analyzer decided cannot drift apart.
//
//  Assignment is deliberately NOT "nearest palette entry in Lab". Anchors sit at
//  different lightnesses, so a plain nearest-anchor search lets lightness decide
//  hue — a dark navy can land nearer the brown anchor than the blue one. The rule
//  below separates the two questions instead: chroma decides neutral-vs-colored,
//  hue ANGLE decides which color, and lightness only distinguishes the one pair
//  that genuinely differs by lightness alone (orange vs brown).
//

import Foundation

/// A color a swatch can be filed under — the filter's vocabulary.
///
/// **Raw values are PERSISTED** in `asset_color.bucket`. They are allocation
/// order, never a sort key: renumbering a case silently re-labels every stored
/// row (every "red" in the library becomes whatever now holds 3). Add new cases
/// with the next free value; never reuse a retired one.
public enum ColorBucket: Int, CaseIterable, Sendable, Hashable {
    // Neutrals — reached by the chroma gate, never by hue.
    case black = 0
    case gray = 1
    case white = 2
    // Hues.
    case red = 3
    case orange = 4
    /// Dark orange/yellow. Reached by the lightness rule, never by angle — see
    /// ``ColorPalette/hueAnchors``.
    case brown = 5
    case yellow = 6
    case green = 7
    case teal = 8
    case blue = 9
    case purple = 10
    case pink = 11

    /// The swatch drawn on this bucket's filter chip, and — for the eight cases
    /// in ``ColorPalette/hueAnchors`` — the anchor its hue angle is measured
    /// from. One value for both so the chip shows what the bucket actually means.
    public var referenceHex: String {
        switch self {
        case .black: return "#000000"
        case .gray: return "#808080"
        case .white: return "#ffffff"
        case .red: return "#e02020"
        case .orange: return "#f07800"
        case .brown: return "#8b5a2b"
        case .yellow: return "#f0d000"
        case .green: return "#3ba03b"
        case .teal: return "#00a0a0"
        // These two are chosen as a PAIR, because what decides a color is the
        // midpoint between them. The obvious anchors — `#2050d0` (295.0°) and
        // `#8030c0` (314.0°) — put that midpoint at 304.5°, and pure blue sits
        // at 306.3°, so the bluest color there is filed under purple. At 300.2°
        // and 321.3° the midpoint is 310.8° and it lands correctly.
        //
        // Moving EITHER one alone would also have fixed it; both moved because
        // the naive purple was crowding blue and the naive blue was leaning
        // cyan-ward. Measured, not guessed — and pinned by `pureColors`, which
        // fails if this pair drifts back together.
        case .blue: return "#2040e0"
        case .purple: return "#a020c0"
        case .pink: return "#e050a0"
        }
    }

    /// The chip's label. A color name rather than app copy — "Red" does not
    /// differ by surface — so it lives with the palette it names.
    public var displayName: String {
        switch self {
        case .black: return "Black"
        case .gray: return "Gray"
        case .white: return "White"
        case .red: return "Red"
        case .orange: return "Orange"
        case .brown: return "Brown"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// Whether this bucket is reached by the chroma gate rather than by hue.
    public var isNeutral: Bool {
        switch self {
        case .black, .gray, .white: return true
        default: return false
        }
    }
}

/// Files a color into a ``ColorBucket``. A stateless namespace of pure functions,
/// matching the imaging layer's other utilities.
public enum ColorPalette {
    // MARK: - Thresholds

    /// Lab chroma below which a color is a NEUTRAL regardless of its hue angle.
    ///
    /// **This gate is the load-bearing part of the whole palette.** Real
    /// photographic pixels are mostly near-neutral, and a near-neutral color
    /// still has *some* hue angle — an off-white wall at `#f5f2ec` computes a
    /// perfectly confident "orange". Without the gate every photograph in the
    /// library matches the orange chip and the filter is worthless.
    ///
    /// 18 sends walls, concrete, paper and beige to the neutrals while leaving
    /// sky (C≈26), tan (C≈25) and navy (C≈31) colored. **This is the palette's
    /// one real judgement call**, and it is a single number: pale warm neutrals
    /// are the most common thing in a reference library, and at 12 they all
    /// landed in yellow, which turned yellow into the junk bucket.
    public static let neutralChromaThreshold = 18.0

    /// Lab L at or below which a neutral is black rather than gray.
    public static let blackMaxLightness = 25.0
    /// Lab L at or above which a neutral is white rather than gray.
    public static let whiteMinLightness = 82.0

    /// Lab L below which a red/orange/yellow-family color may be BROWN.
    ///
    /// Brown has no hue of its own — it is a dark, MUTED orange, and hue angle
    /// alone cannot see the difference. This is the one place lightness is
    /// allowed to pick a bucket, and it applies only to the three families brown
    /// actually borders.
    public static let brownMaxLightness = 55.0

    /// Lab chroma at or above which a dark warm color stays its own hue instead
    /// of becoming brown.
    ///
    /// Lightness alone is not enough: pure red is L=53.2, under
    /// ``brownMaxLightness``, and filing the reddest color there is under brown
    /// is indefensible. Brown is dark AND muted; 70 keeps rust (C≈69) and olive
    /// (C≈58) brown while leaving pure red (C≈105) red.
    public static let brownMaxChroma = 70.0

    /// The families brown can be demoted from. Green and blue have no dark
    /// counterpart with its own everyday name — a dark green is still green.
    private static let brownableFamilies: Set<ColorBucket> = [.red, .orange, .yellow]

    /// The buckets a hue angle is matched against. **Brown is deliberately
    /// absent**: it is decided by ``brownMaxLightness`` after a family is chosen,
    /// so including it here would let it compete on angle with the orange it is
    /// a darker version of.
    public static let hueAnchors: [ColorBucket] =
        [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]

    // MARK: - Assignment

    /// File a stored `#rrggbb` swatch hex into a bucket, or `nil` if the string
    /// is not a color.
    ///
    /// Accepts the lowercase `#rrggbb` ``ColorSwatch/encodeList(_:)`` writes, and
    /// tolerates uppercase and a missing `#` — a parse this liberal costs
    /// nothing and a stricter one would silently drop rows if the writer's
    /// formatting ever changed.
    public static func bucket(forHex hex: String) -> ColorBucket? {
        guard let rgb = rgb(fromHex: hex) else { return nil }
        return bucket(for: rgb)
    }

    /// File an sRGB color into a bucket. The rule, in order:
    ///
    /// 1. **Chroma gate** — low chroma is a neutral, split by lightness.
    /// 2. **Hue angle** — nearest anchor by angle, which is lightness-independent
    ///    so a dark and a pale blue file together.
    /// 3. **Brown** — a red/orange/yellow family color that is both dark
    ///    (``brownMaxLightness``) and muted (``brownMaxChroma``).
    public static func bucket(for color: ColorExtractor.RGB) -> ColorBucket {
        let lab = ColorExtractor.srgbToLab(color)
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()

        if chroma < neutralChromaThreshold {
            if lab.L <= blackMaxLightness { return .black }
            if lab.L >= whiteMinLightness { return .white }
            return .gray
        }

        let family = nearestHue(toAngle: hueAngle(a: lab.a, b: lab.b))
        if brownableFamilies.contains(family),
           lab.L < brownMaxLightness, chroma < brownMaxChroma {
            return .brown
        }
        return family
    }

    // MARK: - Swatch lists

    /// One bucket an asset contains, and how much of the image it covers.
    public struct BucketCoverage: Sendable, Equatable {
        public let bucket: ColorBucket
        /// Summed coverage of every swatch that filed under `bucket`, `0...1`.
        public let coverage: Double

        public init(bucket: ColorBucket, coverage: Double) {
            self.bucket = bucket
            self.coverage = coverage
        }
    }

    /// File a whole extraction into buckets, **merging swatches that land in the
    /// same one** and sorting by descending coverage.
    ///
    /// Merging is the point. `ColorExtractor` returns up to five clusters, and a
    /// photograph of a red door easily yields two reds at 12% and 8%. Kept apart,
    /// neither clears a 15% filter floor and the reddest image in the library
    /// fails a search for red; merged, it matches at 20% — which is the truth
    /// about the picture. The floor is applied downstream against these totals.
    ///
    /// Swatches whose hex does not parse are skipped rather than failing the
    /// list: one bad row should cost that row, not the asset's whole palette.
    public static func bucketCoverages(for swatches: [ColorSwatch]) -> [BucketCoverage] {
        var totals: [ColorBucket: Double] = [:]
        for swatch in swatches {
            guard let bucket = bucket(forHex: swatch.hex) else { continue }
            totals[bucket, default: 0] += swatch.coverage
        }
        return totals
            .map { BucketCoverage(bucket: $0.key, coverage: $0.value) }
            // Coverage first; the bucket's raw value breaks ties so the order is
            // total rather than "whatever the dictionary iterated" — these rows
            // get a persisted rank and must not shuffle between runs.
            .sorted {
                $0.coverage != $1.coverage
                    ? $0.coverage > $1.coverage
                    : $0.bucket.rawValue < $1.bucket.rawValue
            }
    }

    // MARK: - Hue math

    /// The anchor whose hue angle is closest to `angle`, measured the short way
    /// around the wheel so the red/pink wrap at 0° is not a discontinuity.
    ///
    /// Ties break toward the earlier ``hueAnchors`` entry, which only matters for
    /// a color landing exactly on a sector boundary — but "exactly halfway"
    /// must still be deterministic, not whichever the iteration reached first.
    private static func nearestHue(toAngle angle: Double) -> ColorBucket {
        var best = hueAnchors[0]
        var bestDelta = Double.infinity
        for anchor in hueAnchors {
            guard let rgb = rgb(fromHex: anchor.referenceHex) else { continue }
            let lab = ColorExtractor.srgbToLab(rgb)
            let delta = angularDistance(angle, hueAngle(a: lab.a, b: lab.b))
            if delta < bestDelta {
                bestDelta = delta
                best = anchor
            }
        }
        return best
    }

    /// Hue angle in degrees, `0..<360`.
    private static func hueAngle(a: Double, b: Double) -> Double {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The short way around the wheel between two angles, `0...180`.
    private static func angularDistance(_ x: Double, _ y: Double) -> Double {
        let d = abs(x - y).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    // MARK: - Hex parsing

    /// Parse `#rrggbb` / `rrggbb`, any case, to an sRGB triple. `nil` for
    /// anything else — wrong length, non-hex digits, empty.
    static func rgb(fromHex hex: String) -> ColorExtractor.RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return ColorExtractor.RGB(
            r: UInt8((value >> 16) & 0xff),
            g: UInt8((value >> 8) & 0xff),
            b: UInt8(value & 0xff))
    }
}
