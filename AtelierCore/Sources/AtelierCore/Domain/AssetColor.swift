// AtelierCore — one asset's palette-bucket coverage (085 · C1)
//
// The searchable form of `asset_analysis.colors`. That column is the source of
// truth and stays opaque JSON; these rows are its derivation — which fixed
// palette bucket each dominant swatch fell into, and how much of the image the
// bucket covers once same-bucket swatches are merged.
//
// `bucket` is an INTEGER THIS LAYER NEVER INTERPRETS. The palette lives in
// AtelierIngestion (`ColorBucket`), which AtelierCore cannot see — the package
// dependency runs Ingestion → Core. That is the same boundary `colors` itself
// observes ("Ingestion owns the shape; AtelierCore stores it opaquely") and the
// reason the filter can be a plain integer predicate in SQL.
//
// The table exists at all because the color filter has to be a WHERE conjunct:
// a predicate applied after the fetch shortens pages, and the keyset cursor then
// pages through the gaps (023 · A1, `.change-log/367`).
//
// Plain value type (mirrors `AssetAnalysis` / `AssetEmbedding`): the GRDB
// conformance lives in `Persistence/AssetColor+GRDB.swift`, the mutation funnel
// in `AppServices`.

import Foundation

/// One (asset, palette bucket) pair with the share of the image it covers.
///
/// There is at most ONE row per (asset, bucket): swatches landing in the same
/// bucket are merged before they reach this layer, because two reds at 12% and
/// 8% must match a 15% filter floor as one red at 20%.
public struct AssetColor: Sendable, Equatable, Hashable, Codable {
    /// The asset these colors belong to (FK → `asset.id`, CASCADE).
    public var assetID: UUID
    /// The palette bucket's raw value. Opaque here — see the file header.
    public var bucket: Int
    /// Share of the image this bucket covers, `0...1`, summed across every
    /// swatch that filed under it.
    public var coverage: Double

    /// Explicit snake_case column/coding names (exact acronym mapping).
    public enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case bucket
        case coverage
    }

    public init(assetID: UUID, bucket: Int, coverage: Double) {
        self.assetID = assetID
        self.bucket = bucket
        self.coverage = coverage
    }
}
