//
//  CollectionView.swift
//  AtelierRefs
//
//  004-P1 — one collection's screen, extracted from the old `LibraryView`
//  detail. Header + drop target + navigable subfolder chips + a thumbnail grid
//  of the collection's DIRECT items, plus the import affordances (drop + ⌘V)
//  targeting this collection. Drilling into a subfolder pushes another
//  `CollectionView` (via `NavModel`) rather than mutating a shared selection.
//  The full-window item detail overlay keeps a LOCAL flag until 006 wires
//  `NavModel.presentedItemID`.
//

import AppKit
import AtelierCore
import AtelierIngestion
import SwiftUI
import UniformTypeIdentifiers

struct CollectionView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    let collectionID: UUID

    @State private var isTargeted = false

    private static let gridItemMinWidth: CGFloat = 112
    private static let gridSpacing: CGFloat = 8
    private let columns = [
        GridItem(.adaptive(minimum: gridItemMinWidth, maximum: 140), spacing: gridSpacing)
    ]

    var body: some View {
        LibrarySearchable(model: model, collectionID: collectionID) {
            ZStack {
                content
                // Full-window detail page for the presented item. The overlay is
                // shared route state (`NavModel.presentedItemID`) so the grid, the
                // Return key, and the Space canvas can all open it; guarding also on
                // `selectedItem != nil` auto-dismisses back to the grid when the item
                // is removed/deleted from inside the page.
                if nav.presentedItemID != nil, let detail = model.selectedItem {
                    detailOverlay(for: detail)
                        .transition(.opacity)
                }
            }
        }
        // Bind the shared single-selection model to THIS collection whenever the
        // screen appears (fresh push, or a pop back onto it).
        .task(id: collectionID) {
            model.selectedFolderID = collectionID
            model.loadContents(of: collectionID)
        }
        .navigationTitle(model.name(for: collectionID))
        .toolbar {
            ToolbarItem { sortMenu }
            ToolbarItem { AddColorButton { model.addColor(hex: $0) } }
            ToolbarItem { AddLinkButton { model.addLink(url: $0) } }
            ToolbarItem {
                Button {
                    Task {
                        if let id = await model.newSpaceFromCollection(collectionID) {
                            nav.openSpace(id)
                        }
                    }
                } label: {
                    Label("New Space from Collection", systemImage: "square.on.square.dashed")
                }
                .help("Create a space seeded from this collection's arrangement")
                .disabled(model.items.isEmpty)
            }
        }
    }

    /// The grid sort control (007 G4). Explicit checkmarked buttons (clearer +
    /// more reliable than a picker-in-menu): each persists the mode and reloads
    /// the grid; a checkmark marks the active one and the label names it.
    private var sortMenu: some View {
        let current = model.sortMode(for: collectionID)
        return Menu {
            sortButton(.manual, "Manual", "hand.draw", current)
            sortButton(.newest, "Newest", "clock", current)
            sortButton(.mostViewed, "Most Viewed", "eye", current)
        } label: {
            Label("Sort: \(Self.sortLabel(current))", systemImage: "arrow.up.arrow.down")
        }
        .help("Choose how this collection's grid is ordered")
    }

    @ViewBuilder
    private func sortButton(
        _ mode: SortMode, _ title: String, _ symbol: String, _ current: SortMode
    ) -> some View {
        Button {
            model.setSortMode(mode, for: collectionID)
        } label: {
            Label(title, systemImage: current == mode ? "checkmark" : symbol)
        }
    }

    private static func sortLabel(_ mode: SortMode) -> String {
        switch mode {
        case .manual: "Manual"
        case .newest: "Newest"
        case .mostViewed: "Most Viewed"
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.subfolders.isEmpty {
                subfolderChips
            }
            grid
        }
        .padding()
        // The whole collection pane is the drop target (the explicit dropzone is
        // gone): a Finder file, a browser image, or a dragged web URL dropped
        // anywhere here imports into this collection. Internal reorder drags carry
        // `AssetDragPayload` (a `.json` UTI), which isn't in this accepted set, so a
        // reorder dropped on an empty gap simply no-ops rather than importing.
        .onDrop(of: [.image, .fileURL, .url], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        // Targeting highlight as an OVERLAY border so only this layer redraws on
        // drag hover — the grid subtree and its cells are untouched (perf).
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.name(for: collectionID)).font(.title2).bold()
            Text("\(model.items.count) items")
                .font(.callout).foregroundStyle(.secondary)
            importStatus
            Spacer()
            Button {
                paste()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!model.isReady)
        }
    }

    /// Live import feedback, re-homed from the old dropzone (3A): a compact
    /// progress bar + count while a drop/paste batch runs, else the latest status
    /// line. Browser/Instagram sweeps report separately via `BulkSweepsView`.
    @ViewBuilder
    private var importStatus: some View {
        if let progress = model.progress {
            HStack(spacing: 6) {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(max(progress.total, 1)))
                .frame(width: 120)
                Text("\(progress.completed) / \(progress.total)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if let status = model.status {
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var subfolderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.subfolders) { folder in
                    Button {
                        nav.openCollection(folder.id)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(model.items, id: \.item.id) { detail in
                            Button {
                                open(detail)
                            } label: {
                                AssetContentThumbnail(
                                    asset: detail.asset,
                                    url: model.thumbnailURL(for: detail),
                                    isSelected: model.selectedItemID == detail.item.id)
                            }
                            .buttonStyle(.plain)
                            .id(detail.item.id)
                            .draggable(AssetDragPayload(assetID: detail.asset.id))
                            .dropDestination(for: AssetDragPayload.self) { payloads, _ in
                                reorder(dropped: payloads, onto: detail.asset.id)
                            }
                            .contextMenu {
                                Button("Remove from Collection") {
                                    model.removeFromFolder(assetIDs: [detail.asset.id])
                                }
                                Button("Set as Cover") {
                                    model.setCollectionCover(collectionID: collectionID, assetID: detail.asset.id)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    model.requestDelete(assetIDs: [detail.asset.id])
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .focusable()
                .onDeleteCommand { model.requestDeleteSelected() }
                .onKeyPress(.return) {
                    guard let detail = model.selectedItem else { return .ignored }
                    open(detail)
                    return .handled
                }
                .onKeyPress(.leftArrow) { move(.left, width: geo.size.width, proxy: proxy) }
                .onKeyPress(.rightArrow) { move(.right, width: geo.size.width, proxy: proxy) }
                .onKeyPress(.upArrow) { move(.up, width: geo.size.width, proxy: proxy) }
                .onKeyPress(.downArrow) { move(.down, width: geo.size.width, proxy: proxy) }
            }
        }
        .overlay {
            if model.items.isEmpty {
                Text("No items in this collection yet.")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Build the full-window detail overlay for `detail`, feeding the
    /// presentation-only ``ItemDetailView`` from this collection's `IngestionModel`
    /// context — full folder actions plus prev/next across `model.items`.
    private func detailOverlay(for detail: CollectionItemDetail) -> some View {
        let hasSource = !(detail.source.originalURL ?? "").isEmpty
        // A media-less kind (003 · O1) has no blob on disk — disable the blob
        // actions rather than wiring them to a no-op.
        let hasBlob = model.blobURL(for: detail) != nil
        let index = model.items.firstIndex { $0.item.id == detail.item.id }
        return ItemDetailView(
            asset: detail.asset,
            source: detail.source,
            blobURL: model.blobURL(for: detail),
            previewImage: model.previewImage,
            tags: model.selectedTags,
            onAddTag: { model.addTag($0) },
            onRemoveTag: { model.removeTag($0) },
            actions: ItemDetailActions(
                openSource: hasSource ? { model.openSource(detail) } : nil,
                openBlob: hasBlob ? { model.openBlob(detail) } : nil,
                revealInFinder: hasBlob ? { model.revealInFinder(detail) } : nil,
                copySourceLink: hasSource ? { model.copySourceLink(detail) } : nil,
                removeFromFolder: { model.removeFromFolder(assetIDs: [detail.asset.id]) },
                requestDelete: { model.requestDelete(assetIDs: [detail.asset.id]) }),
            navigator: index.map { i in
                ItemDetailNavigator(index: i, count: model.items.count) { delta in
                    let target = i + delta
                    if model.items.indices.contains(target) {
                        model.select(model.items[target])
                        // Stepping to a new item in the detail page is a view.
                        model.recordView(assetID: model.items[target].asset.id)
                    }
                }
            },
            onClose: {
                model.flushViewBumps()
                withAnimation { nav.presentedItemID = nil }
            })
    }

    /// Open the full-window detail page for `detail`: bind the shared selection
    /// and raise the overlay via `NavModel.presentedItemID` (the routing seam the
    /// grid click, the Return key, and the Space canvas all funnel through). The
    /// open is the deliberate "view" signal (007 G4).
    private func open(_ detail: CollectionItemDetail) {
        model.select(detail)
        model.recordView(assetID: detail.asset.id)
        withAnimation { nav.presentedItemID = detail.item.id }
    }

    // MARK: - Grid keyboard nav

    private func move(
        _ key: GridArrowKey, width: CGFloat, proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let currentIndex = model.selectedItemID.flatMap { id in
            model.items.firstIndex { $0.item.id == id }
        }
        let columnCount = gridColumnCount(
            availableWidth: width,
            minItemWidth: Self.gridItemMinWidth,
            spacing: Self.gridSpacing)
        guard let target = nextGridIndex(
            from: currentIndex, key: key,
            count: model.items.count, columns: columnCount)
        else { return .ignored }

        let detail = model.items[target]
        if detail.item.id != model.selectedItemID {
            model.select(detail)
        }
        withAnimation { proxy.scrollTo(detail.item.id, anchor: .center) }
        return .handled
    }

    private func reorder(dropped payloads: [AssetDragPayload], onto targetAssetID: UUID) -> Bool {
        // Reordering only means something in manual mode — reject the drop
        // otherwise (the model guards too, so this is the visual half).
        guard model.sortMode(for: collectionID) == .manual,
              let movingAssetID = payloads.first?.assetID
        else { return false }
        model.reorderItem(movingAssetID: movingAssetID, toIndexOf: targetAssetID)
        return true
    }

    // MARK: - Import actions

    /// The shared disposition for both import surfaces (paste + drop): decoded
    /// inputs win; else a web URL is downloaded/resolved; else the drop is reported
    /// as unreadable. `undecoded` (drag path only) rides into the batch so its
    /// completion status can note how many items couldn't be read (7A).
    private func dispatch(inputs: [IngestInput], webURL: URL?, undecoded: Int = 0) {
        if !inputs.isEmpty {
            model.run(inputs: inputs, undecoded: undecoded)
        } else if let webURL {
            model.ingestRemoteImage(from: webURL)
        } else {
            model.reportUnreadableDrop()
        }
    }

    private func paste() {
        guard model.isReady else { return }
        let pasteboard = NSPasteboard.general
        let inputs = DirectInputReader.inputs(
            from: pasteboard, into: collectionID, now: Date())
        dispatch(inputs: inputs, webURL: Self.firstWebURL(on: pasteboard))
    }

    private static func firstWebURL(on pasteboard: NSPasteboard) -> URL? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = objects.first(where: { !$0.isFileURL && DirectInputReader.isWebURL($0) }) {
            return url
        }
        if let string = pasteboard.string(forType: .URL),
           let url = URL(string: string), DirectInputReader.isWebURL(url) {
            return url
        }
        // A URL copied as PLAIN TEXT (the address bar, a message, a doc) carries only
        // `public.utf8-plain-text` — not `.URL` or an NSURL — so parse that too, with a
        // dotted-host guard so arbitrary text isn't mistaken for a link (001 · C2b).
        if let text = pasteboard.string(forType: .string),
           let url = IngestionModel.webURL(fromPastedText: text) {
            return url
        }
        return nil
    }

    /// Decode a drag drop's providers off-main through the shared
    /// ``DirectInputReader`` seam (the same decision order as the pasteboard path),
    /// then dispatch. Returns `true` synchronously to claim the drop.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.isReady else { return false }
        let target = collectionID
        Task {
            let decoded = await DirectInputReader.inputs(
                from: providers, into: target, now: Date())
            dispatch(
                inputs: decoded.inputs,
                webURL: decoded.webURL,
                undecoded: decoded.undecodedCount)
        }
        return true
    }
}
