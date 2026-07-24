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
/// search is active. Native means Esc-to-clear, the focus ring, the cancel button, and
/// the standard scope bar all come for free.
struct LibrarySearchable<Content: View>: View {
    @ObservedObject var model: IngestionModel
    /// The screen's collection, or `nil` for the global gallery.
    let collectionID: UUID?
    @ViewBuilder let content: () -> Content

    @StateObject private var search = LibrarySearchModel()
    @State private var detail: AssetDetail?

    var body: some View {
        ZStack {
            Group {
                if search.isActive {
                    LibrarySearchResults(model: model, search: search) { asset in
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
            // Native segmented toggle under the field (047 · 3a · 10A): keyword FTS
            // vs semantic meaning. Appears while the search field is active.
            .searchScopes($search.mode) {
                Text("Keyword").tag(SearchMode.keyword)
                Text("Meaning").tag(SearchMode.meaning)
            }
    }
}

// MARK: - Results grid

private struct LibrarySearchResults: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var search: LibrarySearchModel
    let onOpen: (AssetDetail) -> Void

    // Multi-select over the result set, reusing the pure grid reducer (asset ids as
    // the selection universe — search hits have no folder membership). This closes
    // the "triage dead-end": found items can be picked and acted on (007 G2 / 034
    // P2). Arrow-cursor + marquee are intentionally NOT ported — the adaptive
    // LazyVGrid has no analytic frames to drive them; click / ⌘ / ⇧ / ⌘A / Delete
    // / Esc cover keyboard-and-mouse triage.
    @State private var selection = GridSelection()
    /// The hovered cell (drives the selection circle), keyed off the cell CONTAINER
    /// so moving onto the circle doesn't flicker it away (see CollectionView 149).
    @State private var hoveredID: UUID?
    @Environment(\.displayScale) private var displayScale

    // Marquee drag-select (009 · N6): result-cell frames captured in a shared named
    // coordinate space, hit-tested by the pure `marqueeRect`/`marqueeIndices`.
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    private static let gridSpace = "searchResultsContent"

    /// The widest a result cell can draw — the `columns` maximum below. Kept next
    /// to it so the thumbnail bucket can't drift from the layout that sets it.
    private static let maxCellSide: CGFloat = 140
    private let columns = [GridItem(.adaptive(minimum: 112, maximum: maxCellSide), spacing: 8)]

    /// The result set's asset ids in display order — the reducer's `order`.
    private var orderIDs: [UUID] { search.results.map(\.asset.id) }

    var body: some View {
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

    private var resultsGrid: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // The drag catcher sits BEHIND the cells: a drag on empty area starts
                // a marquee; a drag on a cell drags the asset(s) out (see resultCell).
                marqueeCatcher
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(search.results, id: \.asset.id) { detail in
                        resultCell(detail)
                    }
                }
                .padding(12)
                marqueeOverlay
            }
            .coordinateSpace(.named(Self.gridSpace))
        }
        .focusable()
        .focusEffectDisabled()
        .overlay(alignment: .bottom) {
            if selection.isSelecting { selectionBar }
        }
        // Prune a stale multi-selection whenever the query's results change.
        .onChange(of: search.resultsVersion) { _, _ in
            selection = selection.pruned(to: orderIDs)
        }
        // A triage delete removes a hit from the library — re-run the query so the
        // stale card leaves the grid (contentsVersion bumps when the delete reloads).
        .onChange(of: model.contentsVersion) { _, _ in search.rerun() }
        .onDeleteCommand { requestDeleteTargets() }
        .onKeyPress(.escape) {
            guard selection.isSelecting else { return .ignored }
            apply(.clear)
            return .handled
        }
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            apply(.selectAll)
            return .handled
        }
        .onKeyPress(.return) {
            apply(.openLead)
            return selection.lead == nil ? .ignored : .handled
        }
    }

    /// One result cell: the thumbnail with a selection border + hover/selection
    /// circle, click routing (plain opens / ⌘ / ⇧ select), and a batch context menu.
    private func resultCell(_ detail: AssetDetail) -> some View {
        let id = detail.asset.id
        let isSelected = selection.ids.contains(id)
        let showsCircle = selection.isSelecting || hoveredID == id
        return ZStack(alignment: .topTrailing) {
            Button {
                let flags = NSEvent.modifierFlags
                guard !flags.contains(.shift), !flags.contains(.command) else { return }
                apply(gridClickAction(imageID: id, shift: false, command: false), open: detail)
            } label: {
                // 140 pt (the columns maximum) → 280 px at 2× → the 384 bucket.
                AssetContentThumbnail(
                    asset: detail.asset,
                    url: model.thumbnailURL(forAsset: detail.asset),
                    isSelected: isSelected,
                    bucket: thumbnailPixelBucket(
                        pointLongSide: Self.maxCellSide, scale: displayScale))
            }
            .buttonStyle(.plain)
            // ⌘/⇧ clicks: a SwiftUI Button doesn't fire reliably on a modified click,
            // so modifier-aware tap gestures own them (mirrors CollectionCell).
            .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                apply(.commandClick(id))
            })
            .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
                apply(.shiftClick(id))
            })
            .overlay {
                if selection.lead == id && !isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            if showsCircle {
                selectionCircle(id: id, isSelected: isSelected).transition(.opacity)
            }
        }
        .onHover { hovering in
            if hovering { hoveredID = id }
            else if hoveredID == id { hoveredID = nil }
        }
        .animation(.easeInOut(duration: 0.12), value: showsCircle)
        // Drag the asset(s) OUT onto a sidebar collection/space row. A selected cell
        // carries the whole selection; an unselected cell carries just itself. Search
        // hits are membership-less, so the sentinel source makes every drop a COPY
        // (add) — never a move (009 · N3 / N6).
        .draggable(dragPayload(for: id))
        // Publish this cell's frame for the marquee hit-test.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: {
            cardFrames[id] = $0
        }
        .contextMenu { cellMenu(for: detail) }
    }

    // MARK: - Marquee + action bar (009 · N6)

    /// The transparent layer behind the cells that begins a marquee on an empty-area
    /// drag and clears the selection on an empty-area click.
    private var marqueeCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.gridSpace))
                    .onChanged { value in
                        marqueeStart = value.startLocation
                        marqueeCurrent = value.location
                        updateMarqueeSelection()
                    }
                    .onEnded { _ in
                        marqueeStart = nil
                        marqueeCurrent = nil
                    })
            .onTapGesture { if selection.isSelecting { apply(.clear) } }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = marqueeRect(from: start, to: current)
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func updateMarqueeSelection() {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let rect = marqueeRect(from: start, to: current)
        let valid = Set(orderIDs)
        let entries = cardFrames.filter { valid.contains($0.key) }
        let ids = Array(entries.keys)
        let frames = ids.map { entries[$0]! }
        let hits = Set(marqueeIndices(in: rect, frames: frames).map { ids[$0] })
        apply(.marquee(hits: hits, base: []))
    }

    /// The floating "N selected · Clear · Delete" bar, shown while a selection is
    /// active. Delete routes through the same staged/undoable asset delete as the
    /// keyboard and context menu.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.ids.count) selected")
                .font(.callout.weight(.medium))
            Button("Clear") { apply(.clear) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button(role: .destructive) { requestDeleteTargets() } label: {
                Label("Delete \(selection.ids.count)", systemImage: "trash")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(radius: 8, y: 2)
        .padding(.bottom, 16)
    }

    /// The payload a cell drag carries: the whole selection when the dragged cell is
    /// part of it, else just that cell. The sentinel source marks it membership-less
    /// so drops COPY (add) rather than move (009 · N3).
    private func dragPayload(for id: UUID) -> AssetDragPayload {
        let ids = (selection.isSelecting && selection.ids.contains(id))
            ? Array(selection.ids) : [id]
        return AssetDragPayload(assetIDs: ids, sourceCollectionID: AssetDragPayload.nilSourceID)
    }

    private func selectionCircle(id: UUID, isSelected: Bool) -> some View {
        Button {
            apply(.tapCircle(id))
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isSelected ? Color.white : Color.white.opacity(0.95),
                    isSelected ? Color.accentColor : Color.black.opacity(0.35))
                .background(Circle().fill(.black.opacity(0.15)).padding(1))
                .padding(6)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Deselect" : "Select")
        .accessibilityHidden(true)
    }

    /// Finder-scope batch menu: a right-click on a SELECTED cell acts on the whole
    /// selection; on an unselected cell it acts on that one and leaves the selection
    /// untouched. Only the verbs that make sense for a membership-less hit —
    /// Add-to-Collection (copy) and Delete; Reveal in Finder for a lone byte-backed
    /// item.
    @ViewBuilder
    private func cellMenu(for detail: AssetDetail) -> some View {
        let id = detail.asset.id
        let targets = (selection.isSelecting && selection.ids.contains(id))
            ? Array(selection.ids) : [id]
        let n = targets.count
        Menu("Add to Collection") {
            ForEach(addTargets) { c in
                Button(c.name) { model.copyToCollection(assetIDs: targets, to: c.id) }
            }
        }
        if n == 1, model.blobURL(forAsset: detail.asset) != nil {
            Button("Reveal in Finder") { model.revealInFinder(asset: detail.asset) }
        }
        Divider()
        Button("Delete\(n > 1 ? " (\(n))" : "")", role: .destructive) {
            model.requestDelete(assetIDs: targets)
        }
    }

    /// Every collection as a copy target, Unsorted pinned first (search has no
    /// source folder to exclude, so all are offered).
    private var addTargets: [Collection] {
        let unsorted = model.folders.filter { $0.id == model.unsortedFolderID }
        let rest = model.folders
            .filter { $0.id != model.unsortedFolderID }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        return unsorted + rest
    }

    /// The ids a keyboard verb (Delete) acts on: the selection while selecting, else
    /// the cursor's lone item.
    private func requestDeleteTargets() {
        let targets = selection.isSelecting
            ? Array(selection.ids) : (selection.lead.map { [$0] } ?? [])
        guard !targets.isEmpty else { return }
        model.requestDelete(assetIDs: targets)
    }

    /// Apply a reducer action against the current result order; open the detail
    /// page when the effect asks for it.
    private func apply(_ action: GridSelectionAction, open detail: AssetDetail? = nil) {
        let (next, effect) = selection.applying(action, order: orderIDs)
        selection = next
        if case let .openDetail(openID) = effect,
           let hit = detail ?? search.results.first(where: { $0.asset.id == openID }) {
            onOpen(hit)
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
