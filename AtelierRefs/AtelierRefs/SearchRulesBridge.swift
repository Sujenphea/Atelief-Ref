//
//  SearchRulesBridge.swift
//  AtelierRefs
//
//  099 · 4A — the one crossing between the LIVE query (`LibrarySearchQuery`, the
//  seam `LibrarySearchModel` hands to `searchAssets`) and the STORED rule
//  (`AtelierCore.SearchRules`, the versioned blob in `saved_search.rules`).
//
//  **Why it is one file with two initialisers and not two ad-hoc mappings.**
//  `SearchRules`' own header records the incident this exists to prevent:
//  `favoritesOnly` was added to `searchAssets` in 011 and the rules blob never
//  carried it, so every saved search silently dropped the favorites filter for
//  four docs' worth of work. Nothing failed; the filter just wasn't there. A
//  mapping written twice, at two call sites, is that bug waiting for its second
//  chance. Written once, with an exhaustiveness test standing over it
//  (`SearchRulesBridgeTests`), a field added to either side fails a test the same
//  day rather than going quiet in a blob.
//
//  **What deliberately does NOT cross**, and why each one is a decision rather
//  than an oversight (015; 044/045 · 16A/17A):
//
//    • `tagNameContains` — the live `tag:` type-ahead needle. It is an INPUT
//      METHOD, not a filter: it resolves to a picked tag TOKEN (→ `tagIDs`, which
//      does cross) before any query is ever persisted. Saving it would store a
//      half-typed word as a rule.
//    • plural `collectionIDs` beyond the first — a saved search carries a SINGLE
//      collection scope (015), which `AppServices.evaluate(rules:)` re-expands as
//      `rules.collectionID.map { [$0] } ?? []`. The multi-collection search
//      argument is a live-query affordance. This is ASSERTED by the test suite,
//      not assumed: if `SearchRules` ever grows a plural scope, the assertion
//      names this file.
//    • `sort` — the grid's display mode, not part of what a saved search MEANS
//      (015). `evaluate(rules:)` passes no `sort:` at all, so a saved search runs
//      at `searchAssets`' default; ``LibrarySearchQuery/init(rules:)`` therefore
//      reconstructs `.newest` rather than guessing `.relevance` from the presence
//      of text, so the rebuilt query returns the same rows in the same order the
//      service would have.
//    • `platform` — the reverse gap, and the only one on the RULES side: the
//      search field has no platform chip, so a live query cannot express one.
//      A rule that carries a platform keeps it in storage and evaluates with it
//      through `evaluate(rules:)`; it is only the reconstructed live query that
//      cannot show it. Named in the test's rules-side allowlist so the day a
//      platform token lands in the field, the allowlist entry is what has to go.
//

import AtelierCore
import Foundation

// MARK: - Live query → stored rule

extension SearchRules {
    /// The stored rule for a live query — what "Save this search…" persists.
    ///
    /// `tagMatch` and `colorMatch` are not read off the query because the query
    /// cannot express them: the field ANDs tags and ORs colors, always (see
    /// `LibrarySearchModel.selectedTagIDs` / `selectedColorBuckets`, and 085 · C3
    /// for why picking red then blue reads as "red or blue"). They are pinned to
    /// the live behaviour here, and `SearchRulesBridgeTests` asserts the two
    /// constants against `searchAssets`' own defaults so a changed default cannot
    /// leave saved searches quietly matching something else.
    ///
    /// Normalization (trim text → nil when blank, de-duplicate ids first-seen)
    /// happens inside `SearchRules.init`, so a query built from a half-typed field
    /// stores the same canonical blob as one built from a tidy one.
    init(query: LibrarySearchQuery) {
        self.init(
            text: query.text,
            // The live field has no platform affordance; a rule made from a live
            // query therefore has no platform. See the header.
            platform: nil,
            tagIDs: query.tagIDs,
            tagMatch: .all,
            // 015: single-collection scope. `.first` is the rule, and it is the
            // rule the test asserts rather than a convenience — a two-collection
            // live scope saves as its FIRST scope, and the caller that offers
            // "Save this search…" is the one that must decide whether to warn.
            collectionID: query.collectionIDs.first,
            favoritesOnly: query.favoritesOnly,
            colorBuckets: query.colorBuckets,
            colorMatch: .any)
    }
}

// MARK: - Stored rule → live query

extension LibrarySearchQuery {
    /// The live query for a stored rule — what opening a smart collection runs,
    /// and what re-editing one seeds the search field with.
    ///
    /// Runs the same filters `AppServices.evaluate(rules:)` would, in the same
    /// order, so the two paths cannot return different sets for one rule. What it
    /// cannot carry is named in the header: the needle, the plural scope, the
    /// sort, and (on the way back) the platform.
    init(rules: SearchRules) {
        self.init(
            text: rules.text ?? "",
            tagIDs: rules.tagIDs,
            // Not a filter — an input-method affordance (044/045 · 17A). A rule
            // never carries one, so a query rebuilt from a rule never has one.
            tagNameContains: nil,
            collectionIDs: rules.collectionID.map { [$0] } ?? [],
            favoritesOnly: rules.favoritesOnly,
            colorBuckets: rules.colorBuckets,
            // `evaluate(rules:)` passes no sort, so a saved search runs at
            // `searchAssets`' default. Reconstructing `.relevance` from non-empty
            // text — which is what the LIVE field does — would make the rebuilt
            // query order differently from the service that owns the rule.
            sort: .newest)
    }
}
