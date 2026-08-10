//
//  LibrarySearch.swift
//  AtelierRefs
//
//  007 G2 — the search surface: a custom toolbar token field (`SearchToolbarField`,
//  styled to the app chrome) where typed free text is FTS (source title / author) and
//  selected tokens are structured tag filters (default AND). Global on the
//  Collections gallery, collection-scoped (with a This-collection / All toggle) on a
//  Collection screen. Results reuse the thumbnail grid and open the presentation-only
//  `ItemDetailView`.
//
//  Tag tokens resolve to ids before querying, so tag text never leaks into FTS
//  (a silent miss). Agent-applied tags are suggestible too, distinguished by a
//  sparkles glyph.
//

import AppKit
import AtelierCore
import AtelierIngestion
import Combine
import OSLog
import SwiftUI

// MARK: - Token + scope

/// One selected filter chip in the search field (044/045 · 16A/17A). A tag
/// narrows by structured id; a collection scopes to its membership. Multiple
/// collection tokens OR (member of ANY); tags AND. Selecting a suggested token
/// resolves free text to one of these before it ever reaches FTS.
enum SearchToken: Identifiable, Hashable {
    case tag(Tag)
    case collection(Collection)
    /// The favorites filter (011 · U5) — an AND conjunct, like a tag: it narrows
    /// whatever query is running rather than becoming a mode of its own. Carried
    /// as a token rather than as a separate `@Published` flag so it lives, clears
    /// and renders with every other filter: the field's `×` drops it, the chip row
    /// shows it, and `isActive` counts it without a second rule.
    case favorites

    /// The favorites token's synthetic id. Tokens are `Identifiable` by a real
    /// entity id, and this one has no entity; a FIXED constant (not a fresh UUID)
    /// keeps `removeToken` / the `selected` set working, and it is drawn from the
    /// reserved all-zero space Collection.unsortedID already uses so it can never
    /// collide with a real tag or collection.
    static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-0000000000fa")!

    var id: UUID {
        switch self {
        case .tag(let tag): return tag.id
        case .collection(let collection): return collection.id
        case .favorites: return Self.favoritesID
        }
    }

    var displayName: String {
        switch self {
        case .tag(let tag): return tag.name
        case .collection(let collection): return collection.name
        case .favorites: return "Favorites"
        }
    }
}

/// The parameters of one search execution — the seam (12A) between the model's
/// input state and the service call, so a test can inject a runner and assert
/// exactly what the model asked for.
struct LibrarySearchQuery: Equatable {
    /// The FTS free text (raw, so the type-ahead prefix survives). Empty when the
    /// query is a `tag:` directive or tokens-only.
    var text: String
    /// Structured tag ids from `.tag` tokens (ANDed).
    var tagIDs: [UUID]
    /// An unresolved `tag:` needle → a tag-name CONTAINS filter (17A), or `nil`.
    var tagNameContains: String?
    /// Collection scope from `.collection` tokens plus the This-collection scope,
    /// ORed (16A). Empty = whole library.
    var collectionIDs: [UUID]
    /// The `.favorites` token (011 · U5) — an AND conjunct on `asset.is_favorite`,
    /// conjunct with the text / tag / collection arms above.
    var favoritesOnly: Bool = false
    /// `.relevance` when there's free text to rank, else `.newest`.
    var sort: SearchSort
}

/// The Collection-screen scope toggle. Ignored on the global gallery.
enum SearchScope: Hashable {
    case thisCollection
    case all
}

/// How the free text is matched (047 · 3a · 10A). `.keyword` is the FTS keyword
/// backbone (prefix / substring / relevance); `.meaning` embeds the text and
/// ranks by semantic cosine similarity. Structured tag / collection scope applies
/// in BOTH modes; only the free-text ranking differs.
enum SearchMode: Hashable {
    case keyword
    case meaning
}

// MARK: - Model

@MainActor
final class LibrarySearchModel: ObservableObject {
    /// The free-text (FTS) query; also the live prefix that drives suggestions.
    @Published var text = ""
    /// The selected filter tokens — tags (ANDed) and collection scopes (ORed).
    @Published var tokens: [SearchToken] = []
    /// Collection-screen scope. Defaults per screen in `configure`.
    @Published var scope: SearchScope = .all
    /// Free-text matching mode (047 · 3a): keyword FTS vs semantic meaning.
    @Published var mode: SearchMode = .keyword
    /// Prefix-matched tag / collection suggestions for the current `text`.
    @Published private(set) var suggestions: [SearchToken] = []
    /// The current result set (bounded, newest-first).
    @Published private(set) var results: [AssetDetail] = []
    /// Bumped every time `results` is (re)assigned, so the results grid can prune a
    /// stale multi-selection to the surviving ids without needing `AssetDetail` to
    /// be `Equatable` for an `onChange`.
    @Published private(set) var resultsVersion = 0
    /// A query is in flight (drives a subtle progress affordance).
    @Published private(set) var isRunning = false
    /// Set when the last query FAILED, so the results view can distinguish a real
    /// error from a genuine "no matches" (they used to look identical).
    @Published private(set) var queryFailed = false

    private var services: AppServices?
    /// The screen's collection (`nil` = the global gallery — no scope toggle).
    private var collectionID: UUID?
    private var queryTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?


    /// The query executor — the injectable seam (12A). Defaults to the live
    /// service call; tests replace it to drive success / failure / cancellation
    /// paths without a database.
    var runQuery: (LibrarySearchQuery) async throws -> [AssetDetail] = { _ in [] }
    /// The suggestion fetcher — the sibling seam. `includeCollections` is false
    /// while a `tag:` directive narrows suggestions to tags only (17A).
    var fetchSuggestions: (_ prefix: String, _ includeCollections: Bool) async throws -> [SearchToken] = { _, _ in [] }
    /// The SEMANTIC query executor (047 · 3a) — the `.meaning`-mode seam. Defaults
    /// to the live embed-then-kNN call; tests replace it to assert routing without
    /// the model / a database.
    var runSemanticQuery: (LibrarySearchQuery) async throws -> [AssetDetail] = { _ in [] }

    /// The on-device sentence embedder for `.meaning` queries. Lazy so the NL model
    /// only loads once a semantic search is actually run (never in `.keyword` use
    /// or tests, which inject `runSemanticQuery`). `@unchecked Sendable`, so it's
    /// safe to hand to a detached task for off-main embedding.
    private lazy var embedder = NLSentenceEmbedder()

