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
        // Bind the shared single-selection model to THIS collection whenever the
        // screen appears (fresh push, or a pop back onto it).
        .task(id: collectionID) {
            model.selectedFolderID = collectionID
            model.loadContents(of: collectionID)
        }
        .navigationTitle(model.name(for: collectionID))
        .toolbar {
            ToolbarItem { sortMenu }
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

    /// The grid sort control (007 G4). A menu-styled picker bound to the stored
    /// per-collection mode; picking one persists it and reloads the grid.
    private var sortMenu: some View {
        let selection = Binding(
            get: { model.sortMode(for: collectionID) },
            set: { model.setSortMode($0, for: collectionID) })
        return Menu {
            Picker("Sort", selection: selection) {
                Label("Manual", systemImage: "hand.draw").tag(SortMode.manual)
                Label("Newest", systemImage: "clock").tag(SortMode.newest)
                Label("Most Viewed", systemImage: "eye").tag(SortMode.mostViewed)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort: \(Self.sortLabel(model.sortMode(for: collectionID)))",
                  systemImage: "arrow.up.arrow.down")
        }
        .help("Choose how this collection's grid is ordered")
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
            dropZone
            if !model.subfolders.isEmpty {
                subfolderChips
            }
            grid
        }
        .padding()
    }

    private var header: some View {
        HStack {
            Text(model.name(for: collectionID)).font(.title2).bold()
            Text("\(model.items.count) items")
                .font(.callout).foregroundStyle(.secondary)
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

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26))
                    Text("Drop images or files into “\(model.name(for: collectionID))”")
                        .font(.callout)
                    if let progress = model.progress {
                        ProgressView(
                            value: Double(progress.completed),
                            total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 200)
                        Text("\(progress.completed) / \(progress.total)")
                            .font(.caption).monospacedDigit()
                    } else if let status = model.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .onDrop(of: [.image, .fileURL, .url], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
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
                                AsyncThumbnail(
                                    hash: detail.asset.blobHash,
                                    url: model.thumbnailURL(for: detail),
                                    isSelected: model.selectedItemID == detail.item.id)
                            }
                            .buttonStyle(.plain)
                            .id(detail.item.id)
                            .draggable(detail.asset.id.uuidString)
                            .dropDestination(for: String.self) { payloads, _ in
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
                openBlob: { model.openBlob(detail) },
                revealInFinder: { model.revealInFinder(detail) },
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

    private func reorder(dropped payloads: [String], onto targetAssetID: UUID) -> Bool {
        // Reordering only means something in manual mode — reject the drop
        // otherwise (the model guards too, so this is the visual half).
        guard model.sortMode(for: collectionID) == .manual,
              let first = payloads.first, let movingAssetID = UUID(uuidString: first)
        else { return false }
        model.reorderItem(movingAssetID: movingAssetID, toIndexOf: targetAssetID)
        return true
    }

    // MARK: - Import actions

    private func paste() {
        guard model.isReady else { return }
        let pasteboard = NSPasteboard.general
        let inputs = DirectInputReader.inputs(
            from: pasteboard, into: collectionID, now: Date())
        if !inputs.isEmpty {
            model.run(inputs: inputs)
        } else if let url = Self.firstWebURL(on: pasteboard) {
            model.ingestRemoteImage(from: url)
        } else {
            model.reportUnreadableDrop()
        }
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
        return nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.isReady else { return false }
        let target = collectionID
        Task {
            let webURL = await Self.firstWebURL(in: providers)
            var inputs: [IngestInput] = []
            for provider in providers {
                if let input = await Self.input(from: provider, pageURL: webURL, into: target) {
                    inputs.append(input)
                }
            }
            if !inputs.isEmpty {
                model.run(inputs: inputs)
            } else if let webURL {
                model.ingestRemoteImage(from: webURL)
            } else {
                model.reportUnreadableDrop()
            }
        }
        return true
    }

    private nonisolated static func input(
        from provider: NSItemProvider, pageURL: URL?, into collectionID: UUID
    ) async -> IngestInput? {
        let now = Date()
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider), url.isFileURL {
            return DirectInputReader.fileInput(fileURL: url, into: collectionID, at: now)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider, type: UTType.image.identifier) {
            if let pageURL {
                return DirectInputReader.browserImageInput(
                    imageData: data, pageURL: pageURL, into: collectionID, at: now)
            }
            return DirectInputReader.pasteInput(
                imageData: data, sourceURL: nil, into: collectionID, at: now)
        }
        return nil
    }

    private nonisolated static func firstWebURL(in providers: [NSItemProvider]) async -> URL? {
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                  !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            else { continue }
            if let url = await loadURL(provider), DirectInputReader.isWebURL(url) {
                return url
            }
        }
        return nil
    }

    private nonisolated static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private nonisolated static func loadData(
        _ provider: NSItemProvider, type: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
