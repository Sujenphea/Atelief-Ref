// AtelierCore — the saved-search rule vocabulary + codec (015)
//
// A `SearchRules` is the structured, versioned description of a smart collection's
// query. Its fields map 1:1 onto the FILTER arguments of `AppServices.searchAssets`
// — every rule a smart collection can express is a `searchAssets` parameter, and
// nothing here that isn't (015 · "the drift risk lives in the mapping"). The
// exhaustive codec test asserts that mapping so a new `searchAssets` capability
// can't silently drift out of sync with what a saved search can carry.
//
// Deliberately NOT saved as rules (they're evaluation-time, not query identity):
//   • paging (`limit` / `after` cursor) — a scroll position, re-supplied per read;
//   • sort — the grid's display mode (015: default `.newest`, `.manual` excluded),
//     a view concern the V2 grid owns, not a filter. The 044/045 `searchAssets`
//     `sort: .newest | .relevance` argument is this same concern: a saved search
//     defines WHICH assets match, never how they're ORDERED, so `sort` is not a
//     rule field (the codec round-trip test asserts it is unrepresentable);
//   • `tagNameContains` — the live `tag:` type-ahead needle (044/045 · 17A): a
//     transient input-method affordance that resolves to a picked tag TOKEN
//     (→ `tagIDs`, which IS saved) before a search is ever persisted;
//   • plural collection scope — a saved search carries a SINGLE `collectionID`
//     (below); the multi-collection `collectionIDs` search argument (044/045 ·
//     16A) is a live-query affordance, collapsed to `[collectionID]` on evaluate.
//
// Storage is the `saved_search.rules` opaque TEXT column: this codec serializes to
// a stable, versioned JSON blob and back. The `version` field is forward-compatible
// (008-manifest discipline): a newer blob that ADDS fields still decodes what this
// build understands (unknown keys ignored), and unknown enum tokens degrade to
// "conjunct dropped" rather than failing the whole rule (015 · "evaluate what
// parses"). A caller badges `version > currentVersion` to warn that some rules may
// be ignored.

import Foundation

/// The structured, versioned query behind a smart collection (015). Value type;
/// the memberwise `init` and the decoder both NORMALIZE (trim text → nil when
/// empty, de-duplicate tag ids preserving first-seen order) so equal queries
/// written differently share one canonical blob — and `decoded(encoded(x)) == x`.
public struct SearchRules: Sendable, Equatable, Hashable, Codable {

    /// The rule-shape version this build writes. Bump when the shape grows (new
    /// filter dimensions); a stored blob keeps whatever version wrote it.
    public static let currentVersion = 1

    /// The shape version that produced this rule (preserved on decode, so a
    /// consumer can detect a far-future blob and badge it). Fresh rules stamp
    /// ``currentVersion``.
    public var version: Int
    /// Full-text query (provenance OR content OR OCR), or `nil` for no text
    /// filter. Normalized: trimmed, empty → `nil`.
    public var text: String?
    /// Restrict to one capture platform, or `nil` for any.
    public var platform: Platform?
    /// Tags the asset must carry, combined per ``tagMatch``. De-duplicated,
    /// first-seen order preserved. Empty = no tag filter.
    public var tagIDs: [UUID]
    /// How `tagIDs` combine (`.all` narrows, `.any` widens). The `searchAssets`
    /// default is `.all`.
    public var tagMatch: TagMatch
    /// Scope to a single collection's membership, or `nil` for the whole library.
    public var collectionID: UUID?

    /// Explicit, stable JSON keys (the on-disk rule vocabulary).
    public enum CodingKeys: String, CodingKey {
        case version
        case text
        case platform
        case tagIDs = "tag_ids"
        case tagMatch = "tag_match"
        case collectionID = "collection_id"
    }

