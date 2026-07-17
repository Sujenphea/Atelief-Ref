// AtelierIngestion — dominant-color extraction (feature 012, I1)
//
// The passive color index behind 012's swatch row and search-by-color filter:
// reduce an image to its top-N dominant colors as `[hex, coverage]`. Clustering
// happens in CIE **Lab** — a perceptually-uniform space where Euclidean distance
// tracks how different two colors *look* — so the swatches match human grouping
// (two near-identical blues merge; a small saturated accent survives) far better
// than clustering raw sRGB.
//
// Like the rest of the imaging layer this splits into a PURE core and thin decode
// adapters:
//   • ``ColorExtractor/swatches(fromPixels:maxColors:)`` — total, deterministic,
//     framework-free k-means over an in-memory pixel array. Determinism is a
//     design requirement (012 test strategy: "k-means determinism with seeded
//     init"): seeding is farthest-first over a canonically-ordered histogram, so
//     the same pixels always yield the same swatches regardless of input order.
//   • ``ColorExtractor/swatches(fromCGImage:maxColors:)`` / ``extract(from:…)`` —
//     the only ImageIO-touching parts. The `CGImage` entry lets the future
//     `AssetAnalyzer` decode an asset ONCE (via ``ImageDecoding``) and run both
//     this and ``PerceptualHash`` over the same image instead of decoding twice.
//
// The algorithm: quantize pixels into a weighted color histogram (collapses flat
// regions and sensor noise, and bounds the point count), cluster the buckets in
// Lab with weighted Lloyd iterations, then emit each non-empty cluster as the
// weighted-mean sRGB of its members (always in-gamut — no Lab→sRGB inverse) with
// coverage = cluster weight ÷ total. Sorted most-dominant first.
//
// PERSISTENCE NOTE (feature 012 `asset_analysis.colors TEXT`). The column stores
// the top-N swatches as `[hex, coverage]` JSON. Serializing `[ColorSwatch]` to
// that string (and parsing it back) is the analyzer's job at the AtelierCore seam;
// this package returns typed values and never touches GRDB or JSON encoding.

import CoreGraphics
import Foundation

/// One dominant color of an image: its `#rrggbb` hex and the fraction of sampled
/// pixels it represents (`0...1`).
public struct ColorSwatch: Sendable, Equatable {
    /// Lowercased `#rrggbb` — the weighted-mean sRGB of the cluster's members.
    public let hex: String
    /// Share of sampled pixels in this cluster, `0...1`. Swatches from one
    /// extraction sum to ≤ 1 (exactly 1 modulo rounding when no pixels were
    /// dropped for transparency).
    public let coverage: Double

    public init(hex: String, coverage: Double) {
        self.hex = hex
        self.coverage = coverage
    }
}

/// Dominant-color extraction via Lab-space k-means (feature 012). A stateless
/// namespace — all members `static` — matching the imaging layer's other pure
/// utilities.
public enum ColorExtractor {
    /// An 8-bit straight-alpha-free RGB pixel: the pure core's input unit. Public
    /// so callers (and tests) can build pixel arrays without an image.
    public struct RGB: Sendable, Equatable, Hashable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// Max thumbnail edge for ``extract(from:maxColors:)``. 64 px caps the sample
    /// at ~4k pixels — enough to characterize an image's palette, cheap to cluster.
    private static let sampleMaxPixelSize = 64
    /// Channel quantization: keep the top 5 bits (32 levels/channel). Collapses
    /// noise and flat gradients into shared buckets, bounding the point count and
    /// stabilizing clusters, while staying fine enough to separate real hues.
    private static let quantizeShift: UInt8 = 3
    /// Lloyd iteration cap — convergence is fast on ≤32³ buckets; the cap only
    /// guards a pathological oscillation.
    private static let maxIterations = 32
    /// Pixels with alpha below this are dropped so a cutout's transparent
    /// background can't dominate the palette. 16/255 ≈ 6% opacity.
    private static let alphaThreshold: UInt8 = 16

    // MARK: - Pure core

