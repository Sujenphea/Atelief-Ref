// AtelierCore — SpaceItem GRDB conformance + associations (005 · A1)
//
// The board-row record plus the `belongsTo` associations that let the space
// read join each ASSET row to its ``Asset`` (and that asset's ``Source``) in one
// query. Element rows have a NULL `asset_id`, so the asset join is OPTIONAL
// (LEFT) — see `AppServices.spaceItems(in:)`. `internal` (A2); the domain struct
// stays GRDB-free.

import GRDB

extension SpaceItem: AtelierRecord {
    /// Binds to the `space_item` table from `Migrator.v4`.
    public static let databaseTableName = "space_item"

    // C5 — store UUIDs as lowercased TEXT (column names come from CodingKeys).
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { RecordConvention.uuidEncoding }

    /// FK `space_item.space_id REFERENCES space(id)` (inferred).
    static let space = belongsTo(Space.self)

    /// FK `space_item.asset_id REFERENCES asset(id)` (inferred). Nullable — an
    /// element row has no asset, so the join is used as `optional` (LEFT).
    static let asset = belongsTo(Asset.self)
}
