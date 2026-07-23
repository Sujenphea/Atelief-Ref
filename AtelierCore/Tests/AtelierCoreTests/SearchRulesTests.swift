// AtelierCore — saved-search rules codec (015)
//
// The versioned `SearchRules` blob is the drift-risk surface: it must serialize
// every filter dimension losslessly, canonicalize equal-but-differently-written
// rules to one blob, and survive a NEWER build's extra fields / unknown enum
// tokens without failing the whole rule (015 · "evaluate what parses"). These are
// pure value tests — no database.

import Foundation
import Testing
@testable import AtelierCore

@Suite("SearchRules: codec")
struct SearchRulesCodecTests {

    /// Encode → decode returns an equal value.
    private func assertRoundTrips(_ rules: SearchRules, _ comment: Comment? = nil) throws {
        let json = try rules.encoded()
        let back = try #require(SearchRules.decoded(fromJSON: json), comment)
        #expect(back == rules, comment)
    }

    // MARK: - Round-trips

    @Test("an empty rule (whole library) round-trips")
    func emptyRoundTrips() throws {
        try assertRoundTrips(SearchRules())
    }

    @Test("a fully-populated rule round-trips every field")
    func fullRoundTrips() throws {
        let rules = SearchRules(
            text: "editorial grid",
            platform: .pinterest,
            tagIDs: [UUID(), UUID(), UUID()],
            tagMatch: .any,
            collectionID: UUID())
        try assertRoundTrips(rules)
    }

    @Test("each platform value round-trips (rawValue token is stable)")
    func everyPlatformRoundTrips() throws {
        for platform in Platform.allCases {
            try assertRoundTrips(SearchRules(platform: platform), "platform \(platform)")
        }
    }

    @Test("each tag-match mode round-trips")
    func everyTagMatchRoundTrips() throws {
        for match in TagMatch.allCases {
            try assertRoundTrips(SearchRules(tagMatch: match), "match \(match)")
        }
    }

    @Test("each single filter dimension round-trips in isolation (the 1:1 matrix)")
    func eachDimensionRoundTrips() throws {
        try assertRoundTrips(SearchRules(text: "helvetica"))
        try assertRoundTrips(SearchRules(platform: .twitter))
        try assertRoundTrips(SearchRules(tagIDs: [UUID()]))
        try assertRoundTrips(SearchRules(tagMatch: .any))
        try assertRoundTrips(SearchRules(collectionID: UUID()))
    }

    // MARK: - Normalization (canonical blobs)

    @Test("text is trimmed on construction")
    func textTrimmed() {
        #expect(SearchRules(text: "  spacing  ").text == "spacing")
    }

    @Test("empty / whitespace-only text collapses to nil (not a real filter)")
    func blankTextIsNil() {
        #expect(SearchRules(text: "").text == nil)
        #expect(SearchRules(text: "   \n ").text == nil)
        #expect(SearchRules(text: nil).text == nil)
    }

    @Test("duplicate tag ids are removed, first-seen order preserved")
    func tagIDsDeduped() {
        let a = UUID(), b = UUID()
        #expect(SearchRules(tagIDs: [a, b, a, b, a]).tagIDs == [a, b])
    }

    @Test("normalization makes equal-but-differently-written rules one canonical blob")
    func canonicalBlob() throws {
        let a = UUID(), b = UUID()
        let x = try SearchRules(text: "  ui ", tagIDs: [a, b, a]).encoded()
        let y = try SearchRules(text: "ui", tagIDs: [a, b]).encoded()
        #expect(x == y)
    }

    // MARK: - Determinism

    @Test("encoding is deterministic (sorted keys) — a rule serializes identically twice")
    func deterministicEncoding() throws {
        let rules = SearchRules(text: "brutalist", platform: .cosmos, tagMatch: .any)
        #expect(try rules.encoded() == (try rules.encoded()))
    }

    @Test("enum fields serialize as their rawValue token, not a nested object")
    func enumsAsRawTokens() throws {
        let json = try SearchRules(platform: .localPaste, tagMatch: .any).encoded()
        #expect(json.contains("\"platform\":\"local_paste\""))
        #expect(json.contains("\"tag_match\":\"any\""))
    }