    /// The top `maxColors` dominant colors of `pixels`, most-dominant first.
    ///
    /// Pure and deterministic: no image decoding, no randomness. Pixels are
    /// quantized into a weighted histogram, clustered in Lab via weighted
    /// farthest-first-seeded Lloyd's algorithm, and each non-empty cluster is
    /// emitted as its members' weighted-mean sRGB (`#rrggbb`) with fractional
    /// coverage. Fewer than `maxColors` swatches come back when the image has
    /// fewer distinct colors than requested clusters.
    ///
    /// Returns `[]` for empty input or `maxColors < 1`.
    public static func swatches(fromPixels pixels: [RGB], maxColors: Int) -> [ColorSwatch] {
        guard maxColors >= 1, !pixels.isEmpty else { return [] }

        let buckets = histogram(pixels)

        // Fewer distinct colors than clusters ⇒ every bucket is its own swatch;
        // otherwise cluster. Both paths reduce to weighted (weight, color) groups,
        // finalized by the one ``finalize(_:total:)`` step.
        let groups: [(weight: Int, rgb: RGB)]
        if buckets.count <= maxColors {
            groups = buckets.map { (weight: $0.weight, rgb: $0.meanRGB) }
        } else {
            groups = kMeans(buckets: buckets, k: maxColors)
        }
        return finalize(groups, total: Double(pixels.count))
    }

    /// Build the swatches from weighted color groups: hex + fractional coverage,
    /// dropping empties, sorted most-dominant first. The single tail shared by the
    /// few-colors and clustered paths.
    private static func finalize(_ groups: [(weight: Int, rgb: RGB)], total: Double) -> [ColorSwatch] {
        groups
            .filter { $0.weight > 0 }
            .map { ColorSwatch(hex: hex($0.rgb), coverage: Double($0.weight) / total) }
            .sorted { $0.coverage > $1.coverage }
    }

    // MARK: - Histogram

    /// A quantized color bucket: how many source pixels fell in it and their exact
    /// mean sRGB / Lab coordinates (the mean, not the quantized key, so the swatch
    /// color stays faithful).
    private struct Bucket {
        var weight: Int
        var meanRGB: RGB
        var lab: (L: Double, a: Double, b: Double)
    }

    /// Collapse pixels into weighted buckets keyed by quantized color. Each
    /// bucket's representative is the exact mean of its members (accumulated as
    /// sums, divided once at the end) — quantization only groups, it never shifts
    /// the reported color.
    private static func histogram(_ pixels: [RGB]) -> [Bucket] {
        struct Accum {
            var count = 0, sr = 0, sg = 0, sb = 0
            mutating func add(_ p: RGB) {
                count += 1; sr += Int(p.r); sg += Int(p.g); sb += Int(p.b)
            }
        }
        var table: [UInt32: Accum] = [:]
        table.reserveCapacity(min(pixels.count, 4096))

        for p in pixels {
            let qr = p.r >> quantizeShift
            let qg = p.g >> quantizeShift
            let qb = p.b >> quantizeShift
            let key = (UInt32(qr) << 16) | (UInt32(qg) << 8) | UInt32(qb)
            // In-place mutation via `default:` — no per-pixel read-copy/write-copy
            // of the accumulator struct.
            table[key, default: Accum()].add(p)
        }

        return table.values.map { acc in
            let mean = RGB(
                r: UInt8((acc.sr + acc.count / 2) / acc.count),
                g: UInt8((acc.sg + acc.count / 2) / acc.count),
                b: UInt8((acc.sb + acc.count / 2) / acc.count))
            return Bucket(weight: acc.count, meanRGB: mean, lab: srgbToLab(mean))
        }
    }

    // MARK: - k-means (weighted, Lab, deterministic)

    /// Weighted per-cluster running sums — the single accumulator shared by the
    /// Lloyd recompute step and the final swatch build (Lab means feed the next
    /// assignment; RGB means become the swatch color).
    private struct ClusterStats {
        var weight = 0
        var sumL = 0.0, sumA = 0.0, sumB = 0.0
        var sumR = 0, sumG = 0, sumBl = 0

