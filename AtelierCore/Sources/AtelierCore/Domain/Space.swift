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
    /// Manual position among the (flat) space list, maintained DENSE and gapless as
    /// `0..<n` by `AppServices` on create/delete/move — the space analog of
    /// ``Collection/sortIndex`` (043 · 2B). Added by migration v15, `DEFAULT 0`,
    /// back-filled deterministically from the prior `created_at DESC` order so
    /// existing installs keep their current arrangement. Drives the sidebar order
    /// (tie-broken by `(created_at DESC, id)` so equal indices stay stable).
    public var sortIndex: Int
    /// ``SpaceCamera`` JSON — where this board was last looked at (018 · Cluster C).
    /// `nil` for a board that has never been opened, and for one whose blob no
    /// longer decodes; both cases fall back to fit-to-content on open. Added by
    /// migration v17, NULL for every existing row (no back-fill — there is no
    /// historical camera to recover). Stored as the encoded string rather than a
    /// decoded value, exactly as ``SpaceItem/style`` is.
    public var camera: String?

    /// Explicit snake_case column/coding names (exact acronym mapping, e.g.
    /// `coverAssetID` ⇄ `cover_asset_id`).
    public enum CodingKeys: String, CodingKey {
        case id, name
        case coverAssetID = "cover_asset_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sortIndex = "sort_index"
        case camera
    }

    public init(
        id: UUID,
        name: String,
        coverAssetID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date,
        sortIndex: Int = 0,
        camera: String? = nil
    ) {
        self.id = id
        self.name = name
        self.coverAssetID = coverAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortIndex = sortIndex
        self.camera = camera
    }
}