    init() {
        // Wire the seams to the live services by default (self is needed, so this
        // can't be a property initializer). Tests overwrite these after `init`.
        runQuery = { [weak self] query in
            try await self?.liveQuery(query) ?? []
        }
        fetchSuggestions = { [weak self] prefix, includeCollections in
            try await self?.liveSuggestions(prefix: prefix, includeCollections: includeCollections) ?? []
        }
        runSemanticQuery = { [weak self] query in
            try await self?.liveSemanticQuery(query) ?? []
        }
    }

    /// The structured tag ids among the selected tokens (ANDed).
    private var selectedTagIDs: [UUID] {
        tokens.compactMap { if case .tag(let tag) = $0 { tag.id } else { nil } }
    }
    /// The collection ids among the selected tokens (ORed scope).
    private var selectedCollectionIDs: [UUID] {
        tokens.compactMap { if case .collection(let c) = $0 { c.id } else { nil } }
    }
    /// Whether the favorites filter is on (011 · U5) — the `.favorites` token's
    /// presence, so there is exactly one source of truth for it.
    var favoritesOnly: Bool { tokens.contains(.favorites) }

    /// Turn the favorites filter on or off — the chip's click. Mutating `tokens`
    /// fires the same `onChange` re-run every other filter change does.
    func toggleFavoritesFilter() {
        if favoritesOnly {
            tokens.removeAll { $0 == .favorites }
        } else {
            tokens.append(.favorites)
        }
    }

    /// Whether a query is worth running / results should replace the content.
    var isActive: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tokens.isEmpty
    }
    /// Only a Collection screen offers the This-collection / All toggle.
    var showsScopeToggle: Bool { collectionID != nil }

    /// Bind the model to the live services + screen context. Called when the
    /// screen appears and whenever the library becomes ready. Sets the default
    /// scope (a Collection screen starts scoped to itself).
    func configure(services: AppServices?, collectionID: UUID?) {
        self.services = services
        self.collectionID = collectionID
        if collectionID != nil, scope == .all, !isActive { scope = .thisCollection }
        if isActive { runSearch() }
    }

    /// The `text` changed: refresh suggestions and re-run the search (debounced).
    func textChanged() {
        refreshSuggestions()
        runSearch()
    }

    /// The token set changed: re-run and prune now-selected tags from suggestions.
    func tokensChanged() {
        refreshSuggestions()
        runSearch()
    }

    /// The keyword/meaning mode changed: re-run (suggestions are keyword-only).
    func modeChanged() { runSearch() }

    /// Reset everything (e.g. when a screen disappears).
    func reset() {
        queryTask?.cancel(); suggestTask?.cancel()
        text = ""; tokens = []; suggestions = []; results = []; isRunning = false
        queryFailed = false
    }

    /// Dismiss the suggestion dropdown WITHOUT touching the query — e.g. the user
    /// clicked away from the custom search field. The next keystroke refetches, so
    /// this only hides the currently-open list (native `.searchable` did this on blur
    /// for free; the custom field drives it explicitly).
    func clearSuggestions() {
        suggestTask?.cancel()
        suggestions = []
    }

    /// Clear the free text and every selected token in one shot (the field's `×` /
    /// Esc). Leaves scope + mode as-is; the `onChange` hooks re-run into the empty
    /// (inactive) state, which drops the results grid back to the pane's content.
    func clearQuery() {
        text = ""; tokens = []
        clearSuggestions()
    }

    /// Remove one selected token (the chip's `×`). Mutating `tokens` fires the
    /// `onChange` re-run in `LibrarySearchable`.
    func removeToken(_ token: SearchToken) {
        tokens.removeAll { $0.id == token.id }
    }

    /// Promote a suggested token into the selected set and clear the matched text —
    /// the same move the native token field made when a suggestion was picked.
    func selectSuggestion(_ token: SearchToken) {
        guard !tokens.contains(where: { $0.id == token.id }) else { return }
        tokens.append(token)
        text = ""
        clearSuggestions()
    }

    // MARK: queries

    /// Re-run the active query (e.g. after a triage delete removes a hit from the
    /// library, so the stale card leaves the results grid). A no-op when inactive.
    func rerun() { if isActive { runSearch() } }

    private func runSearch() {
        queryTask?.cancel()
        guard isActive else {
            results = []; resultsVersion &+= 1; isRunning = false; queryFailed = false
            return
        }
        let (fts, tagNeedle) = Self.parse(query: text)
        let hasFTS = !fts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Collection scope = the `.collection` tokens (16A) plus the
        // This-collection toggle when active, de-duplicated (a screen scoped to a
        // collection the user ALSO tokenized shouldn't list it twice).
        var scopeIDs = selectedCollectionIDs
        if let collectionID, scope == .thisCollection { scopeIDs.append(collectionID) }
        scopeIDs = Array(NSOrderedSet(array: scopeIDs).array as? [UUID] ?? scopeIDs)

        // `.meaning` mode ranks the WHOLE raw text by semantic similarity (no `tag:`
        // parsing, no prefix/relevance sort — the embedder reads the concept), with
        // the same structured tag / collection scope. It needs text to embed; a
        // tokens-only query falls back to the keyword filter path.
        let query: LibrarySearchQuery
        let run: (LibrarySearchQuery) async throws -> [AssetDetail]
        if mode == .meaning, hasFTS {
            query = LibrarySearchQuery(
                text: text, tagIDs: selectedTagIDs, tagNameContains: nil,
                collectionIDs: scopeIDs, favoritesOnly: favoritesOnly,
                sort: .relevance)
            run = runSemanticQuery
        } else {
            query = LibrarySearchQuery(
                text: fts,
                tagIDs: selectedTagIDs,
                tagNameContains: tagNeedle,
                collectionIDs: scopeIDs,
                favoritesOnly: favoritesOnly,
                // Rank by relevance while there's text to rank; a tokens-only /
                // `tag:`-only query has nothing to score, so keep the recency order.
                sort: hasFTS ? .relevance : .newest)
            run = runQuery
        }
        isRunning = true
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            do {
                let hits = try await run(query)
                guard !Task.isCancelled else { return }
                results = hits
                resultsVersion &+= 1
                queryFailed = false
            } catch is CancellationError {
                return  // a superseded query — leave state for the live one.
            } catch {
                guard !Task.isCancelled else { return }
                // A relevance/cursor misuse is OUR bug (the UI never pages
                // relevance), so trap it in debug; other errors are runtime DB
                // failures — log and surface distinctly (an empty `results` alone
                // reads as "no matches" and hides that the search errored).
                AppLog.search.error("search query failed: \(String(describing: error))")
                if case AtelierError.relevanceSortUnpageable = error {
                    assertionFailure("relevance sort must never be paged from the search UI")
                }
                results = []
                resultsVersion &+= 1
                queryFailed = true
            }
            isRunning = false
        }
    }

    private func refreshSuggestions() {
        suggestTask?.cancel()
        let (_, tagNeedle) = Self.parse(query: text)
        // A `tag:` directive narrows suggestions to tags only (17A); otherwise the
        // raw prefix suggests both tags and collections.
        let includeCollections = tagNeedle == nil
        let prefix = (tagNeedle ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { suggestions = []; return }
        let selected = Set(tokens.map(\.id))
        let fetch = fetchSuggestions
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                let found = try await fetch(prefix, includeCollections)
                guard !Task.isCancelled else { return }
                suggestions = found.filter { !selected.contains($0.id) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.search.error("suggestion fetch failed: \(String(describing: error))")
                suggestions = []
            }
        }
    }

    // MARK: seam implementations (12A)

    /// The live query: forward to the service. `collectionIDs` empty = no scope.
    private func liveQuery(_ query: LibrarySearchQuery) async throws -> [AssetDetail] {
        guard let services else { return [] }
        return try await services.searchAssets(
            text: query.text,
            tagIDs: query.tagIDs,
            tagMatch: .all,
            tagNameContains: query.tagNameContains,
            collectionIDs: query.collectionIDs,
            favoritesOnly: query.favoritesOnly,
            sort: query.sort,
            limit: 500)
    }

    /// The live SEMANTIC query (047 · 3a): embed the text off-main, then rank by
    /// cosine kNN through the service, honouring the structured tag / collection
    /// scope. An unavailable model or empty vector yields no results (the mode is
    /// simply inert), never an error.
    private func liveSemanticQuery(_ query: LibrarySearchQuery) async throws -> [AssetDetail] {
        guard let services else { return [] }
        let text = query.text
        let embedder = self.embedder
        let vector = await Task.detached(priority: .userInitiated) { embedder.embed(text) }.value
        guard let vector else { return [] }
        return try await services.semanticSearchAssets(
            queryVector: vector,
            modelVersion: NLSentenceEmbedder.currentModelVersion,
            tagIDs: query.tagIDs,
            tagMatch: .all,
            collectionIDs: query.collectionIDs,
            favoritesOnly: query.favoritesOnly,
            limit: 500)
    }

    /// The live suggestions: tag vocabulary always, plus name-matching collections
    /// unless a `tag:` directive narrows to tags. The collection inventory is small
    /// and bounded (`listCollections`), so a case-insensitive CONTAINS in memory is
    /// fine; capped so suggestions stay a short list.
    private func liveSuggestions(prefix: String, includeCollections: Bool) async throws -> [SearchToken] {
        guard let services else { return [] }
        let tagTokens = try await services.tagVocabulary(prefix: prefix, limit: 8)
            .map(SearchToken.tag)
        guard includeCollections else { return tagTokens }
        let collectionTokens = try await services.listCollections()
            .filter { $0.name.localizedCaseInsensitiveContains(prefix) }
            .prefix(5)
            .map(SearchToken.collection)
        return tagTokens + collectionTokens
    }

    /// Split the raw query into its FTS text and an optional `tag:` needle (17A).
    /// A leading `tag:` directive routes the remainder to tag-name matching, with
    /// NO FTS text; everything else is plain FTS text returned VERBATIM (untrimmed)
    /// so the type-ahead trailing-space signal survives to `ftsMatchQuery`.
    static func parse(query: String) -> (fts: String, tagNeedle: String?) {
        let leading = query.drop(while: { $0.isWhitespace })
        guard leading.lowercased().hasPrefix("tag:") else { return (query, nil) }
        let needle = leading.dropFirst("tag:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ("", needle.isEmpty ? nil : needle)
    }
}