        mutating func add(_ bucket: Bucket) {
            let w = bucket.weight
            weight += w
            sumL += bucket.lab.L * Double(w)
            sumA += bucket.lab.a * Double(w)
            sumB += bucket.lab.b * Double(w)
            sumR += Int(bucket.meanRGB.r) * w
            sumG += Int(bucket.meanRGB.g) * w
            sumBl += Int(bucket.meanRGB.b) * w
        }

        /// Weighted-mean Lab (only valid when `weight > 0`).
        var labMean: (L: Double, a: Double, b: Double) {
            (sumL / Double(weight), sumA / Double(weight), sumB / Double(weight))
        }

        /// Weighted-mean sRGB, rounded (only valid when `weight > 0`).
        var rgbMean: RGB {
            RGB(r: UInt8((sumR + weight / 2) / weight),
                g: UInt8((sumG + weight / 2) / weight),
                b: UInt8((sumBl + weight / 2) / weight))
        }
    }

    /// Sum every bucket into its assigned cluster — the one place membership is
    /// reduced, called by both the per-iteration center recompute and the final
    /// group build.
    private static func accumulate(
        assignment: [Int], ordered: [Bucket], clusterCount: Int
    ) -> [ClusterStats] {
        var stats = [ClusterStats](repeating: ClusterStats(), count: clusterCount)
        for (i, bucket) in ordered.enumerated() {
            stats[assignment[i]].add(bucket)
        }
        return stats
    }

    /// Weighted Lloyd's algorithm over Lab bucket coordinates with deterministic
    /// farthest-first seeding, returning `(weight, color)` groups.
    ///
    /// Work is bounded: ``extract`` caps pixels at a ``sampleMaxPixelSize``-edge
    /// thumbnail (~4k pixels) and `quantizeShift` caps buckets at 32³, so the
    /// `O(iterations × buckets × k)` loop is small in practice.
    private static func kMeans(buckets: [Bucket], k: Int) -> [(weight: Int, rgb: RGB)] {
        // Canonical order so seeding is independent of input pixel order:
        // heaviest first, ties broken by Lab then RGB.
        let ordered = buckets.sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.lab.L != rhs.lab.L { return lhs.lab.L < rhs.lab.L }
            if lhs.lab.a != rhs.lab.a { return lhs.lab.a < rhs.lab.a }
            if lhs.lab.b != rhs.lab.b { return lhs.lab.b < rhs.lab.b }
            return packed(lhs.meanRGB) < packed(rhs.meanRGB)
        }

        // Farthest-first init: seed 0 = heaviest bucket; each next seed maximizes
        // its minimum Lab distance to the already-chosen seeds. Spread-out and
        // fully deterministic (no RNG) — the "seeded init" of the 012 test note.
        var centers: [(L: Double, a: Double, b: Double)] = [ordered[0].lab]
        var minDist = ordered.map { labDistanceSq($0.lab, ordered[0].lab) }
        while centers.count < k {
            var farIndex = 0
            var farDist = -1.0
            for i in ordered.indices where minDist[i] > farDist {
                farDist = minDist[i]
                farIndex = i
            }
            if farDist <= 0 { break }  // all remaining buckets coincide with a seed
            centers.append(ordered[farIndex].lab)
            for i in ordered.indices {
                minDist[i] = min(minDist[i], labDistanceSq(ordered[i].lab, ordered[farIndex].lab))
            }
        }

        var assignment = [Int](repeating: 0, count: ordered.count)
        for _ in 0 ..< maxIterations {
            var changed = false
            for (i, bucket) in ordered.enumerated() {
                var best = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = labDistanceSq(bucket.lab, center)
                    if d < bestDist { bestDist = d; best = c }
                }
                if assignment[i] != best { assignment[i] = best; changed = true }
            }

            if !changed { break }

