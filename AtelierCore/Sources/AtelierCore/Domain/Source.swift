// AtelierCore — Source
//
// Mirrors 003 §data-model · Source exactly. A plain value type: no persistence,
// no validation (per-platform `originalURL` rules live in the funnel, C8).

import Foundation

/// The origin of an ``Asset`` — first-class and required (003 §data-model).
///
/// Many assets can share one source (a post with several images); every asset
/// has exactly one source.
public struct Source: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity.
    public var id: UUID
    /// Which platform / capture path this came from.
    public var platform: Platform
    /// The canonical link back to the post. Critical provenance.
    public var originalURL: String?
    /// e.g. `@designer`.
    public var authorHandle: String?
    /// Display name.
    public var authorName: String?
    /// Post title / caption excerpt.
    public var title: String?
    /// When ingested.
    public var capturedAt: Date
    /// Platform-specific extras, preserved verbatim (Pinterest board, tweet id,
    /// IG shortcode, Cosmos cluster) — the escape hatch against schema churn.
    public var rawMetadata: JSONValue

    /// Explicit snake_case column/coding names (exact acronym mapping, e.g.
    /// `originalURL` ⇄ `original_url`).
    public enum CodingKeys: String, CodingKey {
        case id, platform
        case originalURL = "original_url"
        case authorHandle = "author_handle"
        case authorName = "author_name"
        case title
        case capturedAt = "captured_at"
        case rawMetadata = "raw_metadata"
    }

    public init(
        id: UUID,
        platform: Platform,
        originalURL: String? = nil,
        authorHandle: String? = nil,
        authorName: String? = nil,
        title: String? = nil,
        capturedAt: Date,
        rawMetadata: JSONValue = .object([:])
    ) {
        self.id = id
        self.platform = platform
        self.originalURL = originalURL
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.title = title
        self.capturedAt = capturedAt
        self.rawMetadata = rawMetadata
    }
}