// MARK: - Searchable container

/// Fixed compact width shared by the toolbar field and the floating suggestion
/// dropdown, so the dropdown lines up under the field at the panel's trailing edge.
private let searchFieldWidth: CGFloat = 360

/// Wraps a screen's `content`, puts the custom `SearchToolbarField` in the WINDOW
/// TOOLBAR (trailing), and swaps in the results grid (with an asset-scoped detail
/// overlay) while a search is active. The field replaces the old native `.searchable`
/// so the search chrome matches the app (the `field` capsule of the selection action
/// bar); Esc-to-clear, ⌘F focus, removable token chips, and the suggestion dropdown are
/// rebuilt on the model. The toolbar clips an attached overlay, so the suggestion
/// dropdown floats at the top of the panel (trailing, under the field) instead. The
/// keyword / meaning mode toggle stays a control at the top of the results grid — see
/// `LibrarySearchResults.modePicker`.
/// Whether `responder` is the **search field's** text editor — the only thing a tap in
/// the content is allowed to blur.
///
/// This used to read `responder is NSText`, which is not the same question. `NSTextView`
/// is a subclass of `NSText`, so it also matched the canvas's inline text editor — and
/// since `LibrarySearchable` wraps every pane and a `simultaneousGesture` ends on
/// mouse-UP, every double-click that opened a text box was blurred a few milliseconds
/// later by this very handler. It looked like double-click-to-edit was broken; the edit
/// was opening every time and being closed again immediately.
///
/// A *field editor* is the shared per-window editor an `NSTextField` (and so a SwiftUI
/// `TextField`) borrows while focused. The canvas owns its text view outright, so it is
/// not one — which is exactly the distinction wanted here.
func isSearchFieldEditor(_ responder: NSResponder?) -> Bool {
    guard let text = responder as? NSText else { return false }
    return text.isFieldEditor
}

struct LibrarySearchable<Content: View>: View {
    @ObservedObject var model: IngestionModel
    /// The global grid density notch — search results honour the SAME persisted
    /// density (and zoom controls) as the collection grid, instead of a fixed 4-up.
    @ObservedObject var gridPrefs: GridViewPreferences
    /// Observed for `navigationPulse` only — a sidebar click means "show me this
    /// destination", which has to drop whatever query is currently covering it.
    @ObservedObject var nav: NavModel
    /// The screen's collection, or `nil` for the global gallery.
    let collectionID: UUID?
    @ViewBuilder let content: () -> Content

