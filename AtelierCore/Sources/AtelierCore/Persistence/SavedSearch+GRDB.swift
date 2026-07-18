// AtelierCore — SavedSearch GRDB conformance (015 / A1)
//
// Keeps the domain struct GRDB-free: the record conformance lives here, in the
// Persistence layer. Mirrors `Collection+GRDB` / `AssetAnalysis+GRDB`.

import GRDB

extension SavedSearch: AtelierRecord {
    /// Binds to the `saved_search` table from `Migrator.v8` (PK is `id`).
    public static let databaseTableName = "saved_search"

    // C5 — store the `id` UUID as lowercased TEXT (column names come from
    // CodingKeys; `rules` is opaque TEXT).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }
}
