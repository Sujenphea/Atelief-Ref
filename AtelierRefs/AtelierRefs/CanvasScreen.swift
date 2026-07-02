//
//  CanvasScreen.swift
//  AtelierRefs
//
//  Build-order #5 — the Canvas tab over real data. Shows the currently-selected
//  folder's items on the infinite canvas (``CanvasView``) driven by
//  ``CanvasContent``, or an empty state when the folder has no items. The view is
//  rebuilt (via `.id`) whenever the folder's contents change.
//

import AtelierCore
import CanvasRenderer
import SwiftUI

struct CanvasScreen: View {
    @ObservedObject var model: IngestionModel
    /// Retains the QuickLook window used to play a double-clicked video.
    @State private var quickLook = QuickLookPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            canvas
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.name(for: model.selectedFolderID)).font(.headline)
            Text("\(model.items.count) items")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text("Scroll to pan · pinch to zoom")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var canvas: some View {
        if let content = model.canvasContent() {
            // Rebuild the host when the folder's contents change (new import or
            // folder switch); this reframes to fit and resets pan/zoom.
            CanvasView(
                provider: content, images: content,
                selectedTileID: selectedTileID(in: content),
                onActivateTile: { tileID in
                    // Double-click a video tile → play it inline in QuickLook.
                    if let url = content.videoURL(forTileID: tileID) {
                        quickLook.present(url: url, title: url.lastPathComponent)
                    }
                },
                onSelectTile: { tileID in
                    // Single-click selects (shared with the Library's selection);
                    // empty space clears it.
                    model.select(tileID.flatMap { content.detail(forTileID: $0) })
                },
                onRemoveTile: { tileID in
                    if let detail = content.detail(forTileID: tileID) {
                        model.removeFromFolder(assetIDs: [detail.asset.id])
                    }
                },
                onDeleteTile: { tileID in
                    if let detail = content.detail(forTileID: tileID) {
                        model.requestDelete(assetIDs: [detail.asset.id])
                    }
                })
            .id(model.contentsVersion)
        } else {
            ContentUnavailableView {
                Label("Nothing on the canvas", systemImage: "square.grid.2x2")
            } description: {
                Text("Import images into “\(model.name(for: model.selectedFolderID))”, "
                     + "or pick a folder in the Library, to see them here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The tile id matching the shared selection, so the canvas highlights the
    /// same item the inspector shows (or nothing when it isn't on this board).
    private func selectedTileID(in content: CanvasContent) -> Int? {
        guard let id = model.selectedItemID else { return nil }
        return content.tileID(forItemID: id)
    }
}