    @StateObject private var search = LibrarySearchModel()
    @State private var detail: AssetDetail?
    /// The detail page's run + grouping, memoized on `(resultsVersion, grouping)` so
    /// the page does not rebuild a whole `PostGroups` per body pass (080 §4).
    @State private var detailContexts = SearchDetailContextCache()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if search.isActive {
                    LibrarySearchResults(
                        model: model, search: search, gridPrefs: gridPrefs,
                        isDetailPresented: detail != nil
                    ) { asset in
                        model.recordView(assetID: asset.asset.id)
                        detail = asset
                    }
                } else {
                    content()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // URL-bar behaviour: clicking anywhere in the content — including empty
            // space — blurs the search field and dismisses the suggestion dropdown.
            .simultaneousGesture(TapGesture().onEnded {
                if let window = NSApp.keyWindow,
                   isSearchFieldEditor(window.firstResponder) {
                    window.makeFirstResponder(nil)
                }
                search.clearSuggestions()
            })

            // The toolbar clips an overlay hung off the field, so the suggestion list
            // floats here — top of the panel, trailing edge, roughly under the field.
            // Alignment is approximate; live typing keeps working (unlike a popover,
            // which would steal first responder from the field).
            if !search.suggestions.isEmpty {
                SearchSuggestionsDropdown(search: search)
                    .frame(width: searchFieldWidth)
                    .padding(.trailing, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.sm)
                    .zIndex(2)
            }

            if let services = model.services, detail != nil {
                // The RUN, not raw result order (069) — a carousel among the hits is
                // walked as one post, in the post's order, exactly as the grid drew it.
                // Still asked for inside this branch, so a query with no page open pays
                // nothing; the memo is what stops the page ITSELF re-deriving it on
                // every step, zoom settle and resize tick (080 §4).
                let context = detailContexts.context(
                    results: search.results, resultsVersion: search.resultsVersion,
                    groupCarousels: gridPrefs.groupCarousels)
                SearchDetailOverlay(
                    services: services, model: model,
                    context: context,
                    current: $detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .toolbar {
            // A flexible spacer ahead of the field pushes it to the trailing edge —
            // a lone `.primaryAction` item otherwise sits at the leading edge, right
            // by the traffic lights.
            ToolbarSpacer(.flexible)
            // The favorites filter chip (011 · U5), collection screens only. It is
            // one click onto the SAME `.favorites` token the field renders as a
            // chip — not a parallel filter — so turning it on shows the chip in
            // the field, and the field's `×` turns it back off. The global gallery
            // omits it: there the filter is reached by the token like any other,
            // and a permanent star in the toolbar of every screen would be a
            // second, competing home for one piece of state.
            if collectionID != nil {
                ToolbarItem(placement: .primaryAction) {
                    FavoritesFilterChip(search: search)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SearchToolbarField(search: search)
                    .frame(width: searchFieldWidth)
            }
        }
        .task(id: model.isReady) {
            search.configure(services: model.services, collectionID: collectionID)
        }
        // The user navigated — drop the previous pane's query so the destination's
        // CONTENT is what appears. Without this the results grid stayed up across a
        // sidebar click (this wrapper's `@StateObject` survives a same-branch change),
        // leaving the field's `×` as the only way back. The re-`configure` also re-points
        // the model at the NEW `collectionID`, which nothing else refreshed — a
        // This-collection scope kept querying the collection the panel had left.
        .onChange(of: nav.navigationPulse) { _, _ in
            search.reset()
            search.configure(services: model.services, collectionID: collectionID)
        }
        .onChange(of: search.text) { _, _ in search.textChanged() }
        .onChange(of: search.tokens) { _, _ in search.tokensChanged() }
        .onChange(of: search.mode) { _, _ in search.modeChanged() }
        .onChange(of: search.scope) { _, _ in search.configure(services: model.services, collectionID: collectionID) }
    }
}

// MARK: - Custom search field (app chrome, in the window toolbar)

/// The search input: a leading magnifying glass, inline removable token chips, the
/// free-text field, and a trailing clear `×`. It draws NO background of its own — the
/// macOS 26 toolbar item supplies the outer glass rect it sits in. Hosted as a
/// `ToolbarItem` (trailing) by `LibrarySearchable`; the matching suggestion dropdown is
/// a sibling (`SearchSuggestionsDropdown`) floated in the panel, since the toolbar would
/// clip an attached overlay. Esc clears the query; ⌘F focuses the field.
private struct SearchToolbarField: View {
    @ObservedObject var search: LibrarySearchModel
    @FocusState private var focused: Bool

    private static let prompt = "Search"

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.inkSecondary)

            ForEach(search.tokens) { token in
                SearchTokenChip(token: token) { search.removeToken(token) }
            }

            TextField(Self.prompt, text: $search.text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .focused($focused)
                .onKeyPress(.escape) {
                    guard search.isActive else { return .ignored }
                    search.clearQuery()
                    return .handled
                }

            if search.isActive {
                Button {
                    search.clearQuery()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                }
                // Tighter than `Radius.control`, deliberately: the hover fill hugs a
                // 12pt glyph at 3pt padding, and the token's 7 would round it to a
                // near-circle. Scales with the control, so it is not a token.
                .buttonStyle(HoverButtonStyle(cornerRadius: 5, padding: 3))
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 3)
        // No own capsule fill / border — the macOS 26 toolbar item already supplies the
        // outer glass rect the field sits in; a second background just double-stacked.
        // ⌘F focuses the field (parity with the old native search shortcut).
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// The leading glyph for a token / suggestion — an agent-applied tag gets the
    /// sparkles, a manual tag the tag glyph, a collection the folder.
    static func icon(for token: SearchToken) -> String {
        switch token {
        case .tag(let tag): return tag.source == .agent ? "sparkles" : "tag"
        case .collection: return "folder"
        case .favorites: return "star.fill"
        }
    }
}

// MARK: - Favorites filter chip (011 · U5)

/// The collection screen's one-click favorites filter. A star that reads its state
/// from — and writes it to — the `.favorites` search token, so the chip, the token
/// in the field, and the query can never disagree: there is one piece of state and
/// two views of it.
private struct FavoritesFilterChip: View {
    @ObservedObject var search: LibrarySearchModel

    var body: some View {
        Button { search.toggleFavoritesFilter() } label: {
            Image(systemName: search.favoritesOnly ? "star.fill" : "star")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(search.favoritesOnly
                    ? Theme.Colors.inkPrimary : Theme.Colors.inkSecondary)
        }
        .buttonStyle(HoverButtonStyle(
            cornerRadius: Theme.Radius.control, padding: Theme.Spacing.xs))
        .help(search.favoritesOnly ? "Show all items" : "Show favorites only")
        .accessibilityLabel("Favorites filter")
        .accessibilityAddTraits(search.favoritesOnly ? [.isSelected] : [])
    }
}

// MARK: - Suggestion dropdown

/// The prefix-matched tag / collection suggestions, in the shared design-system card +
/// rows. Picking one promotes it to a token and clears the matched text. Floated in the
/// panel (not off the toolbar field) so the toolbar can't clip it.
private struct SearchSuggestionsDropdown: View {
    @ObservedObject var search: LibrarySearchModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(search.suggestions) { token in
                SelectionMenuRow(token.displayName, systemImage: SearchToolbarField.icon(for: token)) {
                    search.selectSuggestion(token)
                }
            }
        }
        .padding(Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.hairline))
        .elevation(.hover)
    }
}

