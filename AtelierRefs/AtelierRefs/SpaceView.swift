//
//  SpaceView.swift
//  AtelierRefs
//
//  005-E2 — one open space over the real renderer. Shows the space's asset rows
//  on the infinite canvas (`CanvasView`) driven by `SpaceContent`, or an empty
//  state. "Add from Library" opens a multi-select picker that flows the chosen
//  assets into the board. The canvas host is rebuilt (via `.id`) whenever the
//  space's rows change. Zero renderer changes — images ride the existing path.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import SwiftUI

struct SpaceView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @StateObject private var space: SpaceModel
    /// Tags for the asset shown in the detail overlay (Space has no folder
    /// context, so it can't reuse `IngestionModel`'s selection-bound tags).
    @StateObject private var tagStore: AssetTagsStore
    @State private var quickLook = QuickLookController()
    @State private var showAddSheet = false
    @State private var tool: CanvasTool = .select
    @State private var showEditor = false
    /// The asset row shown in the full-window detail overlay, or `nil`.
    @State private var detailItem: SpaceItemDetail?

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
        .navigationTitle(space.name)
        .toolbar {
            ToolbarItemGroup {
                Button { space.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!space.canUndo)
                .help(space.canUndo ? "Undo \(space.undoActionName)" : "Nothing to undo")
                .keyboardShortcut("z", modifiers: .command)

                Button { space.redo() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!space.canRedo)
                .help(space.canRedo ? "Redo \(space.redoActionName)" : "Nothing to redo")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // Z-order for the selected tile (034 P2). Undoable via the space's own
            // ⌘Z; disabled with nothing selected.
            ToolbarItemGroup {
                Button {
                    if let id = space.selectedItemID { space.bringToFront(itemID: id) }
                } label: {
                    Label("Bring to Front", systemImage: "square.3.layers.3d.top.filled")
                }
                .disabled(space.selectedItemID == nil)
                .help("Bring the selected item to the front (⌘⇧])")
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button {
                    if let id = space.selectedItemID { space.sendToBack(itemID: id) }
                } label: {
                    Label("Send to Back", systemImage: "square.3.layers.3d.bottom.filled")
                }
                .disabled(space.selectedItemID == nil)
                .help("Send the selected item to the back (⌘⇧[)")
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            ToolbarItem {
                Button { showAddSheet = true } label: {
                    Label("Add from Library", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddFromLibrarySheet(model: model) { assets in
                space.addAssets(assets)
            }
        }
        // Surface space-level write failures on the shared app alert.
        .onChange(of: space.lastError) { _, message in
            if let message { model.lastError = message; space.lastError = nil }
        }
        // Tag edits from the detail overlay surface on the same alert.
        .onChange(of: tagStore.lastError) { _, message in
            if let message { model.lastError = message; tagStore.lastError = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(space.name).font(.headline)
            Text("\(space.items.count) items")
                .font(.callout).foregroundStyle(.secondary)
            toolPicker
            editButton
            Spacer()
            Text("Drag to place · pinch to zoom")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Select / Frame / Text. A create tool rubber-bands a new element, then the
    /// canvas flips back to Select (see `onCreateElement`).
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
        .background(toolShortcuts)
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

    /// Appears when a freeform element is selected; opens its inspector popover.
    @ViewBuilder private var editButton: some View {
        if let element = space.selectedElement {
            Button { showEditor = true } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
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
                selectedTileID: space.selectedTileID(in: content),
                tool: tool,
                onActivateTile: { tileID in
                    if let url = content.videoURL(forTileID: tileID) {
                        quickLook.present(url: url)
                    } else if let detail = content.detail(forTileID: tileID),
                              detail.item.kind == .asset, detail.asset != nil {
                        // Double-click an image asset → open its detail page.
                        openAssetDetail(detail)
                    } else {
                        // Double-click a frame/text element → open its inspector.
                        space.select(tileID: tileID, in: content)
                        showEditor = true
                    }
                },
                onSelectTile: { tileID in
                    space.select(tileID: tileID, in: content)
                },
                onRemoveTile: { tileID in
                    space.removeTile(tileID: tileID, in: content)
                },
                onDeleteTile: { tileID in
                    // In a space, both "remove" and ⌫ drop the placement — the
                    // underlying asset (in its collections) is never touched here.
                    space.removeTile(tileID: tileID, in: content)
                },
                onMoveTile: { tileID, worldOrigin in
                    space.moveTile(tileID: tileID, to: worldOrigin, in: content)
                },
                onCreateElement: { createdTool, worldRect in
                    switch createdTool {
                    case .frame: space.addFrame(worldRect: worldRect)
                    case .text: space.addText(worldRect: worldRect)
                    case .select: break
                    }
                    tool = .select // one-shot: back to Select after placing
                })
            .id(space.contentVersion)

            if space.items.isEmpty { emptyHint }
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

    /// A non-blocking hint over the (empty) canvas — the tools + toolbar stay
    /// live, so the first frame / text / library add still works.
    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("This space is empty").font(.headline)
            Text("Add references from your library, or draw a Frame / Text with the tools above.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .allowsHitTesting(false)
    }
}
