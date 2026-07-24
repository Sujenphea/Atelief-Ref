// AtelierCore — AssetEmbedding GRDB conformance (047 · 3a)
//
// Keeps the domain struct GRDB-free: the record conformance lives here, in the
// Persistence layer. Mirrors `AssetAnalysis+GRDB`.

import GRDB

extension AssetEmbedding: AtelierRecord {
    /// Binds to the `asset_embedding` table from `Migrator.v14` (PK is `asset_id`,
    /// one embedding per asset). `vector` is a BLOB; GRDB stores `Data` as BLOB.
    public static let databaseTableName = "asset_embedding"

    // C5 — store the `asset_id` UUID as lowercased TEXT.
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
