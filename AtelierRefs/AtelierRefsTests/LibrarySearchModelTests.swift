//
//  LibrarySearchModelTests.swift
//  AtelierRefsTests
//
//  007 G2 — the search model's state machine (deterministic, no async query):
//  when a search is "active", when the scope toggle shows, and the default
//  scope a Collection screen adopts. The query itself is thin glue over the
//  G1-tested `searchAssets`; here we pin the surrounding logic.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("LibrarySearchModel state (007 G2)")
struct LibrarySearchModelTests {

    private func token(_ name: String, _ source: TagSource = .user) -> SearchToken {
        .tag(Tag(id: UUID(), name: name, source: source))
    }

    @Test("isActive follows text and tokens")
    func isActive() {
        let m = LibrarySearchModel()
        #expect(!m.isActive)                      // empty
        m.text = "   "
        #expect(!m.isActive)                      // whitespace only
        m.text = "brass"
        #expect(m.isActive)
        m.text = ""
        m.tokens = [token("wood")]
        #expect(m.isActive)                       // a token alone activates
    }

    @Test("scope toggle only shows on a collection-scoped screen")
    func scopeToggle() {
        let global = LibrarySearchModel()
        global.configure(services: nil, collectionID: nil)
        #expect(!global.showsScopeToggle)

        let scoped = LibrarySearchModel()
        scoped.configure(services: nil, collectionID: UUID())
        #expect(scoped.showsScopeToggle)
    }

    @Test("a Collection screen defaults its scope to This Collection")
    func defaultScope() {
        let m = LibrarySearchModel()
        #expect(m.scope == .all)                  // fresh default
        m.configure(services: nil, collectionID: UUID())
        #expect(m.scope == .thisCollection)       // collection screen scopes to itself
    }

    @Test("configuring the global gallery leaves scope at All")
    func globalScopeStaysAll() {
        let m = LibrarySearchModel()
        m.configure(services: nil, collectionID: nil)
        #expect(m.scope == .all)
    }

    @Test("reset clears text, tokens, and results")
    func reset() {
        let m = LibrarySearchModel()
        m.text = "brass"; m.tokens = [token("wood")]
        m.reset()
        #expect(m.text.isEmpty)
        #expect(m.tokens.isEmpty)
        #expect(!m.isActive)
    }

    // MARK: - `tag:` query parsing (044/045 · 17A)

    @Test("plain text is FTS text with no tag needle, preserving trailing space")
    func parsePlainText() {
        #expect(LibrarySearchModel.parse(query: "chair").fts == "chair")
        #expect(LibrarySearchModel.parse(query: "chair").tagNeedle == nil)
        // Trailing space must survive (drives the exact-vs-prefix rule downstream).
        #expect(LibrarySearchModel.parse(query: "chair ").fts == "chair ")
    }

    @Test("a leading tag: directive routes the remainder to the tag needle, no FTS")
    func parseTagDirective() {
        let parsed = LibrarySearchModel.parse(query: "tag:brut")
        #expect(parsed.fts.isEmpty)
        #expect(parsed.tagNeedle == "brut")
    }

    @Test("tag: parsing ignores leading whitespace and is case-insensitive")
    func parseTagDirectiveLenient() {
        #expect(LibrarySearchModel.parse(query: "  TAG:Foo").tagNeedle == "Foo")
        #expect(LibrarySearchModel.parse(query: "  Tag:  bar ").tagNeedle == "bar")
    }

    @Test("an empty tag: directive has no needle (inert, not match-everything)")
    func parseEmptyTagDirective() {
        #expect(LibrarySearchModel.parse(query: "tag:").tagNeedle == nil)
        #expect(LibrarySearchModel.parse(query: "tag:   ").tagNeedle == nil)
    }

    // MARK: - Query seam (044/045 · 12A)

    /// Records what the model asked its injected seams to do.
    @MainActor private final class Recorder {
        var queries: [LibrarySearchQuery] = []
        var semanticQueries: [LibrarySearchQuery] = []
        var suggestCalls: [(prefix: String, includeCollections: Bool)] = []
    }

