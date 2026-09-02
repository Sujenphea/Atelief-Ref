//
//  SearchRulesBridgeTests.swift
//  AtelierRefsTests
//
//  099 · 4A — the two initialisers in `SearchRulesBridge.swift`, and the canary
//  that keeps them honest.
//
//  The canary is the reason this file exists. `SearchRules`' header records what
//  happened without one: `favoritesOnly` was added to `searchAssets` in 011, the
//  rules blob never carried it, and every saved search silently dropped the
//  favorites filter. Nothing threw, no test failed, and the filter was simply not
//  there. `exhaustiveness` below is the assertion that would have failed on the
//  commit that added the field: a `Mirror` over each side lists its stored
//  properties, and every one must be either MAPPED by the bridge or named in an
//  explicit allowlist with a reason. A new field is in neither, so the test fails
//  until someone decides which it is.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing

@testable import AtelierRefs

@Suite("SearchRules ↔ LibrarySearchQuery (099 · 4A)")
struct SearchRulesBridgeTests {

    // MARK: - Fixtures

    private static let tagA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let tagB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let collectionA = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let collectionB = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    /// Every dimension a rule can carry, all set to something non-default, and
    /// nothing set that a rule cannot carry — so `query → rules → query` is an
    /// identity and any loss is a bug rather than a documented drop.
    private static let fullyPopulated = LibrarySearchQuery(
        text: "brutalist concrete",
        tagIDs: [tagA, tagB],
        tagNameContains: nil,
        collectionIDs: [collectionA],
        favoritesOnly: true,
        colorBuckets: [ColorBucket.red.rawValue, ColorBucket.blue.rawValue],
        sort: .newest)

    // MARK: - Round trip

    @Test("a fully-populated query survives query → rules → query")
    func roundTrip() {
        let rules = SearchRules(query: Self.fullyPopulated)
        let restored = LibrarySearchQuery(rules: rules)
        #expect(restored == Self.fullyPopulated)
    }

    @Test("the rule the round trip goes through carries every dimension")
    func roundTripRuleIsPopulated() {
        // Guards the round trip against passing vacuously: an identity through a
        // rule that dropped everything and a query that re-derived nothing would
        // still be an identity if the query were empty. It is not.
        let rules = SearchRules(query: Self.fullyPopulated)
        #expect(rules.text == "brutalist concrete")
        #expect(rules.tagIDs == [Self.tagA, Self.tagB])
        #expect(rules.tagMatch == .all)
        #expect(rules.collectionID == Self.collectionA)
        #expect(rules.favoritesOnly)
        #expect(rules.colorBuckets == [ColorBucket.red.rawValue, ColorBucket.blue.rawValue])
        #expect(rules.colorMatch == .any)
        #expect(rules.version == SearchRules.currentVersion)
    }

    @Test("the round trip survives the STORED form, not just the in-memory one")
    func roundTripThroughTheBlob() throws {
        // The blob is what a saved search actually holds, and the codec normalizes
        // on the way through. A bridge that round-trips in memory but writes a
        // field the codec has no key for would pass the test above and lose the
        // field on the first relaunch.
        let rules = SearchRules(query: Self.fullyPopulated)
        let decoded = try #require(SearchRules.decoded(fromJSON: rules.encoded()))
        #expect(LibrarySearchQuery(rules: decoded) == Self.fullyPopulated)
    }

    @Test("an empty query and an empty rule are each other's image")
    func emptyRoundTrip() {
        let empty = LibrarySearchQuery(
            text: "", tagIDs: [], tagNameContains: nil, collectionIDs: [],
            favoritesOnly: false, colorBuckets: [], sort: .newest)
        let rules = SearchRules(query: empty)
        #expect(rules.text == nil, "a blank text is not a filter — the codec nils it")
        #expect(LibrarySearchQuery(rules: rules) == empty)
    }

    @Test("blank-but-not-empty text normalizes to no text filter")
    func whitespaceTextIsNotAFilter() {
        let padded = LibrarySearchQuery(
            text: "   \n ", tagIDs: [], tagNameContains: nil, collectionIDs: [],
            favoritesOnly: false, colorBuckets: [], sort: .newest)
        #expect(SearchRules(query: padded).text == nil)
        #expect(LibrarySearchQuery(rules: SearchRules(query: padded)).text == "")
    }

    // MARK: - The three drops, each asserted rather than assumed

    @Test("the tag: needle is an input method, and does not persist")
    func tagNameContainsIsDropped() {
        var query = Self.fullyPopulated
        query.tagNameContains = "arch"
        // Same rule as the query without the needle: it changes nothing stored.
        #expect(SearchRules(query: query) == SearchRules(query: Self.fullyPopulated))
        #expect(LibrarySearchQuery(rules: SearchRules(query: query)).tagNameContains == nil)
    }

    @Test("a saved search is single-collection: the plural scope collapses to the first")
    func pluralScopeCollapses() {
        // 015's rule, ASSERTED. `AppServices.evaluate(rules:)` re-expands the single
        // id as `[collectionID]`, so a saved two-collection scope has nowhere to go
        // in the service either — the loss is at the storage shape, not here.
        var query = Self.fullyPopulated
        query.collectionIDs = [Self.collectionA, Self.collectionB]
        let rules = SearchRules(query: query)
        #expect(rules.collectionID == Self.collectionA)
        #expect(LibrarySearchQuery(rules: rules).collectionIDs == [Self.collectionA])
    }

    @Test("SearchRules has no plural collection scope to save into")
    func rulesHaveNoPluralScope() {
        // The other half of the assertion above: the collapse is forced by the
        // stored shape. If `SearchRules` ever grows a plural scope, this fails and
        // names the bridge as the thing to revisit.
        let labels = Set(Mirror(reflecting: SearchRules()).children.compactMap(\.label))
        #expect(labels.contains("collectionID"))
        #expect(!labels.contains("collectionIDs"))
    }

