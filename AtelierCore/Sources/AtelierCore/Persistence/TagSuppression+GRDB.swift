// AtelierCore — TagSuppression GRDB conformance (012 · I3)
//
// Keeps the domain struct GRDB-free: the record conformance lives here, in the
// Persistence layer. Mirrors `AssetColor+GRDB` / `AssetAnalysis+GRDB`.

import GRDB

extension TagSuppression: AtelierRecord {
    /// Binds to the `tag_suppression` table from `Migrator.v22`. The primary key
    /// is the COMPOSITE `(asset_id, tag_name)`, so — like `AssetColor` — this
    /// record has no single-column PK and is never fetched by `key:`.
    public static let databaseTableName = "tag_suppression"

    // C5 — store the `asset_id` UUID as lowercased TEXT.
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
