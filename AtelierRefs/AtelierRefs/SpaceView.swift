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
        HStack(spacing: 8) {
            Text(space.name).font(.headline)
            Text("\(space.items.count) items")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text("Scroll to pan · pinch to zoom")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var canvas: some View {
        if let content = space.content() {
            CanvasView(
                provider: content, images: content,
                selectedTileID: space.selectedTileID(in: content),
                onActivateTile: { tileID in
                    if let url = content.videoURL(forTileID: tileID) {
                        quickLook.present(url: url, title: url.lastPathComponent)
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
                })
            .id(space.contentVersion)
        } else {
            ContentUnavailableView {
                Label("This space is empty", systemImage: "square.on.square.dashed")
            } description: {
                Text("Add references from your library to arrange them freely.")
            } actions: {
                Button("Add from Library") { showAddSheet = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
