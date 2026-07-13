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
    /// A query is in flight (drives a subtle progress affordance).
    @Published private(set) var isRunning = false

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
    }

    // MARK: queries

    private func runSearch() {
        queryTask?.cancel()
        guard let services, isActive else {
            results = []; isRunning = false
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
            } catch {
                results = []
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

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 8)]

    var body: some View {
        Group {
            if search.results.isEmpty {
                ContentUnavailableView(
                    search.isRunning ? "Searching…" : "No results",
                    systemImage: search.isRunning ? "hourglass" : "magnifyingglass",
                    description: Text(search.isRunning
                        ? "Looking through your library."
                        : "No items match this search."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(search.results, id: \.asset.id) { asset in
                            Button { onOpen(asset) } label: {
                                AssetContentThumbnail(
                                    asset: asset.asset,
                                    url: model.thumbnailURL(forAsset: asset.asset))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
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