/// One selected filter as a removable pill inside the search field — the `selection`
/// fill (a step up from the field it sits in), ink label, and a trailing `×`.
private struct SearchTokenChip: View {
    let token: SearchToken
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: SearchToolbarField.icon(for: token))
                .font(.system(size: 10, weight: .medium))
            Text(token.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            // Tighter again — an 8pt glyph at 2pt padding, the smallest control the
            // app draws. See the note on the search field's clear button.
            .buttonStyle(HoverButtonStyle(cornerRadius: 4, padding: 2))
            .help("Remove filter")
        }
        .foregroundStyle(Theme.Colors.inkPrimary)
        .padding(.leading, Theme.Spacing.sm)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(Theme.Colors.selection, in: Capsule())
    }
}

// MARK: - Results grid

/// A synthetic membership per search hit, so anything keyed on a `CollectionItemDetail`
/// — the grid host, ``PostGroups`` — can take search results unchanged.
///
/// `item.id == asset.id`, so every closure keyed on a cell id coincides with the asset
/// id and no mapping is needed anywhere. `collectionID` is the membership-less sentinel
/// scope; the placement fields are unused (search has no reorder — array order stands).
///
/// File-scope rather than a method on the results grid because the DETAIL overlay is
/// presented by `LibrarySearchable`, one view up, and has to group the identical feed
/// (069). Two copies of this mapping would be two feeds that could disagree.
func searchItems(for results: [AssetDetail]) -> [CollectionItemDetail] {
    results.map { detail in
        CollectionItemDetail(
            item: CollectionItem(
                id: detail.asset.id,
                collectionID: AssetDragPayload.nilSourceID,
                assetID: detail.asset.id,
                addedAt: detail.asset.createdAt),
            asset: detail.asset,
            source: detail.source)
    }
}

/// What the search detail page needs from the result set: the run its ← / → walk, and
/// the grouping THAT SAME PASS produced.
///
/// One value rather than two calls, because the two have to be the same derivation: the
/// chip says "2 of 4 in this post" about the very index the arrows step through, and a
/// second ``PostGroups`` built beside the first is a second answer waiting to differ
/// (316's "two lists, one of them unseen").
///
/// Empty grouping when the carousel toggle is off — then the run is raw result order,
/// and a chip counting post positions would describe a walk the arrows do not take.
struct SearchDetailContext {
    /// The hits in the order the DETAIL page walks them (069): result order, but with
    /// each post's images together and in the post's own order — the same rule the
    /// results grid draws by, so the page's ← / → agree with what is on screen.
    let run: [AssetDetail]
    /// The result set bucketed by post. `item.id == asset.id` here
    /// (``searchItems(for:)``), so an `AssetDetail` can be looked up in it directly.
    let groups: PostGroups

    init(results: [AssetDetail] = [], groupCarousels: Bool = false) {
        guard groupCarousels else {
            run = results
            groups = PostGroups()
            return
        }
        let items = searchItems(for: results)
        let grouping = PostGroups(items: items)
        let byID = Dictionary(
            results.map { ($0.asset.id, $0) }, uniquingKeysWith: { first, _ in first })
        run = grouping.fullRun(items).compactMap { byID[$0.item.id] }
        groups = grouping
    }
}

/// The memo that keeps ``SearchDetailContext`` off the body-pass hot path (080 §4).
///
/// The grouping used to be built INSIDE `LibrarySearchable.body` — a full bucket +
/// per-group sort + `fullRun` + a `Dictionary` over every hit, i.e. O(n log n) across
/// the whole result set, re-run on every ← / →, every zoom settle and every geometry
/// tick of a live window resize. The call site's "a query with no page open pays
/// nothing" was true and accounted only for the CLOSED case; search is the one surface
/// with no bound on `n`.
///
/// A memo box in `@State` rather than a `.task(id:)` or an `.onChange` rebuild, for two
/// reasons: it stays LAZY (a query with no page open still pays nothing — the box is
/// only asked inside the `detail != nil` branch), and it is SYNCHRONOUS, so the page's
/// first frame has its run instead of opening on an empty pager. Same idiom, and the
/// same reason, as ``MoveTargetsCache`` (027 · G3).
///
/// Keyed on `search.resultsVersion` rather than the array: it is the identity the model
/// already publishes and the results grid already keys its own rebuild on, and comparing
/// a whole `[AssetDetail]` per body pass would reintroduce an O(n) pass to avoid an
/// O(n log n) one.
@MainActor
final class SearchDetailContextCache {
    private struct Key: Equatable {
        var resultsVersion: Int
        var groupCarousels: Bool
    }

    private var key: Key?
    private var value = SearchDetailContext()
    /// Cache misses since init — the handle a perf test would take to prove the memo
    /// hits across renders, as ``MoveTargetsCache/buildCount`` does.
    private(set) var buildCount = 0

    func context(
        results: [AssetDetail], resultsVersion: Int, groupCarousels: Bool
    ) -> SearchDetailContext {
        let k = Key(resultsVersion: resultsVersion, groupCarousels: groupCarousels)
        if key == k { return value }
        value = SearchDetailContext(results: results, groupCarousels: groupCarousels)
        key = k
        buildCount += 1
        return value
    }
}

