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
import AtelierIngestion
import Combine
import Foundation
import Testing
@testable import AtelierRefs

/// The time limit is the outer bound on the lifecycle awaits below (099 · 11A):
/// awaiting a signal is exact, and an exact wait for something that never happens
/// hangs the runner rather than merely failing.
@MainActor
@Suite("LibrarySearchModel state (007 G2)", .timeLimit(.minutes(1)))
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
        /// How many times a `colorFilterAction` closed the page (085 · C2).
        var dismissals = 0
    }

    // The `poll` this suite used to declare privately now lives in
    // `TestSupport/Poll.swift` (099 · 11A) — same bound, same interval, and one
    // place for the next person to find. Every `await poll { … }` below is
    // unchanged: a trailing closure fills the shared helper's `until:` parameter.

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
        let events = EventRecorder(m.events.stream())
        m.text = "a"; m.textChanged()
        m.text = "ab"; m.textChanged()
        m.text = "abc"; m.textChanged()

        // Three keystrokes started three query tasks, so all three have to END
        // before "only the latest ran" means anything. That used to be "sleep
        // 120 ms and hope the losers have finished losing"; it is now the model
        // saying so — two `superseded`, one `settled` (099 · 11A).
        await events.wait(forAtLeast: 3) { _ in true }
        #expect(events.count { $0 == .superseded } == 2,
                "two of the three query tasks must be cancelled")
        #expect(events.count { if case .settled = $0 { true } else { false } } == 1)
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

    // MARK: - The color token (085 · C2)

    /// Every bucket needs its OWN id, and none may collide with the two synthetic
    /// ids already in the reserved space. A collision would make `removeToken` drop
    /// the wrong chip and the `selected` set treat two colors as one.
    @Test("color token ids are distinct, and clear of the reserved ones")
    func colorIDsAreDistinct() {
        let ids = ColorBucket.allCases.map { SearchToken.color($0).id }
        #expect(Set(ids).count == ColorBucket.allCases.count)
        #expect(!ids.contains(SearchToken.favoritesID))
        #expect(!ids.contains(Collection.unsortedID))
        // The shape, pinned once: a `0c` marker byte then the raw value. This is
        // what the first implementation got wrong — its formatted string was two
        // digits short, so every bucket parsed to nil and fell back to ONE id.
        #expect(SearchToken.color(.red).id
            == UUID(uuidString: "00000000-0000-0000-0000-000000000c03"))
    }

    @Test("a color token names its bucket")
    func colorTokenDisplayName() {
        #expect(SearchToken.color(.red).displayName == "Red")
        #expect(SearchToken.color(.teal).displayName == "Teal")
    }

    /// The swatch row is the same row before and after a click, so the second click
    /// on a chip has to undo the first — otherwise the row is a one-way trip only
    /// the field's `×` can reverse.
    @Test("toggleColorFilter adds then removes")
    func toggleColorFilter() {
        let m = LibrarySearchModel()
        #expect(m.selectedColorBuckets.isEmpty)

        m.toggleColorFilter(.red)
        #expect(m.selectedColorBuckets == [.red])
        #expect(m.isActive)

        m.toggleColorFilter(.red)
        #expect(m.selectedColorBuckets.isEmpty)
        #expect(!m.isActive)
    }

    @Test("colors accumulate — a second color widens rather than replacing")
    func colorsAccumulate() {
        let m = LibrarySearchModel()
        m.toggleColorFilter(.red)
        m.toggleColorFilter(.blue)
        #expect(m.selectedColorBuckets == [.red, .blue])
        // …and removing one leaves the other.
        m.toggleColorFilter(.red)
        #expect(m.selectedColorBuckets == [.blue])
    }

    /// The field's `×` clears colors like any other filter — the whole reason a
    /// color is a TOKEN rather than a parallel piece of state.
    @Test("clearQuery drops color tokens")
    func clearQueryDropsColors() {
        let m = LibrarySearchModel()
        m.toggleColorFilter(.green)
        m.clearQuery()
        #expect(m.selectedColorBuckets.isEmpty)
    }

    @Test("removeToken drops the color chip it names, and only that one")
    func removeColorToken() {
        let m = LibrarySearchModel()
        m.toggleColorFilter(.red)
        m.toggleColorFilter(.blue)
        m.removeToken(.color(.red))
        #expect(m.selectedColorBuckets == [.blue])
    }

    @Test("the color token reaches the query as raw bucket values")
    func colorTokenReachesQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        let wood = token("wood")
        m.tokens = [wood, .color(.red), .color(.blue)]
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.queries.isEmpty }

        let q = recorder.queries.last
        #expect(q?.colorBuckets == [ColorBucket.red.rawValue, ColorBucket.blue.rawValue])
        // The synthetic color ids must NOT leak into the tag ids.
        #expect(q?.tagIDs == [wood.id])
    }

    /// Same trap the favorites token was tested for: a filter still visible in the
    /// field must not silently stop applying when the mode flips.
    @Test("color buckets ride the SEMANTIC query too")
    func colorTokenReachesSemanticQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.runSemanticQuery = { q in recorder.semanticQueries.append(q); return [] }
        m.mode = .meaning
        m.tokens = [.color(.teal)]
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.semanticQueries.isEmpty }
        #expect(recorder.semanticQueries.last?.colorBuckets == [ColorBucket.teal.rawValue])
    }

    @Test("no color token means no color filter, not an empty-set filter")
    func noColorTokenIsInert() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.text = "brass"
        m.textChanged()
        await poll { !recorder.queries.isEmpty }
        #expect(recorder.queries.last?.colorBuckets.isEmpty == true)
    }

    /// The swatch click applies the filter AND closes the page that raised it. The
    /// dismiss is load-bearing: the results land in the pane BEHIND the overlay, so
    /// filtering without closing looks like the click did nothing.
    @Test("colorFilterAction applies the filter and dismisses")
    func colorFilterActionDismisses() {
        let m = LibrarySearchModel()
        let recorder = Recorder()
        let action = m.colorFilterAction(dismissing: { recorder.dismissals += 1 })

        action(.red)
        #expect(m.selectedColorBuckets == [.red])
        #expect(recorder.dismissals == 1)

        // And it is the same toggle, so a second click clears — still dismissing.
        action(.red)
        #expect(m.selectedColorBuckets.isEmpty)
        #expect(recorder.dismissals == 2)
    }

    // MARK: - The palette picker (085 · C3)

    /// The chip's on/off look reads the TOKENS, so the picker cannot show a color
    /// as off while the field shows its chip. One piece of state, two views.
    @Test("isColorSelected tracks the token, per bucket")
    func isColorSelectedTracksTokens() {
        let m = LibrarySearchModel()
        #expect(m.isColorSelected(.red) == false)

        m.toggleColorFilter(.red)
        #expect(m.isColorSelected(.red))
        #expect(m.isColorSelected(.blue) == false)  // and only that one

        m.toggleColorFilter(.red)
        #expect(m.isColorSelected(.red) == false)
    }

    /// The picker BUTTON's filled state. Distinct from `isColorSelected` because
    /// the button asks "any at all?" while a chip asks about itself.
    @Test("hasColorFilter is true only while a color token is present")
    func hasColorFilterFollowsAnyToken() {
        let m = LibrarySearchModel()
        #expect(m.hasColorFilter == false)

        m.toggleColorFilter(.teal)
        #expect(m.hasColorFilter)

        m.toggleColorFilter(.teal)
        #expect(m.hasColorFilter == false)
    }

    /// A tag token must NOT light the palette button — the two dimensions share a
    /// token array, and `hasColorFilter` has to read only its own case out of it.
    @Test("a non-color token leaves the palette button dark")
    func otherTokensDoNotSetHasColorFilter() {
        let m = LibrarySearchModel()
        m.tokens = [.favorites, token("grid")]
        #expect(m.hasColorFilter == false)
        #expect(m.isColorSelected(.red) == false)
    }

    /// "Clear colors" is NOT the field's `×`. It drops the colors and leaves the
    /// rest of the query standing — otherwise the picker would silently throw away
    /// a tag filter someone spent longer building than the colors.
    @Test("clearColorFilters drops every color and nothing else")
    func clearColorsKeepsTheRestOfTheQuery() {
        let m = LibrarySearchModel()
        let tag = token("grid")
        m.tokens = [tag, .favorites]
        m.toggleColorFilter(.red)
        m.toggleColorFilter(.blue)
        m.text = "editorial"

        m.clearColorFilters()

        #expect(m.selectedColorBuckets.isEmpty)
        #expect(m.tokens == [tag, .favorites])
        #expect(m.text == "editorial")
    }

    /// Clearing nothing must not PUBLISH — `tokens` drives an `onChange` that
    /// re-runs the query, and `removeAll` on a `@Published` array emits whether or
    /// not it removed anything. Comparing the array before and after cannot see
    /// that: the values are equal either way. So this counts the emissions, which
    /// is the thing the guard actually exists to prevent.
    @Test("clearColorFilters with no colors publishes nothing")
    func clearColorsIsInertWhenEmpty() {
        let m = LibrarySearchModel()
        let tag = token("grid")
        m.tokens = [tag]

        var emissions = 0
        let subscription = m.objectWillChange.sink { _ in emissions += 1 }
        defer { subscription.cancel() }

        m.clearColorFilters()
        #expect(emissions == 0)
        #expect(m.tokens == [tag])

        // ...and it DOES publish when there is something to clear, so the guard is
        // narrow rather than a way to skip the work.
        m.toggleColorFilter(.red)
        let afterToggle = emissions
        m.clearColorFilters()
        #expect(emissions > afterToggle)
    }

    /// The picker draws `ColorPalette.filterOrder`, so every bucket it offers must
    /// be one the model can actually hold as a token. A bucket that toggled to an
    /// id colliding with another's would make two chips one filter.
    @Test("every bucket the picker offers toggles its own distinct token")
    func everyPickerBucketTogglesIndependently() {
        let m = LibrarySearchModel()
        for bucket in ColorPalette.filterOrder {
            m.toggleColorFilter(bucket)
        }
        #expect(m.selectedColorBuckets == ColorPalette.filterOrder)
        #expect(Set(m.tokens.map(\.id)).count == ColorPalette.filterOrder.count)

        m.clearColorFilters()
        #expect(m.tokens.isEmpty)
    }

    // MARK: - The Any / All mode (099 · P10)

    /// One query run reached a terminal, publishing state.
    ///
    /// Every wait in this section awaits THIS rather than polling the recorder
    /// (099 · 11A: "where the object under test can SAY it finished … await the
    /// signal; it is exact"). `LibrarySearchModel.events` has said so since P1;
    /// the colour tests above it predate the signal and are left as they are.
    /// The suite's `.timeLimit(.minutes(1))` is the outer bound.
    private static let isSettled: @Sendable (LibrarySearchModel.Event) -> Bool = {
        if case .settled = $0 { true } else { false }
    }

    /// The default is the service's default, and it is the one a fresh pane starts
    /// at. 085 settled the reading ("red then blue" widens); this is where the app
    /// agrees with it, and the assertion that a later hand cannot flip the default
    /// without saying so.
    @Test("colorMatch starts at .any and reaches the query as .any")
    func colorMatchDefaultsToAny() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        #expect(m.colorMatch == .any)

        m.runQuery = { q in recorder.queries.append(q); return [] }
        let events = EventRecorder(m.events.stream())
        m.toggleColorFilter(.red)
        m.tokensChanged()
        await events.wait(forAtLeast: 1, where: Self.isSettled)
        #expect(recorder.queries.last?.colorMatch == .any)
    }

    /// The point of the whole phase: `.all` was reachable from `searchAssets` and
    /// from a hand-written rules blob and from nothing else. It now leaves the
    /// model on the query, which is the only path the service is ever reached by.
    @Test("colorMatch .all rides the keyword query")
    func colorMatchAllReachesTheQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        let events = EventRecorder(m.events.stream())
        m.colorMatch = .all
        m.toggleColorFilter(.red)
        m.toggleColorFilter(.blue)
        m.tokensChanged()
        await events.wait(forAtLeast: 1, where: Self.isSettled)

        let q = recorder.queries.last
        #expect(q?.colorMatch == .all)
        // …and it did not disturb the buckets it governs, or the tags' own mode.
        #expect(q?.colorBuckets == [ColorBucket.red.rawValue, ColorBucket.blue.rawValue])
    }

    /// The same trap the colour BUCKETS were tested for, one level up: a filter
    /// still showing in the picker must not silently stop applying when the mode
    /// flips to `.meaning`. `semanticSearchAssets` takes `colorMatch` too.
    @Test("colorMatch rides the SEMANTIC query too")
    func colorMatchReachesTheSemanticQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        m.runSemanticQuery = { q in recorder.semanticQueries.append(q); return [] }
        let events = EventRecorder(m.events.stream())
        m.mode = .meaning
        m.colorMatch = .all
        m.tokens = [.color(.teal), .color(.brown)]
        m.text = "brass"
        m.textChanged()
        await events.wait(forAtLeast: 1, where: Self.isSettled)
        #expect(recorder.semanticQueries.last?.colorMatch == .all)
    }

    /// Changing the mode is a new SEARCH, not a repaint. Nothing about the token
    /// set changed, so the `tokens` `onChange` cannot see it — `colorMatchChanged`
    /// is the hook the pane calls, and this is the assertion that it re-queries.
    @Test("colorMatchChanged re-runs the query with the new mode")
    func colorMatchChangeRerunsTheQuery() async {
        let recorder = Recorder()
        let m = LibrarySearchModel()
        m.runQuery = { q in recorder.queries.append(q); return [] }
        let events = EventRecorder(m.events.stream())
        m.tokens = [.color(.red), .color(.blue)]
        m.tokensChanged()
        await events.wait(forAtLeast: 1, where: Self.isSettled)
        #expect(recorder.queries.count == 1)
        #expect(recorder.queries.last?.colorMatch == .any)

        m.colorMatch = .all
        m.colorMatchChanged()
        // The SECOND settle: the mode change started its own query, and this is
        // the model saying that one published too.
        await events.wait(forAtLeast: 2, where: Self.isSettled)
        #expect(recorder.queries.count == 2, "the mode change is a new search")
        #expect(recorder.queries.last?.colorMatch == .all)
    }

    /// The control appears only when it is a choice. With one colour the two modes
    /// select the same pictures, so drawing it would be the dead affordance
    /// `ColorFilterPicker` refuses to draw "Clear colors" as.
    @Test("the Any / All control shows only once two colours are on")
    func colorMatchControlNeedsTwoColours() {
        let m = LibrarySearchModel()
        #expect(m.showsColorMatchControl == false)

        m.toggleColorFilter(.red)
        #expect(m.showsColorMatchControl == false, "one colour matches the same either way")

        m.toggleColorFilter(.blue)
        #expect(m.showsColorMatchControl)

        // A non-colour token must not count towards the pair.
        m.toggleColorFilter(.blue)
        m.tokens.append(.favorites)
        #expect(m.showsColorMatchControl == false)
    }

    /// `reset()` is the whole-model reset — a new pane — so the default comes back
    /// with it. `clearQuery` and `clearColorFilters` do NOT touch it, the way they
    /// already leave `scope` and `mode`: "match all of them" is something the user
    /// said about how they search, not one of the filters they are clearing.
    @Test("reset restores .any; clearing the query or the colours does not")
    func colorMatchResetRules() {
        let m = LibrarySearchModel()
        m.colorMatch = .all
        m.toggleColorFilter(.red)
        m.toggleColorFilter(.blue)

        m.clearColorFilters()
        #expect(m.colorMatch == .all, "the colours went; the reading of them stayed")

        m.toggleColorFilter(.green)
        m.text = "brass"
        m.clearQuery()
        #expect(m.colorMatch == .all)

        m.reset()
        #expect(m.colorMatch == .any)
    }

    /// The mode alone is not a query. Turning it to `.all` with nothing selected
    /// must not make an empty pane start searching — `isActive` reads text and
    /// tokens, and this pins that it stays that way.
    @Test("the colour mode alone does not activate a search")
    func colorMatchDoesNotActivate() {
        let m = LibrarySearchModel()
        m.colorMatch = .all
        #expect(!m.isActive)
    }
}
