// AtelierCore — on-device analysis metadata (012 · I1)
//
// The derived, passive metadata a later analyzer computes for an asset: OCR text,
// dominant colors, and a perceptual hash. One row per asset (`asset_id` PK), and
// all three data fields are optional — analysis is derived data that may be
// absent, partial, or produced by an older algorithm version.
//
// This layer treats `colors` as OPAQUE serialized text and `phash` as a plain
// signed integer: the analyzer (in AtelierIngestion, which owns the imaging
// types) serializes `[ColorSwatch]` → JSON and bit-casts the unsigned 64-bit
// hash → `Int64` before persisting through `AppServices`. Keeping the shapes out
// of AtelierCore preserves the package boundary (imaging types never leak into
// the store) — the 2A serialization seam.
//
// Plain value type, mirroring `Job`: no persistence, no validation here; the GRDB
// conformance lives in `Persistence/AssetAnalysis+GRDB.swift` (A1) and the
// mutation funnel in `AppServices` (A4).

import Foundation

/// One asset's derived analysis metadata (012 · I1). `analyzerVersion` records
/// which algorithm produced this row, so an algorithm upgrade re-analyzes via a
/// `WHERE analyzer_version < …` scan rather than a schema change.
public struct AssetAnalysis: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// The analyzed asset (FK → `asset.id`, CASCADE). Also the primary key — one
    /// analysis row per asset. Doubles as `Identifiable.id`.
    public var assetID: UUID
    /// Recognized text found inside the image (OCR), or `nil` when none was
    /// legible / not yet run. Feeds `analysis_fts` for search-inside-images.
    public var ocrText: String?
    /// The dominant colors as opaque serialized JSON (the analyzer owns the
    /// `[{hex, coverage}]` shape), or `nil` when not computed.
    public var colors: String?
    /// The 64-bit perceptual hash stored as a signed integer (SQLite has no
    /// unsigned type; the analyzer bit-casts `UInt64`↔`Int64` at its seam), or
    /// `nil` when not computed.
    public var phash: Int64?
    /// When this analysis was produced.
    public var analyzedAt: Date
    /// The analyzer algorithm version that produced this row (drives re-analysis).
    public var analyzerVersion: Int
    /// The ``ColorPalette`` version that filed ``colors`` into `asset_color`
    /// rows, or `nil` when they have not been filed at all (085 · C1).
    ///
    /// `nil` and "older than the current palette" both mean the derivation pass
    /// owes this asset work. It is deliberately NOT a boolean: emptiness is not
    /// a usable marker, because an unreadable palette derives zero rows and would
    /// otherwise be re-queued forever.
    public var colorsPaletteVersion: Int?
    /// The suggester version that last proposed tags for this asset, or `nil`
    /// when none ever has (012 · I3).
    ///
    /// Separate from ``analyzerVersion`` on purpose. That one gates OCR, colors
    /// and the perceptual hash together, so bumping it re-decodes every image in
    /// the library; a tag-model change has no business costing a full re-OCR, and
    /// the two version on different schedules. Same WHERE-clause trick, its own
    /// counter.
    public var suggestVersion: Int?

    /// Monotonic write counter (v23): greater than any value issued before, bumped on
    /// every ``AppServices/upsertAnalysis(assetID:ocrText:colors:phash:analyzerVersion:)``.
    /// It answers "has the analysis moved since the embedding was made" without asking
    /// wall-clock time, which ties at millisecond resolution. NULL only for a row that
    /// predates v23 and has not been re-analyzed since.
    public var analysisSeq: Int?

    public var id: UUID { assetID }

    /// Explicit snake_case column/coding names (exact acronym mapping).
    public enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case ocrText = "ocr_text"
        case colors
        case phash
        case analyzedAt = "analyzed_at"
        case analyzerVersion = "analyzer_version"
        case colorsPaletteVersion = "colors_palette_version"
        case suggestVersion = "suggest_version"
        case analysisSeq = "analysis_seq"
    }

    public init(
        assetID: UUID,
        ocrText: String? = nil,
        colors: String? = nil,
        phash: Int64? = nil,
        analyzedAt: Date,
        analyzerVersion: Int,
        colorsPaletteVersion: Int? = nil,
        suggestVersion: Int? = nil,
        analysisSeq: Int? = nil
    ) {
        self.assetID = assetID
        self.ocrText = ocrText
        self.colors = colors
        self.phash = phash
        self.analyzedAt = analyzedAt
        self.analyzerVersion = analyzerVersion
        self.analysisSeq = analysisSeq
        self.colorsPaletteVersion = colorsPaletteVersion
        self.suggestVersion = suggestVersion
    }
}