private struct LibrarySearchResults: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var search: LibrarySearchModel
    @ObservedObject var gridPrefs: GridViewPreferences
    /// Whether the detail page is up over these results (069) — the grid keeps first
    /// responder behind it, so it has to stop consuming keys the page needs.
    var isDetailPresented: Bool = false
    let onOpen: (AssetDetail) -> Void

    /// The live grid width, captured for the ⌘± density clamp (mirrors
    /// `CollectionView.gridWidth`), so zoom respects the 512px cell cap.
    @State private var gridWidth: CGFloat = 1

    // The destination hierarchy for the "Add to Collection ▸" submenu, memoized on
    // the folder list exactly as `CollectionView` does (027 · G3).
    @State private var moveTargetsCache = MoveTargetsCache()

    // 048 — search now renders through the SAME AppKit `MasonryGridHost` as the
    // collection grid instead of a bespoke SwiftUI `LazyVGrid`. This gives search
    // the native `NSDraggingSession` (no per-frame SwiftUI rebuild → the old drag
    // lag is gone), the precomputed small drag image, and the full reducer
    // behaviour — click / ⌘ / ⇧ / marquee / arrows / ⌘A / Delete / Esc — for free.
    // Search hits are membership-less, so a synthetic `CollectionItemDetail` per
    // hit (with `item.id == asset.id`) bridges the host, which is keyed on
    // membership `item.id`; the sentinel scope id + `.looseAssets` menu keep every
    // drop a COPY and hide the verbs that need a real membership.
    @StateObject private var selectionStore = GridSelectionStore()
    @Environment(\.displayScale) private var displayScale

    /// The result set bucketed by originating post (307 · carousel grouping), so a
    /// carousel scattered across a result page can be picked up in one action. Held
    /// as state and rebuilt only when the results change — the collection grid gets
    /// this from `IngestionModel`; search owns its own feed, so it owns its own index.
    @State private var postGroups = PostGroups()

    /// A stable, membership-less sentinel "collection" id for the host. Search hits
    /// belong to no collection; a constant keeps the host from resetting scroll
    /// between queries and marks every drag-out payload as a copy (009 · N3).
    private static let searchScopeID = AssetDragPayload.nilSourceID

    /// The 84 pt / 192-bucket drag preview — the small precomputed image the AppKit
    /// grid uses, NOT a snapshot of the full 384-bucket cell (048 · the old lag).
    private static let dragPreviewSide: CGFloat = 84

    /// The result set's asset ids in display order — the reducer's `order`.
    private var orderIDs: [UUID] { displayItems.map { $0.item.id } }

    /// The results as the grid SHOWS them — collapsed to one tile per post when
    /// grouping is on (307). Held as state, not computed, because this body re-runs
    /// on every selection change and collapsing is O(results).
    @State private var displayItems: [CollectionItemDetail] = []
    /// Bumped whenever ``displayItems`` is rebuilt, and passed to the host as its
    /// items version. It cannot be `search.resultsVersion`: flipping the grouping
    /// toggle changes the display list while the results are identical, and the
    /// masonry layout cache keys off this integer alone — without a bump it would
    /// serve the previous solve and lay out the wrong number of cells.
    @State private var displayVersion = 0
    /// Representative ids of posts opened in place (307), same as the collection
    /// surface. Search owns its own feed, so it owns its own expansion state.
    @State private var expandedPosts: Set<UUID> = []

    /// Rebuild the post index and the display list from the current results. One
    /// function, called from every trigger, so the two can never drift apart.
    private func rebuildGrouping() {
        let source = items
        postGroups = PostGroups(items: source)
        expandedPosts = expandedPosts.filter { postGroups.memberCount(forItem: $0) > 1 }
        displayItems = gridPrefs.groupCarousels
            ? postGroups.collapsed(source, expanding: expandedPosts)
            : source
        displayVersion &+= 1
    }

    /// A synthetic membership per hit so the host (keyed on `item.id`) can render
    /// search results — see ``searchItems(for:)``.
    private var items: [CollectionItemDetail] { searchItems(for: search.results) }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            Group {
                if search.results.isEmpty {
                    if search.queryFailed {
                        ContentUnavailableView(
                            "Search failed",
                            systemImage: "exclamationmark.magnifyingglass",
                            description: Text("Something went wrong running this search. "
                                + "Adjust the query to try again."))
                    } else {
                        ContentUnavailableView(
                            search.isRunning ? "Searching…" : "No results",
                            systemImage: search.isRunning ? "hourglass" : "magnifyingglass",
                            description: Text(search.isRunning
                                ? "Looking through your library."
                                : "No items match this search."))
                    }
                } else {
                    resultsGrid
                }
            }
            // Center the empty / failed / searching states in the full panel rather than
            // sizing to the text.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Edit ▸ Remove / Delete (022 · D5). `canRemove: false` — search results have
        // no container, so the Remove item is greyed here rather than picking one of
        // the hit's collections on the user's behalf. ⌘⌫ still works: leaving the
        // library is the one verb that means the same thing from every surface.
        .focusedSceneValue(\.deleteVerbs, DeleteVerbs(
            removeTitle: "Remove from Collection",
            canRemove: false,
            remove: {},
            destroy: { requestDeleteTargets() }))
    }

    /// The keyword / meaning mode toggle (047 · 3a · 10A), relocated out of the native
    /// `.searchScopes` bar to the top of the results panel: `.keyword` runs FTS
    /// prefix / substring / relevance, `.meaning` embeds the text and ranks by cosine
    /// similarity. Trailing-aligned and styled with the app chrome (`SearchModeToggle`),
    /// so it reads as part of the design system rather than a stock segmented control —
    /// the result count now takes the leading slot. `search.mode`'s `onChange` (in
    /// `LibrarySearchable`) re-runs.
    private var modePicker: some View {
        HStack {
            // The result count, styled like every other page's "N items" subtitle
            // so search reads as another counted surface.
            if !search.results.isEmpty {
                Text("\(search.results.count) results")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            Spacer(minLength: 0)
            SearchModeToggle(mode: $search.mode)
        }
        // Share the collection grid's 24pt content margin so the toggle's right edge
        // and the count's left edge align with the grid below.
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private var resultsGrid: some View {
        MasonryGridHost(configuration: gridConfiguration)
            // Match the collection grid's 24pt horizontal content margin (the
            // collection grid inherits it from its surrounding VStack padding; the
            // search grid is placed directly, so it sets the inset itself).
            .padding(.horizontal, Theme.Spacing.xl)
            // Track the grid width so ⌘± zoom clamps against the live viewport, the
            // same guard the collection grid applies.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                if abs(gridWidth - w) > 0.5 { gridWidth = w }
            }
            .overlay(alignment: .bottom) {
                if selectionStore.selection.isSelecting {
                    selectionBar.padding(.bottom, Theme.Spacing.lg)
                }
            }
            // Keep the reducer's feed order in step with the results (the host does
            // not push this itself — the collection grid's model does). Prune a stale
            // multi-selection to the surviving ids whenever the query changes.
            .onAppear {
                rebuildGrouping()
                selectionStore.setOrder(orderIDs)
            }
            .onChange(of: search.resultsVersion) { _, _ in
                rebuildGrouping()
                selectionStore.setOrder(orderIDs)
                selectionStore.prune(to: orderIDs)
            }
            // Grouping hides tiles, so the reducer's order must follow it and a
            // selection holding a now-hidden member has to be pruned.
            .onChange(of: gridPrefs.groupCarousels) { _, _ in
                rebuildGrouping()
                selectionStore.setOrder(orderIDs)
                selectionStore.prune(to: orderIDs)
            }
            // A triage delete removes a hit from the library — re-run the query so the
            // stale card leaves the grid (contentsVersion bumps when the delete reloads).
            .onChange(of: model.contentsVersion) { _, _ in search.rerun() }
    }

    // MARK: - Host configuration

    private var gridConfiguration: GridHostConfiguration {
        GridHostConfiguration(
            items: displayItems,
            itemsVersion: displayVersion,
            postGroups: postGroups,
            density: gridPrefs.density,
            spacing: Theme.Spacing.sm,
            topInset: Theme.Spacing.md,
            collectionID: Self.searchScopeID,
            displayScale: displayScale,
            thumbnailURL: { model.thumbnailURL(forAsset: $0.asset) },
            blobURL: { model.blobURL(forAsset: $0.asset) },
            selectionStore: selectionStore,
            onOpenDetail: { id in
                if let hit = search.results.first(where: { $0.asset.id == id }) { onOpen(hit) }
            },
            // ⌫ is a NO-OP here, deliberately (022 · D2): a hit belongs to the query,
            // not to a container, so there is nothing "where you are looking" to
            // remove it from. Silently doing nothing beats guessing at one of its
            // collections. ⌘⌫ still leaves the library, as it does everywhere.
            onRequestRemove: {},
            onRequestDelete: { requestDeleteTargets() },
            // Search is MEMBERSHIP-LESS (019 · C1): the hits have no owning
            // collection, so the copy's private payload carries the nil-source
            // sentinel and a ⌘V anywhere reads as an add, never a same-place no-op.
            onCopy: {
                model.copySelectedToPasteboard(
                    from: items, selection: selectionStore.selection.ids,
                    sourceCollectionID: Self.searchScopeID)
            },
            onQuickLook: {},   // search has no Quick Look plumbing yet (parity gap, not lag)
            // ⌘± drives the SAME global density notch as the collection grid, so a
            // zoom in search persists everywhere (011-B2).
            onZoomIn: { gridPrefs.zoomIn(forWidth: gridWidth) },
            onZoomOut: { gridPrefs.zoomOut(forWidth: gridWidth) },
            dragPayload: { dragPayload(for: $0) },
            dragImage: { dragImage(for: $0) },
            canReorder: false,
            onReorderCommit: { _, _ in false },
            actionTargets: { actionTargets(for: $0) },
            // 027 · G3 — the same nested hierarchy the collection grid offers.
            // Nothing is disabled: a hit belongs to no collection here, so every
            // destination is a legitimate add.
            destinationTree: destinationTree,
            destinationUnsortedID: model.unsortedFolderID,
            onMoveToCollection: { _, _ in },   // membership-less: never moves
            onCopyToCollection: { ids, target in model.copyToCollection(assetIDs: ids, to: target) },
            onSetCover: { _ in },
            onRemoveFromCollection: { _ in },
            onDelete: { ids in model.requestDelete(assetIDs: ids) },
            onToggleExpand: { toggleExpansion(forItem: $0) },
            expandedPosts: expandedPosts,
            // 069 — the detail page owns the keyboard while it is up.
            isDetailPresented: isDetailPresented,
            menuStyle: .looseAssets,
            onReveal: { id in
                if let hit = search.results.first(where: { $0.asset.id == id }) {
                    model.revealInFinder(asset: hit.asset)
                }
            })
    }

    // MARK: - Finder-scope target rules (whole selection when the cell is in it)

    /// The payload a cell drag carries: the whole selection when the dragged cell is
    /// part of it, else just that cell. The sentinel source marks it membership-less
    /// so drops COPY (add) rather than move (009 · N3).
    private func dragPayload(for id: UUID) -> AssetDragPayload {
        let selection = selectionStore.selection
        let ids = (selection.isSelecting && selection.ids.contains(id))
            ? Array(selection.ids) : [id]
        return AssetDragPayload(assetIDs: ids, sourceCollectionID: AssetDragPayload.nilSourceID)
    }

    /// The asset ids a menu / drag acts on for the cell — the whole selection when
    /// the cell is in it, else the one cell (the selection stays untouched).
    private func actionTargets(for id: UUID) -> [UUID] {
        let selection = selectionStore.selection
        let scope: Set<UUID> = (selection.isSelecting && selection.ids.contains(id))
            ? selection.ids : [id]
        return Array(widenedForAction(scope))
    }

    /// The ids a keyboard/bar Delete acts on: the selection while selecting, else the
    /// cursor's lone item.
    private func requestDeleteTargets() {
        let selection = selectionStore.selection
        let scope: Set<UUID> = selection.isSelecting
            ? selection.ids : Set(selection.lead.map { [$0] } ?? [])
        let targets = Array(widenedForAction(scope))
        guard !targets.isEmpty else { return }
        model.requestDelete(assetIDs: targets)
    }

    /// Widen ids to whole posts for an action, but only where the grid is HIDING
    /// members (307) — an opened post shows each member as its own tile, and those
    /// act individually. Search synthesizes `item.id == asset.id`, so the widened
    /// membership ids ARE asset ids; the collection surface needs a mapping step.
    private func widenedForAction(_ ids: Set<UUID>) -> Set<UUID> {
        guard gridPrefs.groupCarousels else { return ids }
        var result = Set<UUID>()
        for id in ids {
            let members = postGroups.members(forItem: id)
            guard let lead = members.first, !expandedPosts.contains(lead) else {
                result.insert(id)
                continue
            }
            result.formUnion(members)
        }
        return result
    }

    /// Open or close the post behind `itemID` — the carousel chip's click.
    private func toggleExpansion(forItem itemID: UUID) {
        guard gridPrefs.groupCarousels,
              postGroups.memberCount(forItem: itemID) > 1 else { return }
        let lead = postGroups.members(forItem: itemID).first ?? itemID
        if expandedPosts.contains(lead) {
            expandedPosts.remove(lead)
        } else {
            expandedPosts.insert(lead)
        }
        rebuildGrouping()
        selectionStore.setOrder(orderIDs)
    }

    /// Every collection as a copy target, memoized (027 · G3) — the SAME hierarchy
    /// the collection grid and the selection bar offer. This used to flatten the
    /// whole library into one alphabetical root list, which put a nested
    /// `Refs/Type/Serif` beside unrelated roots as a bare `Serif`.
    private var destinationTree: [DestinationTreeNode] {
        moveTargetsCache.destinationTree(
            folders: model.folders, unsortedID: model.unsortedFolderID)
    }

    // MARK: - Drag image (the small precomputed preview, 048)

    @MainActor
    private func dragImage(for id: UUID) -> NSImage? {
        guard let hit = search.results.first(where: { $0.asset.id == id }) else { return nil }
        let selection = selectionStore.selection
        let count = (selection.isSelecting && selection.ids.contains(id))
            ? max(selection.ids.count, 1) : 1
        let renderer = ImageRenderer(content: dragPreview(asset: hit.asset, count: count))
        renderer.scale = displayScale
        return renderer.nsImage
    }

    @ViewBuilder
    private func dragPreview(asset: Asset, count: Int) -> some View {
        AssetContentThumbnail(
            asset: asset,
            url: model.thumbnailURL(forAsset: asset),
            bucket: thumbnailPixelBucket(pointLongSide: Self.dragPreviewSide, scale: displayScale))
            .frame(width: Self.dragPreviewSide, height: Self.dragPreviewSide)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(Theme.Typography.caption).bold().monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        // NOT `selectionMark`: this is a count BADGE, and white-on-
                        // white would erase its own label. A raised dark chip is the
                        // monochrome equivalent of "stands off the artwork".
                        .background(Capsule().fill(Theme.Colors.surface))
                        .padding(4)
                }
            }
    }

    // MARK: - Selection bar

    /// The floating "N selected · Clear · Delete" bar, shown while a selection is
    /// active. Delete routes through the same staged/undoable asset delete as the
    /// keyboard and context menu.
    private var selectionBar: some View {
        CountSelectionBar(
            count: selectionStore.selection.ids.count,
            onClear: { selectionStore.apply(.clear) },
            onDelete: { requestDeleteTargets() })
    }
}

