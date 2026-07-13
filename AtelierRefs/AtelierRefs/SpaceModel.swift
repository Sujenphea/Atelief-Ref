//
//  SpaceModel.swift
//  AtelierRefs
//
//  005-E2 — the view model behind ONE open space. Deliberately NOT more
//  `IngestionModel`: each open space gets its own small model over the shared
//  Library (`AppServices` + `MediaStore`), holding that space's rows, selection,
//  and the `SpaceContent` provider. Writes hop OFF the main actor and surface
//  failures via `lastError`; the in-memory placement update runs synchronously
//  so a dragged tile stays put (mirrors the folder-canvas drag contract).
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import Combine
import Foundation
import SwiftUI

@MainActor
final class SpaceModel: ObservableObject {
    let spaceID: UUID

    /// The space's metadata (name for the header), or `nil` while loading.
    @Published private(set) var space: Space?
    /// The space's rows (asset + element), z-ordered.
    @Published private(set) var items: [SpaceItemDetail] = []
    /// The selected row's space_item id, or `nil`.
    @Published private(set) var selectedItemID: UUID?
    /// Bumped whenever ``items`` change, so `SpaceView` rebuilds the canvas host.
    @Published private(set) var contentVersion = 0
    /// The last surfaced error, or `nil`.
    @Published var lastError: String?

    private let services: AppServices
    private let store: MediaStore

    /// Monotonic load id so a slow read can't clobber a newer one.
    private var loadID = 0
    private var cachedContent: SpaceContent?
    private var cachedVersion = -1

    init(spaceID: UUID, services: AppServices, store: MediaStore) {
        self.spaceID = spaceID
        self.services = services
        self.store = store
        Task { await load() }
    }

    /// The space's display name (falls back until metadata loads).
    var name: String { space?.name ?? "Space" }

    // MARK: - Load

    /// Load the space metadata + its rows. Guards against stale reads.
    func load() async {
        loadID &+= 1
        let id = loadID
        do {
            let space = try await services.getSpace(id: spaceID)
            let rows = try await services.spaceItems(in: spaceID)
            guard id == loadID else { return }
            self.space = space
            self.items = rows
            if let selectedItemID, !rows.contains(where: { $0.item.id == selectedItemID }) {
                self.selectedItemID = nil
            }
            contentVersion &+= 1
        } catch {
            guard id == loadID else { return }
            lastError = Self.message(for: error)
        }
    }

    // MARK: - Content provider

    /// The `SpaceContent` for the current rows — rebuilt only when
    /// ``contentVersion`` changes. Always non-nil (even for an empty space) so the
    /// canvas is present to draw the first frame / text onto; the empty-state hint
    /// is a non-blocking overlay the view adds when ``items`` is empty.
    func content() -> SpaceContent {
        if cachedVersion == contentVersion, let cached = cachedContent { return cached }
        cachedVersion = contentVersion
        let content = SpaceContent(items: items, store: store)
        cachedContent = content
        return content
    }

    /// The tile id matching the shared selection, so the canvas highlights the
    /// same row the model has selected (or nothing when it isn't drawable).
    func selectedTileID(in content: SpaceContent) -> Int? {
        guard let selectedItemID else { return nil }
        return content.tileID(forSpaceItemID: selectedItemID)
    }

    // MARK: - Selection

    /// Select the row a tile draws (or clear with a nil tile id).
    func select(tileID: Int?, in content: SpaceContent) {
        selectedItemID = tileID.flatMap { content.spaceItemID(forTileID: $0) }
    }

    // MARK: - Drag-to-place

