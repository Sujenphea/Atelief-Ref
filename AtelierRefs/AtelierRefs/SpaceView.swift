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
    @State private var quickLook = QuickLookPresenter()
    @State private var showAddSheet = false
    @State private var tool: CanvasTool = .select
    @State private var showEditor = false

    init(model: IngestionModel, nav: NavModel, spaceID: UUID, services: AppServices, store: MediaStore) {
        self.model = model
        self.nav = nav
        _space = StateObject(wrappedValue: SpaceModel(spaceID: spaceID, services: services, store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            canvas
        }
        .navigationTitle(space.name)
        .toolbar {
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
        .help("Select, draw a Frame, or add Text")
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
                        quickLook.present(url: url, title: url.lastPathComponent)
                    } else if content.detail(forTileID: tileID)?.item.kind != .asset {
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