    /// Poll a main-actor condition until true or a bounded timeout (the model's
    /// query/suggestion Tasks are debounced ~220/120ms, so a fixed wait would be
    /// either flaky or slow; polling settles as soon as the Task lands).
    private func poll(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a query failure sets queryFailed and clears results")
    func queryFailureSetsFlag() async {
        let m = LibrarySearchModel()
        m.runQuery = { _ in throw AtelierError.persistenceFailure(detail: "boom") }
        m.text = "brass"
        m.textChanged()
        await poll { m.queryFailed }
        #expect(m.queryFailed)
        #expect(m.results.isEmpty)
    }

    @Test("a successful query clears a prior failure flag")
    func successClearsFailureFlag() async {
        let m = LibrarySearchModel()
        m.runQuery = { _ in throw AtelierError.persistenceFailure(detail: "boom") }
        m.text = "brass"; m.textChanged()
        await poll { m.queryFailed }

        m.runQuery = { _ in [] }
        m.text = "brasss"; m.textChanged()
        await poll { !m.queryFailed && !m.isRunning }
        #expect(!m.queryFailed)
    }

    @Test("free text builds a .relevance query carrying the tag-token ids")
    func buildsRelevanceQueryWithTokens() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        let wood = token("wood")
        m.tokens = [wood]
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.queries.isEmpty }