// MARK: - Search mode toggle (app-chrome segmented control)

/// The keyword / meaning switch. Was its own `field` capsule holding two pills, with
/// the live one raised to `selection`; it now draws from the shared
/// ``SegmentedControl``, which marks the current value with a border instead. The app
/// had two segmented idioms and this was the second one — a switch that reads
/// differently here than in the export panels is a design system with a hole in it.
private struct SearchModeToggle: View {
    @Binding var mode: SearchMode

    var body: some View {
        SegmentedControl(
            selection: $mode,
            values: [.keyword, .meaning],
            help: {
                $0 == .keyword
                    ? "Match keywords (title, name, note, text)"
                    : "Match meaning (semantic similarity)"
            }
        ) {
            Text($0 == .keyword ? "Keyword" : "Meaning")
        }
    }
}

// MARK: - Detail overlay for a search result

/// The presentation-only `ItemDetailView` for a search hit — an asset with no
/// folder membership (so no folder remove/delete), with prev/next across the
/// result set and asset-scoped tags via `AssetTagsStore`.
private struct SearchDetailOverlay: View {
    let services: AppServices
    @ObservedObject var model: IngestionModel
    /// The run the page walks AND the grouping that ordered it — one derivation, so
    /// the pager and the post chip cannot tell different stories (080 §4).
    let context: SearchDetailContext
    @Binding var current: AssetDetail?

