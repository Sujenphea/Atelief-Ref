// AtelierIngestion — perceptual (difference) hashing (feature 012, I1)
//
// A 64-bit dHash: the near-duplicate primitive behind 012's "Duplicates" review
// surface. Unlike ``ContentHasher`` (SHA-256, byte-exact — a re-encoded or
// resized copy hashes differently), a perceptual hash is *content* shaped: it
// survives re-encoding, resizing, and mild recompression, so two visually-equal
// images land at a small Hamming distance even when their bytes differ (the 012
// §Current-state gap: exact-hash dedup misses resized/re-encoded copies).
//
// The design splits, like the rest of the package, into a PURE core and thin
// decode adapters:
//   • ``PerceptualHash/dHash(reducedLuminance:)`` is total, allocation-light, and
//     Vision-free — it operates on an already-reduced 9×8 luminance grid, so the
//     whole algorithm is property-testable with hand-built grids. Its 72-sample
//     contract is a `precondition` (a call-site programmer error, never
//     data-driven), not a thrown error.
//   • ``PerceptualHash/hash(_:)`` (a `CGImage`) and ``PerceptualHash/hash(from:)``
//     (bytes) are the only parts that touch CoreGraphics/ImageIO. The `CGImage`
//     entry lets the future `AssetAnalyzer` decode an asset ONCE (via
//     ``ImageDecoding``) and run both this and ``ColorExtractor`` over the same
//     image rather than decoding twice.
//
// dHash, precisely: reduce to a (W+1)×H grayscale grid (9×8), then for each row
// emit one bit per adjacent horizontal pair — 1 when the left sample is brighter
// than its right neighbor. 8 pairs × 8 rows = 64 bits, packed MSB-first into a
// `UInt64`. Comparing *gradients* rather than absolute levels is what makes it
// robust to global brightness/contrast shifts.
//
// KNOWN LIMITATION (by design — dHash, not a bug). The reduction is to LUMINANCE
// gradients, so the hash is:
//   • flat-blind: every solid / single-color image reduces to all-equal samples →
//     hash 0, so all solids collide at Hamming distance 0; and
//   • hue-blind: two images with the same luminance structure but different colors
//     (e.g. an equal-brightness red↔green swap) hash identically.
// The pure primitive stays a faithful dHash; the POLICY for these blind spots
// belongs in the 012 duplicates surface (I5), which should treat distance-0
// clusters as candidates and disambiguate with the ``ColorExtractor`` signature
// before calling anything a duplicate.
//
// PERSISTENCE NOTE (feature 012 `asset_analysis.phash INTEGER`). SQLite INTEGER is
// signed Int64; this returns `UInt64` because a bit-signature is unsigned and
// ``hammingDistance`` must operate on the raw bits. The `UInt64`↔`Int64`
// reinterpretation (`Int64(bitPattern:)` on store, `UInt64(bitPattern:)` on load)
// is the analyzer's job at the AtelierCore seam — it never happens in this pure
// package, keeping GRDB and signedness concerns out of the hash itself.

import CoreGraphics
import Foundation

/// A 64-bit perceptual difference-hash (dHash) and its distance metric — the
/// near-duplicate primitive for feature 012.
///
/// A stateless namespace (all members `static`), matching ``ContentHasher`` and
/// ``ThumbnailGenerator``. The hash is a `UInt64`; similarity is the Hamming
/// distance between two hashes (0 = identical gradient signature, 64 = maximal).
public enum PerceptualHash {
    /// Sample columns in the reduced grid. dHash needs one extra column beyond
    /// the 8 output bits per row so every bit is a *pair* comparison.
    public static let reducedWidth = 9
    /// Sample rows in the reduced grid — also the number of output bits per row.
    public static let reducedHeight = 8
    /// Bit count of the produced hash (`reducedHeight × (reducedWidth - 1)` = 64).
    public static let bitCount = reducedHeight * (reducedWidth - 1)

    /// Longest edge of the intermediate thumbnail decoded before reduction to the
    /// 9×8 grid. A hard decode straight to 9 px point-samples and loses the
    /// structure dHash reads; a small intermediate (64 px) then a high-quality box
    /// resample into 9×8 is stabler across source sizes, while staying cheap.
    private static let intermediateDecodeSize = 64

