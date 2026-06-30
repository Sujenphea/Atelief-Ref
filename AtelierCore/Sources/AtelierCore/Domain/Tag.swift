// AtelierCore — Tag + AssetTag
//
// Mirrors 003 §data-model · Tag (and its join table). Schema-reserved in the
// MVP: the agent interface needs them later (006 scope). Plain value types: no
// persistence, no validation.

import Foundation

/// A free-form label for cross-collection filtering and agent-written
/// organization (003 §data-model). `source` distinguishes user vs agent tags so
/// agent work stays reviewable and reversible.
public struct Tag: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity.
    public var id: UUID
    /// The label text.
    public var name: String
    /// `user` | `agent` — who applied it.
    public var source: TagSource

    public init(id: UUID, name: String, source: TagSource) {
        self.id = id
        self.name = name
        self.source = source
    }
}

/// The many-to-many join row linking an ``Asset`` to a ``Tag`` (003
/// §data-model · `AssetTag(asset_id, tag_id)`). Reserved alongside ``Tag``; it
/// has no `id` of its own — the pair is the identity.
public struct AssetTag: Sendable, Equatable, Hashable, Codable {
    /// FK → ``Asset``.
    public var assetID: UUID
    /// FK → ``Tag``.
    public var tagID: UUID

    public init(assetID: UUID, tagID: UUID) {
        self.assetID = assetID
        self.tagID = tagID
    }
}