    @StateObject private var tags: AssetTagsStore

    private var results: [AssetDetail] { context.run }

    init(services: AppServices, model: IngestionModel,
         context: SearchDetailContext, current: Binding<AssetDetail?>) {
        self.services = services
        self.model = model
        self.context = context
        _current = current
        _tags = StateObject(wrappedValue: AssetTagsStore(services: services))
    }

    var body: some View {
        Group {
            if let asset = current?.asset, let detail = current {
                let sourceURL = detail.source.originalURL
                let hasSource = !(sourceURL ?? "").isEmpty
                let hasBlob = model.blobURL(forAsset: asset) != nil
                let index = results.firstIndex { $0.asset.id == asset.id }
                ItemDetailView(
                    asset: asset,
                    source: detail.source,
                    blobURL: model.blobURL(forAsset: asset),
                    previewImage: nil,
                    tags: tags.tags,
                    onAddTag: { tags.add($0) },
                    onRemoveTag: { tags.remove($0) },
                    collections: tags.collections,
                    allCollections: tags.allCollections,
                    onAddToCollection: { tags.addToCollection($0) },
                    onRemoveFromCollection: { tags.removeFromCollection($0) },
                    onSetName: { tags.setName($0) },
                    onSetNote: { tags.setNote($0) },
                    actions: ItemDetailActions(
                        openSource: hasSource ? { model.openSourceURL(sourceURL) } : nil,
                        openBlob: hasBlob ? { model.openBlob(asset: asset) } : nil,
                        revealInFinder: hasBlob ? { model.revealInFinder(asset: asset) } : nil,
                        copySourceLink: hasSource ? { model.copySourceLink(url: sourceURL) } : nil,
                        removeFromFolder: nil,
                        requestDelete: nil,
                        // The model's undoable writer, as on the collection host: it
                        // bumps `contentsVersion`, which the results grid already
                        // watches to re-run the query — so the hit's star repaints
                        // instead of going stale behind the page.
                        setFavorite: { model.setFavorite($0, assetIDs: [asset.id]) }),
                    navigator: index.map { i in
                        ItemDetailNavigator(index: i, count: results.count) { delta in
                            let target = i + delta
                            if results.indices.contains(target) {
                                current = results[target]
                                model.recordView(assetID: results[target].asset.id)
                            }
                        }
                    },
                    // The post the page is inside (080 §3.1), off the SAME grouping
                    // that produced `results` above. Search's synthetic membership
                    // makes `item.id == asset.id`, so the asset id is the key.
                    post: context.groups.detailPost(
                        forItem: asset.id,
                        thumbnailURL: { model.thumbnailURL(forBlobHash: $0) },
                        jump: { target in
                            // Clamped by the CALLEE (080 §3.1): a re-run can shrink the
                            // post under an armed jump, and the run is re-derived with
                            // it, so both the member and its place are resolved fresh.
                            let members = context.groups.members(forItem: asset.id)
                            guard !members.isEmpty else { return }
                            let member = members[min(max(0, target), members.count - 1)]
                            guard let hit = results.first(where: { $0.asset.id == member })
                            else { return }
                            current = hit
                            model.recordView(assetID: hit.asset.id)
                        }),
                    onClose: {
                        model.flushViewBumps()
                        withAnimation { current = nil }
                    })
                    .task(id: asset.id) { tags.bind(to: asset.id) }
                    .onChange(of: tags.lastError) { _, message in
                        if let message { model.lastError = message; tags.lastError = nil }
                    }
            }
        }
    }
}
