// AtelierCore — AssetAnalysis GRDB conformance (012 · I1 / A1)
//
// Keeps the domain struct GRDB-free: the record conformance lives here, in the
// Persistence layer. `internal` (A2). Mirrors `Job+GRDB` / `Source+GRDB`.

import GRDB

extension AssetAnalysis: AtelierRecord {
    /// Binds to the `asset_analysis` table from `Migrator.v7` (PK is `asset_id`,
    /// one analysis per asset — no `id` column of its own).
    public static let databaseTableName = "asset_analysis"

    // C5 — store the `asset_id` UUID as lowercased TEXT (column names come from
    // CodingKeys; `colors`/`ocr_text` are TEXT, `phash` a signed INTEGER).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
