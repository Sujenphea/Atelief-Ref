//
//  LibrarySearch.swift
//  AtelierRefs
//
//  007 G2 — the search surface: a `.searchable` token field where typed free
//  text is FTS (source title / author) and selected tokens are structured tag
//  filters (default AND). Global on the Collections gallery, collection-scoped
//  (with a This-collection / All toggle) on a Collection screen. Results reuse
//  the thumbnail grid and open the presentation-only `ItemDetailView`.
//
//  Tag tokens resolve to ids before querying, so tag text never leaks into FTS
//  (a silent miss). Agent-applied tags are suggestible too, distinguished by a
//  sparkles glyph.
//

import AppKit
import AtelierCore
import AtelierIngestion
import Combine
import os
import SwiftUI

// MARK: - Token + scope

/// One selected filter chip in the search field (044/045 · 16A/17A). A tag
/// narrows by structured id; a collection scopes to its membership. Multiple
/// collection tokens OR (member of ANY); tags AND. Selecting a suggested token
/// resolves free text to one of these before it ever reaches FTS.
enum SearchToken: Identifiable, Hashable {
    case tag(Tag)
    case collection(Collection)

    var id: UUID {
        switch self {
        case .tag(let tag): return tag.id
        case .collection(let collection): return collection.id
        }
    }

    var displayName: String {
        switch self {
        case .tag(let tag): return tag.name
        case .collection(let collection): return collection.name
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

    private static let logger = Logger(subsystem: "so.atelier.refs", category: "search")

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
                collectionIDs: scopeIDs, sort: .relevance)
            run = runSemanticQuery
        } else {
            query = LibrarySearchQuery(
                text: fts,
                tagIDs: selectedTagIDs,
                tagNameContains: tagNeedle,
                collectionIDs: scopeIDs,
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
                Self.logger.error("search query failed: \(String(describing: error))")
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
                Self.logger.error("suggestion fetch failed: \(String(describing: error))")
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

/// Wraps a screen's `content`, adds the NATIVE `.searchable` token field (in the window
/// toolbar), and swaps in the results grid (with an asset-scoped detail overlay) while a
/// search is active. Native means Esc-to-clear, the focus ring, and the cancel button
/// all come for free. The keyword / meaning mode toggle is a custom control at the top
/// of the results grid (not a native scope bar) — see `LibrarySearchResults.modePicker`.
struct LibrarySearchable<Content: View>: View {
    @ObservedObject var model: IngestionModel
    /// The global grid density notch — search results honour the SAME persisted
    /// density (and zoom controls) as the collection grid, instead of a fixed 4-up.
    @ObservedObject var gridPrefs: GridViewPreferences
    /// The screen's collection, or `nil` for the global gallery.
    let collectionID: UUID?
    @ViewBuilder let content: () -> Content

    @StateObject private var search = LibrarySearchModel()
    @State private var detail: AssetDetail?

    var body: some View {
        ZStack {
            Group {
                if search.isActive {
                    LibrarySearchResults(model: model, search: search, gridPrefs: gridPrefs) { asset in
                        model.recordView(assetID: asset.asset.id)
                        detail = asset
                    }
                } else {
                    content()
                }
            }
            // URL-bar behaviour: clicking anywhere in the content — including empty
            // space — blurs the native search field. Guarded to `NSText` (the field
            // editor) so it only fires while a text field is being edited, never
            // interfering with grid selection / keyboard nav.
            .simultaneousGesture(TapGesture().onEnded {
                if let window = NSApp.keyWindow, window.firstResponder is NSText {
                    window.makeFirstResponder(nil)
                }
            })

            if let services = model.services, detail != nil {
                SearchDetailOverlay(
                    services: services, model: model,
                    results: search.results, current: $detail)
                    .transition(.opacity)
            }
        }
        .modifier(SearchFieldModifier(search: search))
        .task(id: model.isReady) {
            search.configure(services: model.services, collectionID: collectionID)
        }
        .onChange(of: search.text) { _, _ in search.textChanged() }
        .onChange(of: search.tokens) { _, _ in search.tokensChanged() }
        .onChange(of: search.mode) { _, _ in search.modeChanged() }
        .onChange(of: search.scope) { _, _ in search.configure(services: model.services, collectionID: collectionID) }
    }
}

/// Applies the native `.searchable` token field. No scope bar — on a Collection the
/// search stays scoped to that collection (the model's default); elsewhere it's global.
/// The keyword / meaning mode toggle (047 · 3a) is NOT a native `.searchScopes` bar —
/// it's a custom segmented control at the top of the results panel (`LibrarySearchResults`).
private struct SearchFieldModifier: ViewModifier {
    @ObservedObject var search: LibrarySearchModel

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $search.text,
                tokens: $search.tokens,
                suggestedTokens: Binding(get: { search.suggestions }, set: { _ in }),
                prompt: "Search title, name, note, text, or tag: / collection"
            ) { token in
                switch token {
                case .tag(let tag):
                    Label(tag.name,
                          systemImage: tag.source == .agent ? "sparkles" : "tag")
                case .collection(let collection):
                    Label(collection.name, systemImage: "folder")
                }
            }
    }
}

// MARK: - Results grid

private struct LibrarySearchResults: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var search: LibrarySearchModel
    @ObservedObject var gridPrefs: GridViewPreferences
    let onOpen: (AssetDetail) -> Void

    /// The live grid width, captured for the ⌘± density clamp (mirrors
    /// `CollectionView.gridWidth`), so zoom respects the 512px cell cap.
    @State private var gridWidth: CGFloat = 1

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

    /// A stable, membership-less sentinel "collection" id for the host. Search hits
    /// belong to no collection; a constant keeps the host from resetting scroll
    /// between queries and marks every drag-out payload as a copy (009 · N3).
    private static let searchScopeID = AssetDragPayload.nilSourceID

