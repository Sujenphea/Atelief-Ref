// AtelierCore — Tag + AssetTag GRDB conformance (chunk 4, decision A1)
//
// Both schema-reserved for the agent interface (006 scope). `internal` (A2);
// the domain structs stay GRDB-free.

import GRDB

extension Tag: AtelierRecord {
    /// Binds to the `tag` table from `Migrator.v1`.
    public static let databaseTableName = "tag"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}

extension AssetTag: AtelierRecord {
    /// Binds to the `asset_tag` join table from `Migrator.v1` (composite PK
    /// `(asset_id, tag_id)`; no `id` of its own).
    public static let databaseTableName = "asset_tag"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
