// AtelierCore — Job + JobItem GRDB conformance (015 · decision 3A / A1)
//
// Keeps the domain structs GRDB-free: the record conformance lives here, in the
// Persistence layer. `internal` (A2). Mirrors `Source+GRDB` / `Tag+GRDB`.

import GRDB

extension Job: AtelierRecord {
    /// Binds to the `job` table from `Migrator.v3`.
    public static let databaseTableName = "job"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}

extension JobItem: AtelierRecord {
    /// Binds to the `job_item` table from `Migrator.v3` (composite PK
    /// `(job_id, source_id)`; no `id` of its own — like `asset_tag`).
    public static let databaseTableName = "job_item"

    // C5 — store the `job_id` UUID as lowercased TEXT (source_id is a platform
    // string, not a UUID; column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
