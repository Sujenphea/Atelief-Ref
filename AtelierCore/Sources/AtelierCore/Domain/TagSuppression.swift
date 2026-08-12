// AtelierCore — a refused tag suggestion (012 · I3)
//
// The memory half of suggest-and-confirm. Accepting a suggestion leaves an
// ordinary `.user` tag behind and needs no record of its own; DISMISSING one has
// to leave something, because the evidence that produced the suggestion — the
// image — does not change when the user says no. Without this row the next
// suggester pass reads the same pixels, reaches the same label, and re-applies
// what was just refused.
//
// Keyed on the tag NAME, not on a `tag.id`. Dismissing unlinks the asset from the
// `.agent` tag, and a tag row nothing points at is not kept alive on this
// suppression's behalf; a foreign key would therefore have to either resurrect
// the tag or cascade the refusal away. The name is the durable identity here, and
// it is stored NORMALIZED (`Validation.tagName` — trimmed, leading `#` stripped)
// so it matches what a suggester would apply, character for character.
//
// Plain value type (mirrors `AssetColor` / `AssetAnalysis`): the GRDB conformance
// lives in `Persistence/TagSuppression+GRDB.swift`, the mutation funnel in
// `AppServices`.

import Foundation

/// One (asset, tag name) pair the user has refused as a suggestion.
///
/// Scoped per asset deliberately: refusing "poster" on one screenshot says
/// nothing about the next one. A library-wide never-suggest list would be a
/// separate, coarser thing.
public struct TagSuppression: Sendable, Equatable, Hashable, Codable {
    /// The asset the refusal is about (FK → `asset.id`, CASCADE).
    public var assetID: UUID
    /// The normalized tag name that must not be suggested again for this asset.
    public var tagName: String
    /// When the user dismissed it.
    public var suppressedAt: Date

    /// Explicit snake_case column/coding names (exact acronym mapping).
    public enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case tagName = "tag_name"
        case suppressedAt = "suppressed_at"
    }

    public init(assetID: UUID, tagName: String, suppressedAt: Date) {
        self.assetID = assetID
        self.tagName = tagName
        self.suppressedAt = suppressedAt
    }
}