            // Recompute centers as weighted Lab means for the next assignment.
            let stats = accumulate(assignment: assignment, ordered: ordered, clusterCount: centers.count)
            for c in centers.indices where stats[c].weight > 0 {
                centers[c] = stats[c].labMean
            }
        }

        // Final membership → (weight, mean color) groups for non-empty clusters.
        let stats = accumulate(assignment: assignment, ordered: ordered, clusterCount: centers.count)
        return stats
            .filter { $0.weight > 0 }
            .map { (weight: $0.weight, rgb: $0.rgbMean) }
    }

    // MARK: - Color math

    /// Squared Euclidean distance in Lab (squared to avoid a `sqrt` in the hot
    /// assignment loop — monotonic, so nearest-center choice is unaffected).
    private static func labDistanceSq(
        _ x: (L: Double, a: Double, b: Double), _ y: (L: Double, a: Double, b: Double)
    ) -> Double {
        let dL = x.L - y.L, da = x.a - y.a, db = x.b - y.b
        return dL * dL + da * da + db * db
    }

    /// Convert an 8-bit sRGB color to CIE Lab (D65 reference white) — the standard
    /// sRGB→linear→XYZ→Lab pipeline. Pure and side-effect-free.
    static func srgbToLab(_ c: RGB) -> (L: Double, a: Double, b: Double) {
        func linear(_ v: UInt8) -> Double {
            let s = Double(v) / 255.0
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)

        // Linear sRGB → XYZ (D65).
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b

        // Normalize by the D65 white point.
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double {
            let d = 6.0 / 29.0
            return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
        }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Lowercased `#rrggbb` for an sRGB color.
    private static func hex(_ c: RGB) -> String {
        String(format: "#%02x%02x%02x", c.r, c.g, c.b)
    }

    /// Pack an RGB into a comparable `UInt32` for deterministic tie-breaking.
    private static func packed(_ c: RGB) -> UInt32 {
        (UInt32(c.r) << 16) | (UInt32(c.g) << 8) | UInt32(c.b)
    }

    // MARK: - Decode adapters

    /// Extract the top `maxColors` dominant colors from an already-decoded
    /// `CGImage` — the reduction seam the analyzer uses to analyze without
    /// re-decoding. Reads the image's straight (un-premultiplied) sRGB pixels,
    /// drops near-transparent ones, and clusters.
    ///
    /// - Throws: ``ImageError/decodeFailed`` if a draw context can't be built.
    ///   Returns `[]` if every pixel was transparent.
    public static func swatches(fromCGImage image: CGImage, maxColors: Int = 5) throws -> [ColorSwatch] {
        swatches(fromPixels: try readPixels(image), maxColors: maxColors)
    }

    /// Extract the top `maxColors` dominant colors from image `data`.
    ///
    /// The thin byte adapter: decode a ≤``sampleMaxPixelSize`` display-oriented
    /// thumbnail via the shared ``ImageDecoding`` helper, then
    /// ``swatches(fromCGImage:maxColors:)``. `maxColors` defaults to 5 (012's
    /// `colors TEXT` stores the top 5).
    ///
    /// - Throws: ``ImageError/unreadable`` for non-image bytes,
    ///   ``ImageError/decodeFailed`` if the thumbnail or draw context can't be made.
    public static func extract(from data: Data, maxColors: Int = 5) throws -> [ColorSwatch] {
        let image = try ImageDecoding.thumbnailCGImage(from: data, maxPixelSize: sampleMaxPixelSize)
        return try swatches(fromCGImage: image, maxColors: maxColors)
    }

    /// Draw `image` into a straight-alpha RGBA8 context and read back its opaque
    /// pixels as ``RGB``. Premultiplied bytes are un-multiplied back to straight
    /// color; pixels with alpha below ``alphaThreshold`` are dropped.
    private static func readPixels(_ image: CGImage) throws -> [RGB] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var raw = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let ok: Bool = raw.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw ImageError.decodeFailed }

        var pixels = [RGB]()
        pixels.reserveCapacity(width * height)
        var i = 0
        while i < raw.count {
            let a = raw[i + 3]
            if a >= alphaThreshold {
                if a == 255 {
                    pixels.append(RGB(r: raw[i], g: raw[i + 1], b: raw[i + 2]))
                } else {
                    // Un-premultiply: straight = premultiplied × 255 ÷ alpha.
                    let av = Int(a)
                    pixels.append(RGB(
                        r: UInt8(min(255, Int(raw[i]) * 255 / av)),
                        g: UInt8(min(255, Int(raw[i + 1]) * 255 / av)),
                        b: UInt8(min(255, Int(raw[i + 2]) * 255 / av))))
                }
            }
            i += bytesPerPixel
        }
        return pixels
    }
}
