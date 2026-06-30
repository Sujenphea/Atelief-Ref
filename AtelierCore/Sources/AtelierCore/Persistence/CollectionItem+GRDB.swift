// AtelierCore — CollectionItem GRDB conformance + associations (chunk 4, A1/P14)
//
// The membership row, plus the two `belongsTo` associations that make the P14
// collection read a single joined query (CollectionItem → Asset → Source).
// `internal` (A2); the domain struct stays GRDB-free.

import GRDB

extension CollectionItem: AtelierRecord {
    /// Binds to the `collection_item` table from `Migrator.v1`.
    public static let databaseTableName = "collection_item"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }

    /// FK `collection_item.collection_id REFERENCES collection(id)` (inferred).
    static let collection = belongsTo(Collection.self)

    /// FK `collection_item.asset_id REFERENCES asset(id)` (inferred).
    static let asset = belongsTo(Asset.self)
}
