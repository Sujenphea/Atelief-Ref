//
//  SpaceView.swift
//  AtelierRefs
//
//  005-E2 — one open space over the real renderer. Shows the space's asset rows
//  on the infinite canvas (`CanvasView`) driven by `SpaceContent`, or an empty
//  state. Assets enter the board by dragging them in from a collection. The canvas
//  host is rebuilt (via `.id`) whenever the space's rows change. Zero renderer
//  changes — images ride the existing path.
//

import AppKit
import AtelierCore
import AtelierIngestion
import CanvasRenderer
import SwiftUI

/// The context-aware action bar's mode, derived purely from the selection count
/// (051 · 2A). Extracted + pure so the thresholds are unit-tested (051 · 12A) and
/// the rendering stays compile-only. Selection drives it, never the active tool
/// (051 · E-4).
enum SpaceBarMode: Equatable {
    case idle   // nothing selected → create tools
    case single // one row → Edit + z-order
    case multi  // 2+ rows → align + distribute + z-order

    static func forSelection(count: Int) -> SpaceBarMode {
        switch count {
        case ..<1: .idle
        case 1: .single
        default: .multi
        }
    }
}

extension CanvasArrange.Operation {
    /// Whether the bar enables this op for a selection of `selectionCount`: align
    /// needs ≥2, distribute ≥3 — read straight off `minimumCount` so the threshold
    /// lives in ONE place (051 · 12A/E-3). Pure; unit-tested for the off-by-ones.
    func isEnabled(selectionCount: Int) -> Bool { selectionCount >= minimumCount }
}

