// AtelierCore — Source GRDB conformance (chunk 4, decision A1)
//
// Keeps the domain `Source` struct GRDB-free: the record conformance lives
// here, in the Persistence layer, not on the declaration. `internal` (A2).

import GRDB

extension Source: AtelierRecord {
    /// Binds to the `source` table from `Migrator.v1`.
    public static let databaseTableName = "source"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }

    // `rawMetadata` is a nested `JSONValue` (not a database-scalar). GRDB
    // encodes non-scalar Codable properties as JSON text automatically, landing
    // in the TEXT `raw_metadata` column — verified by a round-trip test.
}
