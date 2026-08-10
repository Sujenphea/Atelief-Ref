// AtelierCore — AssetColor GRDB conformance (085 · C1)
//
// Keeps the domain struct GRDB-free: the record conformance lives here, in the
// Persistence layer. Mirrors `AssetAnalysis+GRDB` / `AssetEmbedding+GRDB`.

import GRDB

extension AssetColor: AtelierRecord {
    /// Binds to the `asset_color` table from `Migrator.v21`. The primary key is
    /// the COMPOSITE `(asset_id, bucket)` — one row per bucket per asset, since
    /// same-bucket swatches merge upstream — so unlike the other analysis tables
    /// this record has no single-column PK and is never fetched by `key:`.
    public static let databaseTableName = "asset_color"

    // C5 — store the `asset_id` UUID as lowercased TEXT.
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
