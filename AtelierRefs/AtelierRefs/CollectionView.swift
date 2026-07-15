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

    // The marquee's per-tick state (009 · N6), a class in plain `@State` ON
    // PURPOSE: only the two layers in `GridMarquee.swift` observe it, so a
    // 120Hz drag re-renders those layers and NOT this whole screen. (`@State`
    // keeps the first instance across re-inits; `@StateObject` would subscribe
    // this view to every tick.)
    @State private var marquee = GridMarqueeState()

    private static let gridItemMinWidth: CGFloat = 112
    private static let gridSpacing: CGFloat = 8
    private static let gridTopInset: CGFloat = 4
    private static let marqueeSpace = "collectionGridContent"
    private let columns = [
        GridItem(.adaptive(minimum: gridItemMinWidth, maximum: 140), spacing: gridSpacing)
    ]

    var body: some View {
        LibrarySearchable(model: model, collectionID: collectionID) {
            ZStack {
                content
                // The floating drop rail (009 · N5) — every collection screen EXCEPT
                // Unsorted, and hidden while the detail page covers the grid.
                if collectionID != model.unsortedFolderID, nav.presentedItemID == nil {
                    dropRail
                }
                // Full-window detail page for the presented item. The overlay is
                // shared route state (`NavModel.presentedItemID`) so the grid, the
                // Return key, and the Space canvas can all open it; guarding also on
                // `selectedItem != nil` auto-dismisses back to the grid when the item
                // is removed/deleted from inside the page.
                if nav.presentedItemID != nil, let detail = model.leadItem {
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
            // Covers feed the rail's mini thumbnails; refresh them for this screen.
            await model.refreshCollectionCovers()
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
            // The stack row is the Unsorted screen's triage surface (009 · N4):
            // drop the selection onto a root collection to move it out of Unsorted.
            if collectionID == model.unsortedFolderID && !model.stackPreviews.isEmpty {
                stackRow
            }
            dropZone
            if !model.subfolders.isEmpty {
                subfolderChips
            }
            grid
        }
        .padding()
    }

    /// The Unsorted-only horizontal row of collection stacks (009 · N4). Each card
    /// is a drop target that MOVES (⌥ copies) the dragged selection out of Unsorted
    /// into that collection, and navigates into it on a plain click.
    private var stackRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.stackPreviews, id: \.collection.id) { preview in
                    StackDropTarget(
                        preview: preview,
                        thumbnailURL: { model.thumbnailURL(forBlobHash: $0) },
                        onNavigate: { nav.openCollection(preview.collection.id) },
                        onDrop: { handleCollectionDrop($0, into: preview.collection.id) })
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// The floating trailing drop rail (009 · N5), materialized only when there
    /// are reachable targets. Aligned to the trailing edge over the grid.
    @ViewBuilder
    private var dropRail: some View {
        let dests = CollectionTargets.moveTargets(
            from: collectionID, folders: model.folders, unsortedID: model.unsortedFolderID)
        if !dests.isEmpty {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CollectionDropRail(
                    targets: dests,
                    coverHash: { model.collectionCovers[$0] },
                    thumbnailURL: { model.thumbnailURL(forBlobHash: $0) },
                    onNavigate: { nav.openCollection($0) },
                    onDrop: { handleCollectionDrop($0, into: $1) })
            }
        }
    }

    /// Route a payload dropped onto a collection target (stack card / rail row)
    /// and apply the move or copy. Shared by the stack row and the drop rail.
    private func handleCollectionDrop(_ payload: AssetDragPayload, into targetID: UUID) -> Bool {
        switch routeDrop(
            payload, onto: .collection(targetID), optionDown: Self.modifierReader.isOptionDown) {
        case let .move(assetIDs, _, to):
            model.moveToCollection(assetIDs: assetIDs, to: to)
            return true
        case let .copy(assetIDs, to):
            model.copyToCollection(assetIDs: assetIDs, to: to)
            return true
        case .reject, .reorder:
            return false
        }
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
                    ZStack(alignment: .topLeading) {
                        // Background capture layer (009 · N6): a drag on EMPTY space
                        // is a marquee (image-drags hit the cells above and mean
                        // move/copy); a plain click clears the selection. Sized to
                        // the grid via the ZStack, in a named space so drag
                        // locations match the computed cell frames.
                        MarqueeCaptureLayer(
                            state: marquee,
                            width: geo.size.width,
                            itemIDs: model.items.map { $0.item.id },
                            minItemWidth: Self.gridItemMinWidth,
                            spacing: Self.gridSpacing,
                            topInset: Self.gridTopInset,
                            spaceName: Self.marqueeSpace,
                            selectionIDs: model.selection.ids,
                            onMarquee: { hits, base in
                                model.applySelection(.marquee(hits: hits, base: base))
                            },
                            onClear: { model.applySelection(.clear) })
                        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                            ForEach(model.items, id: \.item.id) { detail in
                                CollectionCell(
                                    detail: detail,
                                    url: model.thumbnailURL(for: detail),
                                    isSelected: model.selection.ids.contains(detail.item.id),
                                    isCursor: model.selection.lead == detail.item.id,
                                    isSelecting: model.selection.isSelecting,
                                    onImagePress: { shift, command in
                                        handleImagePress(
                                            detail, shift: shift, command: command, proxy: proxy)
                                    },
                                    onImageClick: { shift, command in
                                        handleImageClick(
                                            detail, shift: shift, command: command, proxy: proxy)
                                    },
                                    onCircleToggle: {
                                        model.applySelection(.tapCircle(detail.item.id))
                                    })
                                .equatable()
                                .id(detail.item.id)
                                .draggable(dragPayload(for: detail)) { dragPreview(for: detail) }
                                .dropDestination(for: AssetDragPayload.self) { payloads, _ in
                                    handleCellDrop(payloads, onto: detail.asset.id)
                                }
                                .contextMenu { cellMenu(for: detail) }
                            }
                        }
                        .padding(.top, Self.gridTopInset)
                        // The live marquee rectangle, drawn in the same space.
                        MarqueeRectangleLayer(state: marquee)
                    }
                    .coordinateSpace(name: Self.marqueeSpace)
                }
                .focusable()
                .onDeleteCommand { model.requestDeleteSelected() }
                .onKeyPress(.return) {
                    let effect = model.applySelection(.openLead)
                    execute(effect, proxy: proxy)
                    return effect == .none ? .ignored : .handled
                }
                .onKeyPress(.escape) {
                    guard model.selection.isSelecting else { return .ignored }
                    model.applySelection(.clear)
                    return .handled
                }
                .onKeyPress(keys: ["a"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.applySelection(.selectAll)
                    return .handled
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    handleArrow(press, width: geo.size.width, proxy: proxy)
                }
            }
        }
        .overlay {
            if model.items.isEmpty {
                Text("No items in this collection yet.")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The batch context menu (009 · N2/N6). Finder scope (7A): a right-click on a
    /// SELECTED cell acts on the whole selection; on an UNSELECTED cell it acts on
    /// that one cell and leaves the selection untouched. Counts are shown in the
    /// destructive verbs so the scope is never ambiguous.
    @ViewBuilder
    private func cellMenu(for detail: CollectionItemDetail) -> some View {
        let targets = model.actionTargets(forCellItemID: detail.item.id)
        let n = targets.count
        let dests = CollectionTargets.moveTargets(
            from: collectionID, folders: model.folders, unsortedID: model.unsortedFolderID)

        Menu("Move to") {
            targetButtons(dests) { model.moveToCollection(assetIDs: targets, to: $0) }
        }
        Menu("Add to") {
            targetButtons(dests) { model.copyToCollection(assetIDs: targets, to: $0) }
        }
        if n == 1 {
            Button("Set as Cover") {
                model.setCollectionCover(collectionID: collectionID, assetID: targets[0])
            }
        }
        Divider()
        Button("Remove from Collection\(Self.countSuffix(n))") {
            model.removeFromFolder(assetIDs: targets)
        }
        Button("Delete\(Self.countSuffix(n))", role: .destructive) {
            model.requestDelete(assetIDs: targets)
        }
    }

    /// A Move-to / Add-to submenu: subfolders first, a divider, then roots.
    @ViewBuilder
    private func targetButtons(
        _ dests: MoveTargets, action: @escaping (UUID) -> Void
    ) -> some View {
        ForEach(dests.subfolders) { c in Button(c.name) { action(c.id) } }
        if !dests.subfolders.isEmpty && !dests.roots.isEmpty { Divider() }
        ForEach(dests.roots) { c in Button(c.name) { action(c.id) } }
    }

    /// " (N)" for a multi-item action, empty for a single — keeps the verb scope
    /// explicit ("Delete (34)") without noise on the common one-item case.
    private static func countSuffix(_ n: Int) -> String { n > 1 ? " (\(n))" : "" }

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
                        model.openItem(model.items[target])
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

    /// Open the full-window detail page for `detail`: make it the lead (loading
    /// its preview + tags, 009 · 8A) and raise the overlay via
    /// `NavModel.presentedItemID` (the routing seam the grid click, the Return
    /// key, and the Space canvas all funnel through). The open is the deliberate
    /// "view" signal (007 G4).
    private func open(_ detail: CollectionItemDetail) {
        model.openItem(detail)
        model.recordView(assetID: detail.asset.id)
        withAnimation { nav.presentedItemID = detail.item.id }
    }

    // MARK: - Selection input routing (009 · N2)

    /// The mouse-DOWN edge on a cell's image: apply the down-edge cases (⇧/⌘,
    /// toggle-on of an unselected cell while selecting) so a drag activation
    /// can't swallow them, and report whether the press consumed the interaction
    /// (the cell then ignores the matching mouse-up click). The decision table
    /// is the pure ``gridPressRouting(imageID:isSelecting:isSelected:shift:command:)``.
    private func handleImagePress(
        _ detail: CollectionItemDetail, shift: Bool, command: Bool, proxy: ScrollViewProxy
    ) -> Bool {
        let routing = gridPressRouting(
            imageID: detail.item.id,
            isSelecting: model.selection.isSelecting,
            isSelected: model.selection.ids.contains(detail.item.id),
            shift: shift, command: command)
        if let action = routing.pressAction {
            execute(model.applySelection(action), proxy: proxy)
        }
        return routing.consumesRelease
    }

    /// A plain/⇧/⌘ click on a cell's image: build the reducer action from the live
    /// modifiers and execute the returned effect. The reducer owns the
    /// mode-dependent "open vs toggle" decision — this only routes.
    private func handleImageClick(
        _ detail: CollectionItemDetail, shift: Bool, command: Bool, proxy: ScrollViewProxy
    ) {
        let action = gridClickAction(imageID: detail.item.id, shift: shift, command: command)
        execute(model.applySelection(action), proxy: proxy)
    }

    /// Route an arrow key (with ⇧ = extend) through the reducer, feeding it the
    /// live column count so Up/Down step a whole row.
    private func handleArrow(
        _ press: KeyPress, width: CGFloat, proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let key: GridArrowKey
        switch press.key {
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .upArrow: key = .up
        case .downArrow: key = .down
        default: return .ignored
        }
        let columns = gridColumnCount(
            availableWidth: width,
            minItemWidth: Self.gridItemMinWidth,
            spacing: Self.gridSpacing)
        let effect = model.applySelection(
            .arrow(key, extend: press.modifiers.contains(.shift)), columns: columns)
        execute(effect, proxy: proxy)
        return .handled
    }

    /// Carry out a reducer ``GridSelectionEffect``: open a detail page or scroll a
    /// cell into view (Q4 — ⇧-arrow reuses the existing `scrollTo` path).
    private func execute(_ effect: GridSelectionEffect, proxy: ScrollViewProxy) {
        switch effect {
        case .none:
            break
        case let .scrollTo(id):
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        case let .openDetail(id):
            if let detail = model.items.first(where: { $0.item.id == id }) { open(detail) }
        }
    }

    // MARK: - Drag & drop (009 · N3)

    /// The ⌥-at-drop-time reader, isolated behind a protocol so move-vs-copy
    /// routing stays unit-testable (the routing itself lives in `routeDrop`).
    private static let modifierReader: ModifierReading = LiveModifierReader()

    /// The payload for a drag starting on `detail`: the whole selection when the
    /// cell is selected, else the cell alone (which it also selects). Falls back
    /// to a lone-cell payload if the model can't build one (cell vanished).
    private func dragPayload(for detail: CollectionItemDetail) -> AssetDragPayload {
        model.dragPayload(forCellItemID: detail.item.id)
            ?? AssetDragPayload(assetIDs: [detail.asset.id], sourceCollectionID: collectionID)
    }

    /// The drag image: the cell's thumbnail with a count badge when more than one
    /// item travels (Q3 — count badge on the lead thumbnail).
    @ViewBuilder
    private func dragPreview(for detail: CollectionItemDetail) -> some View {
        let count = model.selection.ids.contains(detail.item.id)
            ? max(model.selection.ids.count, 1) : 1
        AssetContentThumbnail(asset: detail.asset, url: model.thumbnailURL(for: detail))
            .frame(width: 84, height: 84)
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

    /// Handle a payload dropped onto the cell for `targetAssetID`: route it (only
    /// a same-collection, manual-sort drop is a reorder) and apply the multi-block
    /// move. Cross-collection / non-manual drops are refused here — those moves go
    /// through the stack row / rail.
    private func handleCellDrop(_ payloads: [AssetDragPayload], onto targetAssetID: UUID) -> Bool {
        guard let payload = payloads.first else { return false }
        let target = DropTarget.cell(
            collectionID: collectionID, sortMode: model.sortMode(for: collectionID))
        switch routeDrop(payload, onto: target, optionDown: Self.modifierReader.isOptionDown) {
        case let .reorder(assetIDs):
            model.reorderItems(movingAssetIDs: assetIDs, toIndexOf: targetAssetID)
            return true
        case .reject, .move, .copy:
            return false
        }
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
        // A URL copied as PLAIN TEXT (the address bar, a message, a doc) carries only
        // `public.utf8-plain-text` — not `.URL` or an NSURL — so parse that too, with a
        // dotted-host guard so arbitrary text isn't mistaken for a link (001 · C2b).
        if let text = pasteboard.string(forType: .string),
           let url = IngestionModel.webURL(fromPastedText: text) {
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
