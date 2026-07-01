// AtelierCore — Collection
//
// Mirrors 003 §data-model · Collection exactly. A plain value type: no
// persistence, no validation (name trim/reject lives in the funnel, C8).

import Foundation

/// A named grouping — the unit of organization in the library (003
/// §data-model). Having its own `id` keeps a future `parentCollectionID` or
/// saved-query collection additive.
public struct Collection: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// The fixed, well-known id of the protected "Unsorted" folder.
    ///
    /// Seeded by the v2 migration as the guaranteed default import target
    /// (decision F3). It is undeletable / unrenamable / unreparentable — those
    /// guards live in `AppServices` (chunk 2). A stable literal so every install
    /// resolves the same folder regardless of migration timing.
    public static let unsortedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Stable identity.
    public var id: UUID
    /// Display name.
    public var name: String
    /// Optional longer description.
    public var description: String?
    /// FK → ``Asset``. Optional cover thumbnail.
    public var coverAssetID: UUID?
    /// When created.
    public var createdAt: Date
    /// When last modified.
    public var updatedAt: Date
    /// FK → parent ``Collection`` (decision F1). `nil` = a root folder.
    public var parentCollectionID: UUID?

    /// Explicit snake_case column/coding names (exact acronym mapping, e.g.
    /// `coverAssetID` ⇄ `cover_asset_id`).
    public enum CodingKeys: String, CodingKey {
        case id, name, description
        case coverAssetID = "cover_asset_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case parentCollectionID = "parent_collection_id"
    }

    public init(
        id: UUID,
        name: String,
        description: String? = nil,
        coverAssetID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date,
        parentCollectionID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.coverAssetID = coverAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentCollectionID = parentCollectionID
    }
}
