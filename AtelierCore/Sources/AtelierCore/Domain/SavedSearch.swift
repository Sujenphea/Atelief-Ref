// AtelierCore — a smart collection: a saved search (015)
//
// A smart collection IS a saved query (015): rules like "platform:pinterest AND
// tag:ui" persisted as an entity, evaluated LIVE against `searchAssets` every
// time it opens (never materialized — no membership rows, no GC, never stale).
//
// This layer treats `rules` as OPAQUE versioned JSON, exactly as `AssetAnalysis`
// treats `colors`: the `SearchRules` codec (in the Services layer, which owns the
// query vocabulary — `Platform`, `TagMatch`) serializes the structured rule to
// JSON and back at the seam. Keeping the rule shape out of the domain record lets
// listing saved searches never fail on a corrupt or far-future blob — decode is
// per-search, at open time, where a failure badges the card instead of breaking
// the whole gallery (015 · "evaluate what parses").
//
// Plain value type, mirroring `Collection` / `AssetAnalysis`: no persistence, no
// validation here; the GRDB conformance lives in `Persistence/SavedSearch+GRDB`
// (A1) and the mutation funnel in `AppServices` (A4).

import Foundation

/// One smart collection — a named, saved search (015). `rules` is the versioned
/// JSON of the query; decode it with `SearchRules.decoded(fromJSON:)` (the
/// `decodedRules` convenience lives in the Services layer, where `SearchRules` is).
public struct SavedSearch: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity (also the primary key).
    public var id: UUID
    /// User-facing name (trimmed, non-empty — enforced by the funnel).
    public var name: String
    /// The query as opaque versioned JSON (the `SearchRules` codec owns the
    /// shape). NOT NULL: every saved search carries a rule, even an empty one
    /// ("the whole library").
    public var rules: String
    /// When the search was first saved.
    public var createdAt: Date
    /// Last time the name or rules changed (a re-save bumps this).
    public var updatedAt: Date

    /// Explicit snake_case column/coding names (exact mapping — no acronyms here,
    /// but explicit for consistency with the rest of the schema).
    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case rules
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        name: String,
        rules: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.rules = rules
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