    public init(
        text: String? = nil,
        platform: Platform? = nil,
        tagIDs: [UUID] = [],
        tagMatch: TagMatch = .all,
        collectionID: UUID? = nil,
        version: Int = SearchRules.currentVersion
    ) {
        self.version = version
        self.text = Self.normalizeText(text)
        self.platform = platform
        self.tagIDs = Self.dedupe(tagIDs)
        self.tagMatch = tagMatch
        self.collectionID = collectionID
    }

    // MARK: - Normalization

    /// Trim and collapse an empty/whitespace-only query to `nil` (mirrors what
    /// `searchAssets` does to `text`, so a saved blank text ≠ a real filter).
    private static func normalizeText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Distinct tag ids, first-seen order preserved (deterministic — `Set` would
    /// scramble the blob and break round-trip equality). `searchAssets` de-dupes
    /// anyway; canonicalizing here keeps the STORED rule canonical too.
    private static func dedupe(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Codec

    /// Serialize to the stable, sorted-key JSON stored in `saved_search.rules`.
    /// Throws only if the value is non-encodable, which this fixed shape never is
    /// (plain scalars) — so in practice it is total; the `throws` lets the write
    /// funnel surface any impossible failure rather than swallow it.
    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // deterministic → golden-file safe
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode a stored rules blob, or `nil` when the JSON is unparseable (corrupt
    /// / not JSON at all) — the caller treats `nil` as "this saved search's rules
    /// can't be read" (badge, don't crash the list). Unknown FUTURE fields are
    /// ignored, and unknown enum tokens degrade to "no filter for that dimension"
    /// (see `init(from:)`), so a far-future-but-well-formed blob decodes to the
    /// subset this build understands rather than returning `nil`.
    public static func decoded(fromJSON json: String) -> SearchRules? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SearchRules.self, from: data)
    }

    /// Tolerant decode (015 · "evaluate what parses"): every field is optional
    /// with a sane default, and the two enum-valued fields (`platform`,
    /// `tagMatch`) decode via their rawValue so an UNKNOWN token from a newer
    /// build drops that dimension (→ `nil` / `.all`) instead of throwing and
    /// nuking the whole rule. Tag ids decode leniently too — a non-UUID string is
    /// skipped rather than fatal. Normalizes exactly like the memberwise init.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let decodedVersion = try c.decodeIfPresent(Int.self, forKey: .version)
        self.version = decodedVersion ?? SearchRules.currentVersion

        self.text = Self.normalizeText(try c.decodeIfPresent(String.self, forKey: .text))

        if let rawPlatform = try c.decodeIfPresent(String.self, forKey: .platform) {
            self.platform = Platform(rawValue: rawPlatform)  // unknown → nil (dropped)
        } else {
            self.platform = nil
        }

        let rawTagIDs = try c.decodeIfPresent([String].self, forKey: .tagIDs) ?? []
        self.tagIDs = Self.dedupe(rawTagIDs.compactMap(UUID.init(uuidString:)))

        if let rawMatch = try c.decodeIfPresent(String.self, forKey: .tagMatch) {
            self.tagMatch = TagMatch(rawValue: rawMatch) ?? .all  // unknown → .all
        } else {
            self.tagMatch = .all
        }

        if let rawCollection = try c.decodeIfPresent(String.self, forKey: .collectionID) {
            self.collectionID = UUID(uuidString: rawCollection)  // non-UUID → nil
        } else {
            self.collectionID = nil
        }
    }
}

public extension SearchRules {
    /// `true` when this rule was written by a NEWER build than the current one, so
    /// some of its dimensions may not be understood here — the card badges it
    /// ("saved by a newer version; some filters may be ignored").
    var referencesUnknownVersion: Bool { version > SearchRules.currentVersion }
}

public extension SavedSearch {
    /// Decode the stored rules JSON at the seam, or `nil` when the blob is corrupt
    /// / unreadable (badge the card, don't break the gallery). Mirrors
    /// `AssetAnalysis.colors` → `ColorSwatch.decodeList`.
    var decodedRules: SearchRules? { SearchRules.decoded(fromJSON: rules) }
}
