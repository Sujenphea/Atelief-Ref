// AtelierCore — Space (005 · first-class spaces)
//
// A Space is a freeform board — its own first-class entity, NOT bound to a
// folder (005 §entity, decision O1). It mixes assets from any collection and
// (later, E3) freeform elements (frames / text / shapes). A plain value type:
// no persistence, no validation (name trim/reject lives in the funnel, C8); the
// GRDB conformance lives in `Persistence/Space+GRDB.swift` (A1).

import Foundation

/// A freeform board (005 §entity). Unlike a ``Collection`` it has no membership
/// dedup, no nesting, and no protected default — it is a plain named canvas that
/// references assets (and, later, elements) through ``SpaceItem`` rows.
public struct Space: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity.
    public var id: UUID
    /// Display name.
    public var name: String
    /// FK → ``Asset``. Optional cover thumbnail for the Spaces list (open Q2 —
    /// covers reuse the collection-cover pattern). `SET NULL` on asset delete.
    public var coverAssetID: UUID?
    /// When created.
    public var createdAt: Date
    /// When last modified.
    public var updatedAt: Date

    /// Explicit snake_case column/coding names (exact acronym mapping, e.g.
    /// `coverAssetID` ⇄ `cover_asset_id`).
    public enum CodingKeys: String, CodingKey {
        case id, name
        case coverAssetID = "cover_asset_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        name: String,
        coverAssetID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.coverAssetID = coverAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
