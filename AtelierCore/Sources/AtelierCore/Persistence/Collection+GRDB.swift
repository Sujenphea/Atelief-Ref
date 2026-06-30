// AtelierCore — Collection GRDB conformance (chunk 4, decision A1)
//
// `internal` (A2); the domain `Collection` struct stays GRDB-free.

import GRDB

extension Collection: AtelierRecord {
    /// Binds to the `collection` table from `Migrator.v1`.
    public static let databaseTableName = "collection"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
