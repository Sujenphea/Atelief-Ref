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
import Combine
import SwiftUI

// MARK: - Token + scope

/// One selected tag filter in the search field.
struct TagToken: Identifiable, Hashable {
    let tag: Tag
    var id: UUID { tag.id }
}

/// The Collection-screen scope toggle. Ignored on the global gallery.
enum SearchScope: Hashable {
    case thisCollection
    case all
}

// MARK: - Model

@MainActor
final class LibrarySearchModel: ObservableObject {
    /// The free-text (FTS) query; also the live prefix that drives suggestions.
    @Published var text = ""
    /// The selected tag filters (ANDed).
    @Published var tokens: [TagToken] = []
    /// Collection-screen scope. Defaults per screen in `configure`.
    @Published var scope: SearchScope = .all
    /// Prefix-matched tag suggestions for the current `text`.
    @Published private(set) var suggestions: [TagToken] = []
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
        guard let services, isActive else {
            results = []; resultsVersion &+= 1; isRunning = false; queryFailed = false
            return
        }
        let text = self.text
        let tagIDs = tokens.map(\.tag.id)
        let scoped = (collectionID != nil && scope == .thisCollection) ? collectionID : nil
        isRunning = true
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            do {
                let hits = try await services.searchAssets(
                    text: text, tagIDs: tagIDs, tagMatch: .all,
                    collectionID: scoped, limit: 500)
                guard !Task.isCancelled else { return }
                results = hits
                resultsVersion &+= 1
                queryFailed = false
            } catch {
                // Surface the failure distinctly — an empty `results` alone reads as
                // "no matches" and hides that the search actually errored.
                results = []
                resultsVersion &+= 1
                queryFailed = true
            }
            isRunning = false
        }
    }

    private func refreshSuggestions() {
        suggestTask?.cancel()
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let services, !prefix.isEmpty else { suggestions = []; return }
        let selected = Set(tokens.map(\.id))
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let tags = (try? await services.tagVocabulary(prefix: prefix, limit: 8)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = tags.map(TagToken.init).filter { !selected.contains($0.id) }
        }
    }
}

// MARK: - Searchable container

/// Wraps a screen's `content`, adds the token search field, and swaps in the
/// results grid (with an asset-scoped detail overlay) while a search is active.
struct LibrarySearchable<Content: View>: View {
    @ObservedObject var model: IngestionModel
    /// The screen's collection, or `nil` for the global gallery.
    let collectionID: UUID?
    @ViewBuilder let content: () -> Content

    @StateObject private var search = LibrarySearchModel()
    @State private var detail: AssetDetail?

    var body: some View {
        ZStack {
            if search.isActive {
                LibrarySearchResults(model: model, search: search) { asset in
                    model.recordView(assetID: asset.asset.id)
                    detail = asset
                }
            } else {
                content()
            }

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
        .onChange(of: search.scope) { _, _ in search.configure(services: model.services, collectionID: collectionID) }
    }
}

/// Applies `.searchable` (+ scopes when the screen is collection-scoped). A
/// separate modifier so the scope toggle can be applied conditionally.
private struct SearchFieldModifier: ViewModifier {
    @ObservedObject var search: LibrarySearchModel

    func body(content: Content) -> some View {
        let field = content
            .searchable(
                text: $search.text,
                tokens: $search.tokens,
                suggestedTokens: Binding(get: { search.suggestions }, set: { _ in }),
                prompt: "Search title, author, or #tag"
            ) { token in
                Label(token.tag.name,
                      systemImage: token.tag.source == .agent ? "sparkles" : "tag")
            }
        if search.showsScopeToggle {
            field.searchScopes($search.scope) {
                Text("This Collection").tag(SearchScope.thisCollection)
                Text("All").tag(SearchScope.all)
            }
        } else {
            field
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
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(search.results, id: \.asset.id) { detail in
                    resultCell(detail)
                }
            }
            .padding(12)
        }
        .focusable()
        .focusEffectDisabled()
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
        .contextMenu { cellMenu(for: detail) }
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