struct SpaceView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @EnvironmentObject private var exportController: ExportController
    @StateObject private var space: SpaceModel
    /// Tags for the asset shown in the detail overlay (Space has no folder
    /// context, so it can't reuse `IngestionModel`'s selection-bound tags).
    @StateObject private var tagStore: AssetTagsStore
    @State private var quickLook = QuickLookController()
    @State private var tool: CanvasTool = .select
    @State private var showEditor = false
    /// The asset row shown in the full-window detail overlay, or `nil`.
    @State private var detailItem: SpaceItemDetail?
    /// The tile currently being edited inline on-canvas (2B · 054 §5), or `nil`.
    /// Double-clicking a `.text` element (or finishing a new-text-box create) sets
    /// it; committing / cancelling / deleting clears it.
    @State private var editingTileID: Int?
    /// Whether ``editingTileID`` refers to a box just created (an empty commit
    /// deletes it, 054 §5.3).
    @State private var editingWasNew = false
    /// The app↔host rendezvous the inline editor repositions through, off the
    /// SwiftUI diff (054 §5.1/§5.2). A stable reference for this view's lifetime.
    @State private var editBridge = CanvasEditingBridge()

    init(model: IngestionModel, nav: NavModel, spaceID: UUID, services: AppServices, store: MediaStore) {
        self.model = model
        self.nav = nav
        _space = StateObject(wrappedValue: SpaceModel(spaceID: spaceID, services: services, store: store))
        _tagStore = StateObject(wrappedValue: AssetTagsStore(services: services))
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                canvas
            }
            // Full-window detail page for a double-clicked asset tile. Guarding on
            // the row keeps it self-dismissing if the space reloads it away.
            if let detailItem, detailItem.asset != nil {
                spaceDetailOverlay(for: detailItem)
                    .transition(.opacity)
            }
        }
        // The space name lives in the in-content header only (parity with Collection);
        // the native window-toolbar title is dropped so the name isn't shown twice.
        // Undo/redo and z-order live in the floating bottom action bar (`actionBar`,
        // over the canvas) rather than the native window toolbar.
        // Surface space-level write failures on the shared app alert.
        .onChange(of: space.lastError) { _, message in
            if let message { model.lastError = message; space.lastError = nil }
        }
        // Tag edits from the detail overlay surface on the same alert.
        .onChange(of: tagStore.lastError) { _, message in
            if let message { model.lastError = message; tagStore.lastError = nil }
        }
        // Expose the board's export to the File-menu command (052 · B3): default
        // config (PDF, single page) for the same selection-or-whole-board rows.
        .focusedSceneValue(\.exportMoodboard, ExportMoodboardAction {
            guard !space.items.isEmpty else { return }
            let mapping = MoodboardExport.map(
                details: MoodboardExport.rows(items: space.placedItems, selected: space.selectedItemIDs),
                imageURL: { model.previewImageURL(forAsset: $0) })
            exportController.requestExport(
                mapping: mapping, config: ExportConfig(), suggestedName: space.name)
        })
    }

    /// The header shrank to name + count once the tools moved into the context-aware
    /// floating bar (051 · 8A); the create tools, Edit, and align/distribute all live
    /// in `actionBar` now.
    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(space.name).font(Theme.Typography.sectionTitle)
            Text("\(space.items.count) items")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text("Drag to place · pinch to zoom")
                .font(.caption).foregroundStyle(.tertiary)
            // Moodboard export: the progress ring appears only while rendering
            // (052 · B3); the Export button opens the format popover.
            ExportProgressRing()
            MoodboardExportButton(space: space, model: model)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    /// Select / Frame / Text, in the `.idle` sub-bar. A create tool rubber-bands a
    /// new element, then the canvas flips back to Select (see `onCreateElement`).
    /// The V/F/T shortcuts live on the canvas container (see `canvas`), NOT here —
    /// they must keep firing when a selection swaps this picker out of the bar
    /// (051 · E-2).
    private var toolPicker: some View {
        Picker("Tool", selection: $tool) {
            Image(systemName: "cursorarrow").tag(CanvasTool.select)
            Image(systemName: "rectangle.dashed").tag(CanvasTool.frame)
            Image(systemName: "textformat").tag(CanvasTool.text)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Select (V), Frame (F), or Text (T)")
    }

    /// V / F / T switch tools without reaching for the picker (design-tool muscle
    /// memory). Zero-size hidden buttons so the shortcuts register while the board
    /// is up; a focused text field takes plain keys first, so typing isn't hijacked.
    private var toolShortcuts: some View {
        ZStack {
            Button("") { tool = .select }.keyboardShortcut("v", modifiers: [])
            Button("") { tool = .frame }.keyboardShortcut("f", modifiers: [])
            Button("") { tool = .text }.keyboardShortcut("t", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// The `.single` bar's Edit glyph (051 · 8A — folded down from the header).
    /// Shows only when the lone selected row is a freeform element; opens its
    /// inspector popover. A selected asset has no style to edit, so it's absent.
    @ViewBuilder private var editButton: some View {
        if let element = space.selectedElement {
            SelectionBarButton("slider.horizontal.3", help: "Edit style") { showEditor = true }
                .popover(isPresented: $showEditor, arrowEdge: .bottom) {
                    ElementInspector(
                        kind: element.item.kind,
                        initialStyle: space.style(forItemID: element.item.id),
                        onCommit: { style in space.updateStyle(itemID: element.item.id, style: style) },
                        onDelete: { space.removeItem(element.item.id) })
                    .id(element.item.id)
                }
        }
    }

    @ViewBuilder private var canvas: some View {
        let content = space.content()
        ZStack {
            CanvasView(
                provider: content, images: content,
                selectedTileIDs: space.selectedTileIDs(in: content),
                syncToken: space.renderRevision,
                tool: tool,
                editingTileID: editingTileID,
                onActivateTile: { tileID in
                    if let url = content.videoURL(forTileID: tileID) {
                        quickLook.present(url: url)
                    } else if let detail = content.detail(forTileID: tileID),
                              detail.item.kind == .asset, detail.asset != nil {
                        // Double-click an image asset → open its detail page.
                        openAssetDetail(detail)
                    } else if let detail = content.detail(forTileID: tileID),
                              detail.item.kind == .text {
                        // Double-click a TEXT element → edit its string inline on
                        // canvas (2B · D3); the style popover stays for the Edit bar.
                        space.select(tileID: tileID, in: content)
                        editingWasNew = false
                        editingTileID = tileID
                    } else {
                        // Double-click a FRAME element → open its style popover
                        // (frames have no inline path, 054 §5.2).
                        space.select(tileID: tileID, in: content)
                        showEditor = true
                    }
                },
                onSelectTiles: { tileIDs in
                    space.select(tileIDs: tileIDs, in: content)
                },
                onRemoveTiles: { tileIDs in
                    space.removeTiles(tileIDs: tileIDs, in: content)
                },
                onDeleteTiles: { tileIDs in
                    // In a space, both "remove" and ⌫ drop the placement — the
                    // underlying asset (in its collections) is never touched here.
                    space.removeTiles(tileIDs: tileIDs, in: content)
                },
                onCopyTiles: { tileIDs in
                    // ⌘C copies the selected asset tiles (052 · B1), z-ordered for a
                    // deterministic multi-copy; element rows (frame/text, no asset)
                    // are skipped. Routes through the ONE shared write path.
                    let assets = tileIDs
                        .compactMap { content.detail(forTileID: $0) }
                        .sorted { $0.item.z < $1.item.z }
                        .compactMap { detail in
                            detail.asset.map { (asset: $0, source: detail.source) }
                        }
                    model.copyToPasteboard(assets: assets)
                },
                onMoveTile: { tileID, worldOrigin in
                    space.moveTile(tileID: tileID, to: worldOrigin, in: content)
                },
                onCreateElement: { createdTool, worldRect in
                    switch createdTool {
                    case .frame:
                        space.addFrame(worldRect: worldRect)
                    case .text:
                        // Place the box, then enter inline edit immediately (054 §5.2)
                        // once the write settles and the new row has a tile id.
                        space.addText(worldRect: worldRect)
                        Task {
                            await space.waitForWrites()
                            let created = space.content()
                            if let id = space.selectedItemID,
                               let tid = created.tileID(forSpaceItemID: id) {
                                editingWasNew = true
                                editingTileID = tid
                            }
                        }
                    case .select:
                        break
                    }
                    tool = .select // one-shot: back to Select after placing
                },
                onTransformChanged: { editBridge.transformDidChange() },
                onHostReady: { editBridge.host = $0 },
                // SP2 / S2: accept an in-app asset drag (grid / library / another
                // board) and place it centred on the drop point. External import
                // (files / images / URLs) is SP3 — refused here for now.
                acceptedDropTypes: [AssetDragPayload.pasteboardType],
                onDragEntered: { pasteboard in
                    guard let payload = AssetDragPayload.decode(from: pasteboard),
                          case .place = canvasDropRoute(.assetDrag(payload)) else { return [] }
                    return .copy
                },
                onDrop: { pasteboard, worldPoint in
                    guard let payload = AssetDragPayload.decode(from: pasteboard) else { return false }
                    switch canvasDropRoute(.assetDrag(payload)) {
                    case let .place(assetIDs):
                        space.placeDroppedAssets(ids: assetIDs, at: worldPoint)
                        return true
                    case .ingestThenPlace, .reject:
                        return false
                    }
                })
            .id(space.contentVersion)

            if space.items.isEmpty { emptyHint }

            // The inline text-editing overlay (2B). Present only while a `.text` tile
            // is being edited; it repositions itself imperatively via `editBridge`.
            if let editingTileID, let detail = content.detail(forTileID: editingTileID),
               detail.item.kind == .text {
                inlineEditor(tileID: editingTileID, itemID: detail.item.id)
            }
        }
        // V/F/T ride the canvas container, NOT the `.idle` sub-bar (051 · E-2): a
        // `keyboardShortcut` fires only while rendered, so keeping them here means
        // the create tools stay reachable even when a selection swaps the tool
        // picker out of the bar for `.single` / `.multi`.
        .background(toolShortcuts)
        .overlay(alignment: .bottom) { actionBar }
    }

    /// The inline `NSTextView` overlay for the tile being edited (2B). Commit routes
    /// through the SAME `updateStyle` path 2C uses (one undo step, auto-size + one
    /// sync); cancel abandons; an empty NEW box is deleted (054 §5.3). Clearing
    /// ``editingTileID`` removes the overlay and un-blanks the tile's glyphs.
    @ViewBuilder
    private func inlineEditor(tileID: Int, itemID: UUID) -> some View {
        InlineTextEditor(
            tileID: tileID,
            style: space.style(forItemID: itemID),
            wasNewlyCreated: editingWasNew,
            bridge: editBridge,
            onCommit: { newText in
                var style = space.style(forItemID: itemID)
                style.text = newText
                space.updateStyle(itemID: itemID, style: style)
                editingTileID = nil
                editingWasNew = false
            },
            onCancel: {
                editingTileID = nil
                editingWasNew = false
            },
            onDelete: {
                space.removeItem(itemID)
                editingTileID = nil
                editingWasNew = false
            })
        .frame(maxWidth: .infinity, maxHeight: .infinity) // fill the canvas area
        .id(tileID)
    }

    // MARK: - Bottom action bar

    /// The bar's mode, derived PURELY from the selection count (051 · 2A). Selection
    /// wins over any active create tool (051 · E-4) — the tools stay reachable via
    /// the hoisted V/F/T shortcuts regardless of mode.
    private var barMode: SpaceBarMode { .forSelection(count: space.selectedItemIDs.count) }

    /// The floating action pill over the canvas, now context-aware (051 · 2A/E-2).
    /// Undo/redo are MODE-INVARIANT — present in every mode, dimmed-not-hidden — so
    /// ⌘Z / ⌘⇧Z always fire (a `keyboardShortcut` on an unrendered button is dead).
    /// The mode-switched half is the tools (`.idle`) / Edit + z-order (`.single`) /
    /// align + distribute + z-order (`.multi`). Reuses the shared `SelectionBarButton`
    /// glyphs + `selectionBarChrome()` capsule (parity with the Collection/Search
    /// bar) — a flat `spacing: 2` row. The trailing pad balances the chrome's
    /// text-tuned leading inset (16) for this icon-only bar.
    private var actionBar: some View {
        HStack(spacing: 2) {
            undoRedoBar // mode-invariant (051 · E-2)
            switch barMode {
            case .idle: toolPicker
            case .single: singleBar
            case .multi: multiBar
            }
        }
        .padding(.trailing, 10)
        .selectionBarChrome()
    }

    /// Undo / redo — always on screen so their shortcuts never die (051 · E-2).
    @ViewBuilder private var undoRedoBar: some View {
        SelectionBarButton(
            "arrow.uturn.backward",
            help: space.canUndo ? "Undo \(space.undoActionName)" : "Nothing to undo"
        ) { space.undo() }
            .disabled(!space.canUndo)
            .opacity(space.canUndo ? 1 : 0.35)
            .keyboardShortcut("z", modifiers: .command)

        SelectionBarButton(
            "arrow.uturn.forward",
            help: space.canRedo ? "Redo \(space.redoActionName)" : "Nothing to redo"
        ) { space.redo() }
            .disabled(!space.canRedo)
            .opacity(space.canRedo ? 1 : 0.35)
            .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    /// `.single`: Edit (elements only) + z-order for the lone selection.
    @ViewBuilder private var singleBar: some View {
        editButton
        zOrderBar
    }

    /// `.multi`: the six aligns + two distributes, then z-order. Each op is gated on
    /// its own `minimumCount` (align ≥2, distribute ≥3 — 051 · 12A/E-3), dimmed-not-
    /// hidden below it, so at a 2-item selection the distributes read as "not yet".
    @ViewBuilder private var multiBar: some View {
        ForEach(CanvasArrange.Operation.allCases, id: \.self) { op in
            let enabled = op.isEnabled(selectionCount: space.selectedItemIDs.count)
            SelectionBarButton(Self.symbol(for: op), help: op.actionName) { space.arrange(op) }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
        }
        zOrderBar
    }

    /// Z-order for the whole selection (034 P2 · 049 D7 — relative order preserved),
    /// shared by `.single` and `.multi`. Undoable via the space's own ⌘Z.
    @ViewBuilder private var zOrderBar: some View {
        SelectionBarButton(
            "square.3.layers.3d.top.filled",
            help: "Bring the selected items to the front (⌘⇧])"
        ) { space.bringSelectionToFront() }
            .keyboardShortcut("]", modifiers: [.command, .shift])

        SelectionBarButton(
            "square.3.layers.3d.bottom.filled",
            help: "Send the selected items to the back (⌘⇧[)"
        ) { space.sendSelectionToBack() }
            .keyboardShortcut("[", modifiers: [.command, .shift])
    }

    /// The SF Symbol for each arrange op. Kept in the view layer so `CanvasArrange`
    /// stays geometry-only (051 · 1A).
    private static func symbol(for op: CanvasArrange.Operation) -> String {
        switch op {
        case .alignLeft: "align.horizontal.left"
        case .alignHorizontalCenter: "align.horizontal.center"
        case .alignRight: "align.horizontal.right"
        case .alignTop: "align.vertical.top"
        case .alignVerticalCenter: "align.vertical.center"
        case .alignBottom: "align.vertical.bottom"
        case .distributeHorizontal: "arrow.left.and.right"
        case .distributeVertical: "arrow.up.and.down"
        }
    }

    // MARK: - Asset detail overlay

    /// Open the detail page for a double-clicked asset row: bind the tag store to
    /// the asset and raise the overlay.
    private func openAssetDetail(_ detail: SpaceItemDetail) {
        tagStore.bind(to: detail.asset?.id)
        if let id = detail.asset?.id { model.recordView(assetID: id) }
        withAnimation { detailItem = detail }
    }

    /// Build the detail overlay for a Space asset. Reuses the presentation-only
    /// ``ItemDetailView`` with NO prev/next (a board has no ordered set) and NO
    /// folder-scoped remove/delete (the placement — not a membership — is the
    /// unit of removal here, and that's the canvas tile's ⌫).
    @ViewBuilder
    private func spaceDetailOverlay(for detail: SpaceItemDetail) -> some View {
        if let asset = detail.asset {
            let sourceURL = detail.source?.originalURL
            let hasSource = !(sourceURL ?? "").isEmpty
            let hasBlob = model.blobURL(forAsset: asset) != nil
            ItemDetailView(
                asset: asset,
                source: detail.source,
                blobURL: model.blobURL(forAsset: asset),
                previewImage: nil,
                tags: tagStore.tags,
                onAddTag: { tagStore.add($0) },
                onRemoveTag: { tagStore.remove($0) },
                collections: tagStore.collections,
                allCollections: tagStore.allCollections,
                onAddToCollection: { tagStore.addToCollection($0) },
                onRemoveFromCollection: { tagStore.removeFromCollection($0) },
                onSetName: { tagStore.setName($0) },
                onSetNote: { tagStore.setNote($0) },
                actions: ItemDetailActions(
                    openSource: hasSource ? { model.openSourceURL(sourceURL) } : nil,
                    openBlob: hasBlob ? { model.openBlob(asset: asset) } : nil,
                    revealInFinder: hasBlob ? { model.revealInFinder(asset: asset) } : nil,
                    copySourceLink: hasSource ? { model.copySourceLink(url: sourceURL) } : nil,
                    removeFromFolder: nil,
                    requestDelete: nil),
                navigator: nil,
                onClose: {
                    model.flushViewBumps()
                    withAnimation { detailItem = nil }
                    tagStore.bind(to: nil)
                })
        }
    }

    /// A non-blocking hint over the (empty) canvas — the tools stay live, so drawing
    /// the first Frame / Text still works.
    private var emptyHint: some View {
        ContentUnavailableView(
            "This space is empty",
            systemImage: "square.on.square.dashed",
            description: Text(
                "Drag references in from a collection, or draw a Frame / Text with the tools below."))
            .allowsHitTesting(false)
    }
}
