// AtelierCore — shared GRDB record convention (chunk 4, decisions A1/A2/C5)
//
// One protocol that bundles the package's storage conventions so every record
// conforms identically. Conformances live in `*+GRDB.swift` extension files
// (A1) so the Domain structs stay GRDB-free; GRDB is confined to the
// Persistence layer (A2). Everything here is `internal`.

import GRDB

/// The package's record convention. Conforming a domain type makes it both
/// readable (`FetchableRecord`) and writable (`PersistableRecord`) through GRDB.
///
/// Ids are app-provided (UUIDs), never autoincremented, so these are plain
/// `PersistableRecord`s (no `MutablePersistableRecord` / `didInsert`).
///
/// **Column names** come from each domain type's explicit `CodingKeys`
/// (snake_case), not from a column-encoding *strategy*. We deliberately avoid
/// GRDB's `.convertToSnakeCase` / `.convertFromSnakeCase`: Foundation's two
/// conversions are not inverses for all-caps acronyms — `originalURL` encodes to
/// `original_url`, but `original_url` decodes back to `originalUrl`, so the
/// round-trip silently loses the column. Explicit `CodingKeys` make the mapping
/// exact and reviewable (explicit over clever). Each record only forwards the
/// UUID value strategy (``RecordConvention``).
protocol AtelierRecord: FetchableRecord, PersistableRecord, Codable {}

/// The UUID value-encoding strategy (C5), defined once (DRY) and forwarded by
/// each concrete record's `databaseUUIDEncodingStrategy(for:)`.
///
/// This is a value encoding (how a UUID becomes a column value), distinct from
/// column *naming* (handled by `CodingKeys`). GRDB's default would store UUIDs
/// as 16-byte blobs; we store lowercased `uuidString` TEXT so the database is
/// agent-readable. Date is intentionally left at GRDB's default
/// `YYYY-MM-DD HH:MM:SS.SSS` UTC text — millisecond-precise and lexically
/// sortable, both required by C5 (unlike `.iso8601`, which truncates).
enum RecordConvention {
    static let uuidEncoding = DatabaseUUIDEncodingStrategy.lowercaseString
}