        let q = recorder.queries.last
        #expect(q?.text == "brass")
        #expect(q?.sort == .relevance)
        #expect(q?.tagIDs == [wood.id])
        #expect(q?.tagNameContains == nil)
    }

    @Test("a tag: directive builds a tagNameContains query with .newest sort, no FTS")
    func buildsTagNeedleQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.text = "tag:brut"
        m.textChanged()
        await poll { !recorder.queries.isEmpty }

        let q = recorder.queries.last
        #expect(q?.text.isEmpty == true)
        #expect(q?.tagNameContains == "brut")
        #expect(q?.sort == .newest)  // nothing to rank
    }

    @Test("This-collection scope folds the screen collection into collectionIDs")
    func thisCollectionScopeAddsScreenCollection() async {
        let recorder = Recorder()
        let screen = UUID()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.configure(services: nil, collectionID: screen)  // defaults to .thisCollection
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.queries.isEmpty }

        let q = recorder.queries.last
        #expect(q?.collectionIDs == [screen])
    }

    @Test("rapid retype cancels the stale query — only the latest runs")
    func rapidRetypeCoalesces() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.text = "a"; m.textChanged()
        m.text = "ab"; m.textChanged()
        m.text = "abc"; m.textChanged()
        await poll { !recorder.queries.isEmpty }
        // Let any stragglers land, then assert only the final query ran.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(recorder.queries.map(\.text) == ["abc"])
    }

    @Test("a suggestion fetch failure clears suggestions without the query flag")
    func suggestionFailureIsQuiet() async {
        let m = LibrarySearchModel()
        m.runQuery = { _ in [] }
        m.fetchSuggestions = { _, _ in throw AtelierError.persistenceFailure(detail: "boom") }
        m.text = "br"
        m.textChanged()
        await poll { !m.isRunning }
        #expect(m.suggestions.isEmpty)
        #expect(!m.queryFailed)  // a suggestion miss is not a query failure
    }

    @Test("a tag: directive narrows suggestions to tags only")
    func tagDirectiveNarrowsSuggestions() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.fetchSuggestions = { prefix, inc in
            recorder.suggestCalls.append((prefix, inc)); return []
        }
        m.text = "tag:woo"; m.textChanged()
        await poll { recorder.suggestCalls.contains { !$0.includeCollections } }
        #expect(recorder.suggestCalls.last?.includeCollections == false)
        #expect(recorder.suggestCalls.last?.prefix == "woo")

        m.text = "woo"; m.textChanged()
        await poll { recorder.suggestCalls.contains { $0.includeCollections } }
        #expect(recorder.suggestCalls.last?.includeCollections == true)
    }

    // MARK: - Semantic (meaning) mode (047 · 3a · 10A)

    @Test("meaning mode with text routes to the semantic seam, carrying scope")
    func meaningModeRoutesToSemantic() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.runSemanticQuery = { q in recorder.semanticQueries.append(q); return [] }
        let wood = token("wood")
        m.tokens = [wood]
        m.mode = .meaning
        m.text = "cozy reading nook"
        m.textChanged()
        await poll { !recorder.semanticQueries.isEmpty }

        // Semantic seam ran; keyword seam did not.
        let q = recorder.semanticQueries.last
        #expect(q?.text == "cozy reading nook")   // raw text, no tag: parsing
        #expect(q?.tagIDs == [wood.id])            // structured scope still applies
        #expect(recorder.queries.isEmpty)
    }

    @Test("meaning mode with NO free text falls back to the keyword filter path")
    func meaningModeNoTextFallsBack() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.runSemanticQuery = { q in recorder.semanticQueries.append(q); return [] }
        m.mode = .meaning
        m.tokens = [token("wood")]   // tokens only, nothing to embed
        m.tokensChanged()
        await poll { !recorder.queries.isEmpty }
        #expect(recorder.semanticQueries.isEmpty)   // no text → not semantic
    }

    @Test("switching to meaning mode re-runs the active query semantically")
    func switchingModeReruns() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.runSemanticQuery = { q in recorder.semanticQueries.append(q); return [] }
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.queries.isEmpty }   // keyword first

        m.mode = .meaning
        m.modeChanged()
        await poll { !recorder.semanticQueries.isEmpty }
        #expect(recorder.semanticQueries.last?.text == "brass")
    }

    @Test("an already-selected token is pruned from suggestions")
    func selectedTokenPruned() async {
        let m = LibrarySearchModel()
        let wood = token("wood")
        m.tokens = [wood]
        m.runQuery = { _ in [] }
        m.fetchSuggestions = { _, _ in [wood, self.token("wooden")] }
        m.text = "woo"; m.textChanged()
        await poll { !m.suggestions.isEmpty }
        #expect(!m.suggestions.contains(wood))  // the selected one is filtered out
    }

    // MARK: - Favorites filter token (011 · U5)

    @Test("the favorites chip toggles the .favorites token, and reads back from it")
    func favoritesTokenToggles() {
        let m = LibrarySearchModel()
        #expect(!m.favoritesOnly)
        #expect(!m.isActive)

        m.toggleFavoritesFilter()
        #expect(m.favoritesOnly)
        #expect(m.tokens == [.favorites])
        // The token alone activates the search, like any other filter — so the
        // results grid replaces the pane instead of the chip doing nothing.
        #expect(m.isActive)

        m.toggleFavoritesFilter()
        #expect(!m.favoritesOnly)
        #expect(m.tokens.isEmpty)
    }

    @Test("the field's clear (×) drops the favorites filter with everything else")
    func favoritesTokenClears() {
        let m = LibrarySearchModel()
        m.tokens = [token("wood"), .favorites]
        m.text = "brass"
        m.clearQuery()
        #expect(!m.favoritesOnly)
        #expect(m.tokens.isEmpty)
    }

    @Test("removing the chip by its × turns the filter off")
    func favoritesTokenRemovable() {
        let m = LibrarySearchModel()
        m.toggleFavoritesFilter()
        m.removeToken(.favorites)
        #expect(!m.favoritesOnly)
    }

    /// The token is a CONJUNCT: it rides alongside the text and tag arms in one
    /// query rather than replacing them.
    @Test("favoritesOnly rides the keyword query with text and tag tokens")
    func favoritesTokenReachesKeywordQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        let wood = token("wood")
        m.tokens = [wood, .favorites]
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.queries.isEmpty }

        let q = recorder.queries.last
        #expect(q?.favoritesOnly == true)
        #expect(q?.text == "brass")
        // The synthetic favorites token must NOT leak into the tag ids.
        #expect(q?.tagIDs == [wood.id])
        #expect(q?.collectionIDs.isEmpty == true)
    }

    /// …and it survives the mode switch, where a filter the user can still see
    /// selected would otherwise silently stop applying.
    @Test("favoritesOnly rides the SEMANTIC query too")
    func favoritesTokenReachesSemanticQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.runSemanticQuery = { q in recorder.semanticQueries.append(q); return [] }
        m.mode = .meaning
        m.tokens = [.favorites]
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.semanticQueries.isEmpty }
        #expect(recorder.semanticQueries.last?.favoritesOnly == true)
    }

    @Test("the favorites token carries a stable id and its own name / glyph")
    func favoritesTokenIdentity() {
        #expect(SearchToken.favorites.id == SearchToken.favoritesID)
        #expect(SearchToken.favorites.displayName == "Favorites")
        // Distinct from every real entity id a tag / collection token could carry.
        #expect(SearchToken.favorites.id != token("wood").id)
    }
}