    /// Move a tile to `worldOrigin` and PERSIST the placement (keeps w/h/z). The
    /// in-memory update runs first so the tile stays put; the DB write hops off
    /// the main actor. No-op if the tile can't be resolved.
    func moveTile(tileID: Int, to worldOrigin: CGPoint, in content: SpaceContent) {
        guard content.tiles.indices.contains(tileID),
              let itemID = content.spaceItemID(forTileID: tileID) else { return }
        let tile = content.tiles[tileID]
        let (w, h, z) = (tile.w, tile.h, tile.z)
        let x = Double(worldOrigin.x)
        let y = Double(worldOrigin.y)
        content.setPlacement(tileID: tileID, x: x, y: y)
        Task {
            do {
                try await services.setSpaceItemPlacement(itemID: itemID, x: x, y: y, w: w, h: h, z: z)
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Remove

    /// Remove a tile's row from the space (a placement, NOT the underlying
    /// asset), then reload. No-op if the tile can't be resolved.
    func removeTile(tileID: Int, in content: SpaceContent) {
        guard let itemID = content.spaceItemID(forTileID: tileID) else { return }
        removeItem(itemID)
    }

    /// Remove a space_item by id, then reload.
    func removeItem(_ itemID: UUID) {
        Task {
            do {
                try await services.removeSpaceItem(itemID: itemID)
                await load()
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Add from Library

    /// Add assets to this space, flowed into justified rows BELOW the current
    /// content (005 — the "Add from Library" flow-in). Reloads on completion.
    func addAssets(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        // Start below the current content's bounding box; z above the current max.
        let startY: Double = {
            let maxBottom = items.map { $0.item.y + $0.item.h }.max() ?? 0
            return maxBottom > 0 ? maxBottom + SpaceLayout.spacing : 0
        }()
        let startZ = (items.map(\.item.z).max() ?? -1) + 1
        let aspects = assets.map(SpaceLayout.aspect)
        let rects = SpaceLayout.flowIn(aspects: aspects, startY: startY, startZ: startZ)
        Task {
            do {
                for (asset, rect) in zip(assets, rects) {
                    try await services.addAssetToSpace(
                        assetID: asset.id, to: spaceID,
                        x: rect.x, y: rect.y, w: rect.w, h: rect.h, z: rect.z)
                }
                await load()
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Elements (frames + text, E3)

    /// The selected row IFF it is a freeform element (frame/text) — drives the
    /// element inspector. `nil` when nothing, or an asset, is selected.
    var selectedElement: SpaceItemDetail? {
        guard let selectedItemID,
              let detail = items.first(where: { $0.item.id == selectedItemID }),
              detail.item.kind != .asset else { return nil }
        return detail
    }

    /// Add a frame element occupying `worldRect`. Frames sit BEHIND the board
    /// content (lowest z) so the references they group draw on top. Selects it.
    func addFrame(worldRect: CGRect) {
        addElement(kind: .frame, style: ElementRendering.defaultFrameStyle(), rect: worldRect, behind: true)
    }

    /// Add a text element occupying `worldRect`, on TOP of the content. Selects it.
    func addText(worldRect: CGRect) {
        addElement(kind: .text, style: ElementRendering.defaultTextStyle(), rect: worldRect, behind: false)
    }

    private func addElement(kind: SpaceItemKind, style: ElementStyle, rect: CGRect, behind: Bool) {
        let z = behind
            ? (items.map(\.item.z).min() ?? 0) - 1
            : (items.map(\.item.z).max() ?? -1) + 1
        Task {
            do {
                let created = try await services.addElement(
                    to: spaceID, kind: kind, style: style,
                    x: Double(rect.minX), y: Double(rect.minY),
                    w: Double(rect.width), h: Double(rect.height), z: z)
                selectedItemID = created.id
                await load()
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// The current `ElementStyle` for an element row (empty style if unset / not
    /// found), so the inspector can seed its editors.
    func style(forItemID id: UUID) -> ElementStyle {
        guard let detail = items.first(where: { $0.item.id == id }) else { return ElementStyle() }
        return ElementStyle(jsonString: detail.item.style) ?? ElementStyle()
    }

    /// Persist an element's restyle (text, colours, stroke, label), then reload.
    func updateStyle(itemID: UUID, style: ElementStyle) {
        Task {
            do {
                try await services.updateSpaceItemStyle(itemID: itemID, style: style)
                await load()
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Errors

    private static func message(for error: Error) -> String {
        guard let error = error as? AtelierError else { return error.localizedDescription }
        switch error {
        case .notFound:
            return "That space no longer exists."
        case .invalidPlacement:
            return "That placement isn't valid."
        case .persistenceFailure(let detail):
            if let detail, !detail.isEmpty { return "Library storage failed: \(detail)" }
            return "Library storage failed."
        default:
            return "\(error)"
        }
    }
}