    /// Compute the 64-bit dHash of an already-reduced luminance grid.
    ///
    /// `reducedLuminance` is exactly ``reducedWidth`` × ``reducedHeight`` (= 72)
    /// samples in **row-major** order (column varies fastest): index
    /// `row * reducedWidth + col`. Each value is an 8-bit luminance (0 = black,
    /// 255 = white). This is the pure heart of the algorithm — no image decoding,
    /// no framework calls — so it is exhaustively testable with synthetic grids.
    ///
    /// For each of the 8 rows and each of the 8 adjacent column pairs, one bit is
    /// set when the left sample is **strictly brighter** than its right neighbor
    /// (`left > right`). Bits are packed MSB-first in row-major pair order, so bit
    /// 63 is row 0's first pair and bit 0 is the last row's last pair.
    ///
    /// The 72-sample size is a **precondition**: it is an internal invariant every
    /// caller in this package satisfies by construction (the reduction always
    /// yields 72), never a value derived from input data — so a mismatch is a
    /// programming error surfaced loudly, not a recoverable failure.
    public static func dHash(reducedLuminance: [UInt8]) -> UInt64 {
        precondition(
            reducedLuminance.count == reducedWidth * reducedHeight,
            "dHash requires exactly \(reducedWidth * reducedHeight) luminance samples, got \(reducedLuminance.count)")

        var hash: UInt64 = 0
        var bit = bitCount - 1  // fill from the MSB downward
        for row in 0 ..< reducedHeight {
            let base = row * reducedWidth
            for col in 0 ..< (reducedWidth - 1) {
                if reducedLuminance[base + col] > reducedLuminance[base + col + 1] {
                    hash |= (1 as UInt64) << UInt64(bit)
                }
                bit -= 1
            }
        }
        return hash
    }

    /// The Hamming distance between two perceptual hashes: the number of differing
    /// bits, in `0...64`. Smaller means more visually similar; a threshold around
    /// ≤10 is the usual near-duplicate cutoff (tuned by the 012 review surface, not
    /// fixed here).
    ///
    /// A pure `nonzeroBitCount` of the XOR — reflexive (`distance(x, x) == 0`) and
    /// symmetric by construction.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// The dHash of an already-decoded `CGImage`.
    ///
    /// The reduction seam the analyzer uses to hash without re-decoding: it draws
    /// `image` straight into a 9×8 grayscale context and hands the grid to
    /// ``dHash(reducedLuminance:)``. Callers holding only bytes use
    /// ``hash(from:)`` instead.
    ///
    /// - Throws: ``ImageError/decodeFailed`` if the grayscale context can't be
    ///   built (a CoreGraphics allocation failure).
    public static func hash(_ image: CGImage) throws -> UInt64 {
        dHash(reducedLuminance: try reduceToLuminanceGrid(image))
    }

    /// Decode image `data` down to a 9×8 luminance grid and return its dHash.
    ///
    /// The thin byte adapter: decode a small display-oriented thumbnail through the
    /// shared ``ImageDecoding`` helper (EXIF transform applied, so orientation
    /// variants of one image agree), then ``hash(_:)``.
    ///
    /// - Throws: ``ImageError/unreadable`` for bytes that aren't an image source,
    ///   ``ImageError/decodeFailed`` if no thumbnail or grayscale context can be
    ///   produced.
    public static func hash(from data: Data) throws -> UInt64 {
        let image = try ImageDecoding.thumbnailCGImage(from: data, maxPixelSize: intermediateDecodeSize)
        return try hash(image)
    }

    /// Draw `image` into a ``reducedWidth`` × ``reducedHeight`` 8-bit grayscale
    /// context and read back the row-major luminance grid.
    ///
    /// A device-gray `CGContext` performs the RGB→luminance conversion during the
    /// draw. `bytesPerRow` may be padded by CoreGraphics, so rows are read using
    /// the context's actual stride rather than assuming a tight ``reducedWidth``.
    private static func reduceToLuminanceGrid(_ image: CGImage) throws -> [UInt8] {
        let width = reducedWidth
        let height = reducedHeight
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,  // let CoreGraphics choose (may pad the stride)
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw ImageError.decodeFailed
        }

        // High-quality interpolation so the downsample averages, rather than
        // point-samples, the source — keeps the reduced grid stable across sizes.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixels = context.data else {
            throw ImageError.decodeFailed
        }
        let stride = context.bytesPerRow
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: stride * height)

        var grid = [UInt8](repeating: 0, count: width * height)
        for row in 0 ..< height {
            let rowStart = row * stride
            for col in 0 ..< width {
                grid[row * width + col] = buffer[rowStart + col]
            }
        }
        return grid
    }
}
