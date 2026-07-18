// AtelierIngestion — on-device asset analyzer (feature 012, I1)
//
// Runs the passive-metadata pipeline over one image: perceptual hash (near-dup),
// dominant colors, and OCR text. It composes the pure imaging cores
// (``PerceptualHash``, ``ColorExtractor``) with an INJECTABLE text-recognition
// seam (``TextRecognizing``) — the only nondeterministic, Vision-bound part — so
// every consumer is testable with a fake recognizer and no Vision at all.
//
// Decode-once (the 15A benefit): the source is decoded a SINGLE time, then the
// resulting `CGImage` is handed to all three analyses. The decode is sized for
// OCR — the largest consumer, and 012's highest search-quality win — so it uses a
// larger thumbnail than the hash/color paths would pick alone; those two simply
// downsample from it internally (`PerceptualHash` to its 9×8 grid,
// `ColorExtractor` via its histogram). ``analyze(cgImage:)`` lets a caller supply
// an already-decoded image (e.g. a stored thumbnail — the deferred 16A
// optimization), skipping the decode entirely.
//
// This layer produces a typed ``AnalysisResult`` and its serialized forms
// (``AnalysisResult/signedPHash``, ``AnalysisResult/colorsJSON``) — the 2A
// boundary. Persisting it through `AppServices.upsertAnalysis` is the wiring
// layer's job (a later 012 phase); the analyzer itself never touches AtelierCore.

import CoreGraphics
import Foundation

/// Recognizes text inside an image — the injectable OCR seam (feature 012).
///
/// Refines `Sendable` so an ``AssetAnalyzer`` holding one stays `Sendable`. The
/// method is **synchronous**: Vision's `perform` is itself synchronous, and a sync
/// signature avoids passing the non-`Sendable` `CGImage` across an async boundary.
/// Production uses ``VisionTextRecognizer``; tests use a fake.
public protocol TextRecognizing: Sendable {
    /// Recognized text in `image`, joined across lines, or `nil` when none was
    /// found. Throws only on a recognition-engine failure (not on "no text").
    func recognizeText(in image: CGImage) throws -> String?
}

/// The derived passive metadata for one asset (feature 012 · I1): perceptual
/// hash, dominant colors, and OCR text, plus the serialized forms the
/// `asset_analysis` columns store.
public struct AnalysisResult: Sendable, Equatable {
    /// The 64-bit perceptual hash (unsigned — the natural form for Hamming
    /// distance and bit-packing).
    public let phash: UInt64
    /// The top dominant colors, most-dominant first (possibly empty).
    public let colors: [ColorSwatch]
    /// Recognized text inside the image, or `nil` when none/empty.
    public let ocrText: String?

    public init(phash: UInt64, colors: [ColorSwatch], ocrText: String?) {
        self.phash = phash
        self.colors = colors
        self.ocrText = ocrText
    }

    /// The perceptual hash reinterpreted as `Int64` for 012's
    /// `asset_analysis.phash INTEGER` column (SQLite has no unsigned type). The
    /// bit pattern is preserved, so a consumer casts back with
    /// `UInt64(bitPattern:)` before computing Hamming distance — the 2A seam.
    public var signedPHash: Int64 { Int64(bitPattern: phash) }

    /// The colors as `[{"hex", "coverage"}]` JSON for `asset_analysis.colors`, or
    /// `nil` when there are none (matching the NULLABLE column).
    public var colorsJSON: String? { ColorSwatch.encodeList(colors) }
}

/// The on-device analyzer (feature 012 · I1): decode once, then hash + color +
/// OCR. A `Sendable` value type holding only its injected recognizer.
public struct AssetAnalyzer: Sendable {
    /// The algorithm version stamped on every row this analyzer produces (012's
    /// `analyzer_version`). Bump when any analysis output changes so the backfill
    /// re-analyzes existing rows via a `WHERE analyzer_version < …` scan.
    public static let analyzerVersion = 1

    /// Longest-edge size of the single decode. Sized for OCR legibility (the
    /// largest consumer); hash and color downsample from it. Larger would improve
    /// OCR on dense text at a quadratic memory/time cost — 1024 is the balance for
    /// idle-priority per-asset backfill.
    public static let decodeSize = 1024

    /// How many dominant colors to extract (012's `colors` stores the top 5).
    public static let maxColors = 5

    private let textRecognizer: any TextRecognizing

    /// Create an analyzer with an injected OCR seam (``VisionTextRecognizer`` in
    /// production, a fake in tests).
    public init(textRecognizer: any TextRecognizing) {
        self.textRecognizer = textRecognizer
    }

    /// Analyze an already-decoded image — the decode-once entry point. Runs all
    /// three analyses over the SAME `CGImage`. OCR text that comes back empty is
    /// normalized to `nil` (nothing legible ⇒ no row content, not `""`).
    ///
    /// - Throws: ``ImageError/decodeFailed`` if the hash/color draw contexts can't
    ///   be built, or any error the recognizer raises.
    public func analyze(cgImage image: CGImage) throws -> AnalysisResult {
        let phash = try PerceptualHash.hash(image)
        let colors = try ColorExtractor.swatches(fromCGImage: image, maxColors: Self.maxColors)
        let recognized = try textRecognizer.recognizeText(in: image)
        let ocrText = (recognized?.isEmpty ?? true) ? nil : recognized
        return AnalysisResult(phash: phash, colors: colors, ocrText: ocrText)
    }

    /// Analyze raw image `data`: decode once (sized for OCR) via the shared
    /// ``ImageDecoding`` helper, then ``analyze(cgImage:)``.
    ///
    /// - Throws: ``ImageError/unreadable`` for non-image bytes,
    ///   ``ImageError/decodeFailed`` on a decode/context failure, or a recognizer
    ///   error.
    public func analyze(imageData data: Data) throws -> AnalysisResult {
        let image = try ImageDecoding.thumbnailCGImage(from: data, maxPixelSize: Self.decodeSize)
        return try analyze(cgImage: image)
    }
}
