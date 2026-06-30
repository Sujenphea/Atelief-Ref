// AtelierCore — Asset GRDB conformance + associations (chunk 4, A1/P14)
//
// Record conformance plus the `belongsTo(Source)` association the P14 joined
// read traverses. `internal` (A2); domain `Asset` stays GRDB-free.

import GRDB

extension Asset: AtelierRecord {
    /// Binds to the `asset` table from `Migrator.v1`.
    public static let databaseTableName = "asset"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }

    /// Every asset has exactly one origin (C6). GRDB infers the foreign key
    /// from the schema's `asset.source_id REFERENCES source(id)`.
    static let source = belongsTo(Source.self)
}
