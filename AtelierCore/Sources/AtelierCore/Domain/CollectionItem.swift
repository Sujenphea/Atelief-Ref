// AtelierCore — CollectionItem
//
// Mirrors 003 §data-model · CollectionItem exactly. A plain value type: no
// persistence, no validation (non-finite canvas placement is rejected in the
// funnel, C8). The placement fields intentionally mirror CanvasRenderer.Tile.

import Foundation

/// An ``Asset``'s membership in a ``Collection``, plus its per-view placement
/// (003 §data-model). **Many-to-many**: one asset can live in multiple
/// collections without disk duplication.
///
/// Placement lives **per-membership**, not on the asset — the same asset can be
/// order 3 in the grid and at (1200, 480) on the canvas. Grid honors
/// `manualOrder`; canvas honors `canvasX/Y/W/H/Z`.
public struct CollectionItem: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity.
    public var id: UUID
    /// FK → ``Collection``.
    public var collectionID: UUID
    /// FK → ``Asset``.
    public var assetID: UUID
    /// When added to the collection.
    public var addedAt: Date
    /// Ordering in grid view.
    public var manualOrder: Int?
    /// Position x on the infinite canvas.
    public var canvasX: Double?
    /// Position y on the infinite canvas.
    public var canvasY: Double?
    /// Width on the canvas (overrides intrinsic).
    public var canvasW: Double?
    /// Height on the canvas (overrides intrinsic).
    public var canvasH: Double?
    /// Stacking order on the canvas.
    public var canvasZ: Int?

    /// Explicit snake_case column/coding names (exact acronym mapping, e.g.
    /// `collectionID` ⇄ `collection_id`, `assetID` ⇄ `asset_id`).
    public enum CodingKeys: String, CodingKey {
        case id
        case collectionID = "collection_id"
        case assetID = "asset_id"
        case addedAt = "added_at"
        case manualOrder = "manual_order"
        case canvasX = "canvas_x"
        case canvasY = "canvas_y"
        case canvasW = "canvas_w"
        case canvasH = "canvas_h"
        case canvasZ = "canvas_z"
    }

    public init(
        id: UUID,
        collectionID: UUID,
        assetID: UUID,
        addedAt: Date,
        manualOrder: Int? = nil,
        canvasX: Double? = nil,
        canvasY: Double? = nil,
        canvasW: Double? = nil,
        canvasH: Double? = nil,
        canvasZ: Int? = nil
    ) {
        self.id = id
        self.collectionID = collectionID
        self.assetID = assetID
        self.addedAt = addedAt
        self.manualOrder = manualOrder
        self.canvasX = canvasX
        self.canvasY = canvasY
        self.canvasW = canvasW
        self.canvasH = canvasH
        self.canvasZ = canvasZ
    }
}
