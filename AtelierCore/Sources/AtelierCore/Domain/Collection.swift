// AtelierCore — Collection
//
// Mirrors 003 §data-model · Collection exactly. A plain value type: no
// persistence, no validation (name trim/reject lives in the funnel, C8).

import Foundation

/// A named grouping — the unit of organization in the library (003
/// §data-model). Having its own `id` keeps a future `parentCollectionID` or
/// saved-query collection additive.
public struct Collection: Sendable, Equatable, Hashable, Codable, Identifiable {
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

    public init(
        id: UUID,
        name: String,
        description: String? = nil,
        coverAssetID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.coverAssetID = coverAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