    @Test("sort is the grid's display mode, not part of the rule", arguments: [
        SearchSort.newest, SearchSort.relevance,
    ])
    func sortIsNotARule(_ sort: SearchSort) {
        var query = Self.fullyPopulated
        query.sort = sort
        // Both sorts store the same rule …
        #expect(SearchRules(query: query) == SearchRules(query: Self.fullyPopulated))
        // … and a rule always rebuilds `.newest`, because `evaluate(rules:)`
        // passes no sort and `searchAssets` defaults to `.newest`.
        #expect(LibrarySearchQuery(rules: SearchRules(query: query)).sort == .newest)
    }

    @Test("a rule's platform survives storage but cannot reach the live query")
    func platformIsRuleOnly() {
        // The reverse gap, named in the bridge header: the search field has no
        // platform chip. The rule keeps it — `evaluate(rules:)` still filters on
        // it — and only the RECONSTRUCTED live query is without it. The day a
        // platform token lands in the field, this test is what has to change.
        let rules = SearchRules(platform: .pinterest, tagIDs: [Self.tagA])
        let query = LibrarySearchQuery(rules: rules)
        #expect(query.tagIDs == [Self.tagA])
        #expect(SearchRules(query: query).platform == nil,
                "re-saving a platform rule from the live field would silently drop it")
    }

    // MARK: - The match modes are pinned to the live behaviour

    @Test("tags AND and colors OR, matching the field and searchAssets' defaults")
    func matchModesArePinned() {
        let rules = SearchRules(query: Self.fullyPopulated)
        // The live field ANDs tag tokens and ORs color tokens (085 · C3). These two
        // constants are the only fields the bridge invents rather than copies, so
        // they are pinned against what the service does by default.
        #expect(rules.tagMatch == .all)
        #expect(rules.colorMatch == .any)
        #expect(SearchRules().tagMatch == .all)
        #expect(SearchRules().colorMatch == .any)
    }

    @Test("a rule written with the other match modes still rebuilds a runnable query")
    func exoticMatchModesDegradeRatherThanCrash() {
        // Nothing in the app writes these today, but a hand-edited blob or a newer
        // build can. The live query has no field for them, so they are simply not
        // reachable from the reconstructed query — it must not lose the tags too.
        let rules = SearchRules(
            tagIDs: [Self.tagA, Self.tagB], tagMatch: .any,
            colorBuckets: [ColorBucket.red.rawValue], colorMatch: .all)
        let query = LibrarySearchQuery(rules: rules)
        #expect(query.tagIDs == [Self.tagA, Self.tagB])
        #expect(query.colorBuckets == [ColorBucket.red.rawValue])
    }

    // MARK: - Exhaustiveness — the canary

    /// Every stored property of `LibrarySearchQuery` the bridge reads or writes.
    private static let queryMapped: Set<String> = [
        "text", "tagIDs", "collectionIDs", "favoritesOnly", "colorBuckets",
    ]

    /// Every stored property of `LibrarySearchQuery` the bridge deliberately does
    /// NOT persist. Each entry is a decision recorded in `SearchRulesBridge.swift`'s
    /// header; adding one here without adding it there is how this canary dies.
    private static let queryNotPersisted: Set<String> = [
        "tagNameContains",  // 044/045 · 17A — an input method, not a filter
        "sort",             // 015 — the grid's display mode, not query identity
    ]

    /// Every stored property of `SearchRules` the bridge reads or writes.
    private static let rulesMapped: Set<String> = [
        "text", "tagIDs", "tagMatch", "collectionID", "favoritesOnly",
        "colorBuckets", "colorMatch",
    ]

    /// Every stored property of `SearchRules` that has no live-query counterpart.
    private static let rulesNotRepresentable: Set<String> = [
        "version",   // the blob's own shape stamp; `SearchRules.init` sets it
        "platform",  // no platform chip in the search field — see `platformIsRuleOnly`
    ]

    @Test("every stored property of both sides is mapped or explicitly allowlisted")
    func exhaustiveness() {
        // `collectionIDs` counts as MAPPED even though only its first element
        // crosses: the field is read, and the lossy half is `pluralScopeCollapses`'
        // business, not this one's. A field the bridge never touches is the thing
        // this test is looking for.
        assertExhaustive(
            over: Self.fullyPopulated,
            named: "LibrarySearchQuery",
            mapped: Self.queryMapped,
            allowlisted: Self.queryNotPersisted)

        assertExhaustive(
            over: SearchRules(),
            named: "SearchRules",
            mapped: Self.rulesMapped,
            allowlisted: Self.rulesNotRepresentable)
    }

    /// The canary's body: reflect, subtract, and fail with the field's NAME so the
    /// failure tells the next person exactly what they added and where to decide
    /// about it.
    private func assertExhaustive<T>(
        over value: T, named type: String, mapped: Set<String>, allowlisted: Set<String>
    ) {
        let stored = Set(Mirror(reflecting: value).children.compactMap(\.label))
        #expect(!stored.isEmpty, "\(type) reflected no stored properties at all")

        let accounted = mapped.union(allowlisted)
        let unaccounted = stored.subtracting(accounted)
        #expect(unaccounted.isEmpty, """
            \(type) grew \(unaccounted.sorted().joined(separator: ", ")). \
            Either map it in SearchRulesBridge.swift, or add it to the allowlist \
            in SearchRulesBridgeTests with the reason it cannot cross.
            """)

        let stale = accounted.subtracting(stored)
        #expect(stale.isEmpty, """
            \(type) no longer has \(stale.sorted().joined(separator: ", ")); \
            the bridge's lists name a field that is gone.
            """)
    }
}