    /// The 84 pt / 192-bucket drag preview — the small precomputed image the AppKit
    /// grid uses, NOT a snapshot of the full 384-bucket cell (048 · the old lag).
    private static let dragPreviewSide: CGFloat = 84

    /// The result set's asset ids in display order — the reducer's `order`.
    private var orderIDs: [UUID] { search.results.map(\.asset.id) }

    /// A synthetic membership per hit so the host (keyed on `item.id`) can render
    /// search results. `item.id == asset.id` so every host closure keyed on the cell
    /// id coincides with the asset id — no id mapping anywhere. `collectionID` is the
    /// sentinel scope; placement fields are unused (no reorder, array order stands).
    private var items: [CollectionItemDetail] {
        search.results.map { detail in
            CollectionItemDetail(
                item: CollectionItem(
                    id: detail.asset.id,
                    collectionID: Self.searchScopeID,
                    assetID: detail.asset.id,
                    addedAt: detail.asset.createdAt),
                asset: detail.asset,
                source: detail.source)
        }
    }

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
    }

    /// The keyword / meaning mode toggle (047 · 3a · 10A), relocated out of the native
    /// `.searchScopes` bar to the top of the results panel: `.keyword` runs FTS
    /// prefix / substring / relevance, `.meaning` embeds the text and ranks by cosine
    /// similarity. Leading-aligned and intrinsically sized so it reads as a control,
    /// not a full-width bar. `search.mode`'s `onChange` (in `LibrarySearchable`) re-runs.
    private var modePicker: some View {
        HStack {
            Picker("Search mode", selection: $search.mode) {
                Text("Keyword").tag(SearchMode.keyword)
                Text("Meaning").tag(SearchMode.meaning)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            // The result count, styled like every other page's "N items" subtitle
            // so search reads as another counted surface.
            if !search.results.isEmpty {
                Text("\(search.results.count) results")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
        }
        // Share the collection grid's 24pt content margin so the mode toggle's left
        // edge aligns with the grid below it.
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
                if selectionStore.selection.isSelecting { selectionBar }
            }
            // Keep the reducer's feed order in step with the results (the host does
            // not push this itself — the collection grid's model does). Prune a stale
            // multi-selection to the surviving ids whenever the query changes.
            .onAppear { selectionStore.setOrder(orderIDs) }
            .onChange(of: search.resultsVersion) { _, _ in
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
            items: items,
            itemsVersion: search.resultsVersion,
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
            onRequestDelete: { requestDeleteTargets() },
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
            moveTargets: moveTargets,
            onMoveToCollection: { _, _ in },   // membership-less: never moves
            onCopyToCollection: { ids, target in model.copyToCollection(assetIDs: ids, to: target) },
            onSetCover: { _ in },
            onRemoveFromCollection: { _ in },
            onDelete: { ids in model.requestDelete(assetIDs: ids) },
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
        return (selection.isSelecting && selection.ids.contains(id))
            ? Array(selection.ids) : [id]
    }

    /// The ids a keyboard/bar Delete acts on: the selection while selecting, else the
    /// cursor's lone item.
    private func requestDeleteTargets() {
        let selection = selectionStore.selection
        let targets = selection.isSelecting
            ? Array(selection.ids) : (selection.lead.map { [$0] } ?? [])
        guard !targets.isEmpty else { return }
        model.requestDelete(assetIDs: targets)
    }

    /// Every collection as a copy target, Unsorted pinned first (search has no source
    /// folder to exclude, so all are offered as roots — no subfolder grouping).
    private var moveTargets: MoveTargets {
        let unsorted = model.folders.filter { $0.id == model.unsortedFolderID }
        let rest = model.folders
            .filter { $0.id != model.unsortedFolderID }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        return MoveTargets(subfolders: [], roots: unsorted + rest)
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
                        .font(.caption2).bold().monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(4)
                }
            }
    }

    // MARK: - Selection bar

    /// The floating "N selected · Clear · Delete" bar, shown while a selection is
    /// active. Delete routes through the same staged/undoable asset delete as the
    /// keyboard and context menu.
    private var selectionBar: some View {
        let count = selectionStore.selection.ids.count
        return HStack(spacing: 2) {
            Text("\(count) selected")
                .font(.callout.weight(.medium))
                .padding(.trailing, 10)
            SelectionBarButton("xmark", help: "Clear selection") {
                selectionStore.apply(.clear)
            }
            // `requestDelete` runs its own confirmation, so no extra dialog here.
            SelectionBarButton("trash", help: "Delete \(count)", role: .destructive) {
                requestDeleteTargets()
            }
        }
        .selectionBarChrome()
    }
}

// MARK: - Detail overlay for a search result

/// The presentation-only `ItemDetailView` for a search hit — an asset with no
/// folder membership (so no folder remove/delete), with prev/next across the
/// result set and asset-scoped tags via `AssetTagsStore`.
private struct SearchDetailOverlay: View {
    let services: AppServices
    @ObservedObject var model: IngestionModel
    let results: [AssetDetail]
    @Binding var current: AssetDetail?

    @StateObject private var tags: AssetTagsStore

    init(services: AppServices, model: IngestionModel,
         results: [AssetDetail], current: Binding<AssetDetail?>) {
        self.services = services
        self.model = model
        self.results = results
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
                        requestDelete: nil),
                    navigator: index.map { i in
                        ItemDetailNavigator(index: i, count: results.count) { delta in
                            let target = i + delta
                            if results.indices.contains(target) {
                                current = results[target]
                                model.recordView(assetID: results[target].asset.id)
                            }
                        }
                    },
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