    /// The stored rule vocabulary is EXACTLY these keys — the drift guard (015 ·
    /// "the drift risk lives in the mapping"). A saved search defines WHICH assets
    /// match, never how a live search is ordered or its input-method sugar, so the
    /// 044/045 `searchAssets` arguments `sort`, `tagNameContains`, and plural
    /// `collectionIDs` are deliberately NOT rule fields (8A). Pinning the key set
    /// makes any future attempt to serialize one of them fail loudly here.
    @Test("the rule blob carries exactly the saved dimensions — no sort / tag: / plural scope")
    func ruleVocabularyIsExactlyTheSavedDimensions() throws {
        // A fully-populated rule so every representable key appears.
        let json = try SearchRules(
            text: "grid", platform: .pinterest, tagIDs: [UUID()],
            tagMatch: .all, collectionID: UUID()).encoded()
        let keys = Set(try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        ).keys)
        #expect(keys == ["version", "text", "platform", "tag_ids",
                         "tag_match", "collection_id"])
        // The excluded live-search concepts have no on-disk token.
        for excluded in ["sort", "tag_name_contains", "collection_ids"] {
            #expect(!keys.contains(excluded), "unexpected rule key: \(excluded)")
        }
    }

    // MARK: - Version

    @Test("a fresh rule is stamped with the current version")
    func freshStampsCurrentVersion() {
        #expect(SearchRules().version == SearchRules.currentVersion)
        #expect(SearchRules().referencesUnknownVersion == false)
    }

    @Test("decode preserves the stored version (so a newer blob can be badged)")
    func versionPreservedOnDecode() throws {
        let future = #"{"version":999,"tag_match":"all","tag_ids":[]}"#
        let rules = try #require(SearchRules.decoded(fromJSON: future))
        #expect(rules.version == 999)
        #expect(rules.referencesUnknownVersion)
    }

    // MARK: - Forward / backward compatibility ("evaluate what parses")

    @Test("a newer blob with unknown extra fields decodes the subset we understand")
    func unknownFieldsIgnored() throws {
        let tag = UUID()
        let future = """
        {"version":2,"text":"grid","platform":"pinterest","tag_ids":["\(tag.uuidString.lowercased())"],\
        "tag_match":"any","collection_id":null,"favorite":true,"color":"#ff0000"}
        """
        let rules = try #require(SearchRules.decoded(fromJSON: future))
        #expect(rules.version == 2)
        #expect(rules.text == "grid")
        #expect(rules.platform == .pinterest)
        #expect(rules.tagIDs == [tag])
        #expect(rules.tagMatch == .any)
        #expect(rules.collectionID == nil)
    }

    @Test("missing fields fall back to sane defaults (no filter / .all / current version)")
    func missingFieldsDefault() throws {
        let rules = try #require(SearchRules.decoded(fromJSON: "{}"))
        #expect(rules.version == SearchRules.currentVersion)
        #expect(rules.text == nil)
        #expect(rules.platform == nil)
        #expect(rules.tagIDs.isEmpty)
        #expect(rules.tagMatch == .all)
        #expect(rules.collectionID == nil)
    }

    @Test("an unknown platform token drops that dimension rather than failing the rule")
    func unknownPlatformDropped() throws {
        let blob = #"{"version":2,"platform":"tiktok","tag_match":"all","tag_ids":[]}"#
        let rules = try #require(SearchRules.decoded(fromJSON: blob))
        #expect(rules.platform == nil)  // dropped, rule still usable
    }

    @Test("an unknown tag-match token degrades to .all")
    func unknownTagMatchDefaults() throws {
        let blob = #"{"version":2,"tag_match":"most","tag_ids":[]}"#
        let rules = try #require(SearchRules.decoded(fromJSON: blob))
        #expect(rules.tagMatch == .all)
    }

    @Test("a non-UUID tag id is skipped, not fatal")
    func invalidTagIDSkipped() throws {
        let good = UUID()
        let blob = #"{"tag_ids":["not-a-uuid","\#(good.uuidString.lowercased())"],"tag_match":"all"}"#
        let rules = try #require(SearchRules.decoded(fromJSON: blob))
        #expect(rules.tagIDs == [good])
    }

    // MARK: - Corrupt input

    @Test("unparseable JSON decodes to nil (badge, don't crash)")
    func corruptIsNil() {
        #expect(SearchRules.decoded(fromJSON: "not json at all") == nil)
        #expect(SearchRules.decoded(fromJSON: "") == nil)
        #expect(SearchRules.decoded(fromJSON: "[1,2,3]") == nil)  // wrong root type
    }
}
