// AtelierCore — Space GRDB conformance (005 · A1)
//
// `internal` (A2); the domain `Space` struct stays GRDB-free. Mirrors
// `Collection+GRDB`.

import GRDB

extension Space: AtelierRecord {
    /// Binds to the `space` table from `Migrator.v4`.
    public static let databaseTableName = "space"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
