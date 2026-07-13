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

    /// Undo/redo scoped to THIS open space (history resets on close — v1). Every
    /// write funnels through ``enqueue(_:)`` so an undo can't reorder ahead of an
    /// in-flight write, and registrations are synchronous so `groupsByEvent`
    /// coalesces a frame's per-tile group-move into a SINGLE undo step.
    let undoManager = UndoManager()
    /// Bumped on every register / undo / redo so the toolbar's enabled state +
    /// action names refresh (UndoManager isn't `ObservableObject`).
    @Published private(set) var undoToken = 0

    /// Serial write queue: each op awaits the previous, so DB writes + reloads
    /// stay strictly ordered even as undo/redo interleave with live edits.
    private var writeChain: Task<Void, Never> = Task {}

    private struct Placement: Equatable {
        var x: Double, y: Double, w: Double, h: Double
        var z: Int
    }

    /// Pending moves in the current synchronous drag burst (a frame group-drag
    /// delivers one `moveTile` per carried tile). Flushed to a SINGLE undo step.
    private var pendingMoves: [(id: UUID, old: Placement, new: Placement)] = []

    init(spaceID: UUID, services: AppServices, store: MediaStore) {
        self.spaceID = spaceID
        self.services = services
        self.store = store
        // Explicit grouping (not per-run-loop-event): each action registers its
        // own closed group, so `canUndo` is correct immediately and undo is
        // deterministic without a running event loop.
        undoManager.groupsByEvent = false
        Task { await load() }
    }

    // MARK: - Serialized writes + undo

    /// Await the current tail of the serial write chain — for tests to observe a
    /// settled state after an edit / undo / redo.
    func waitForWrites() async { await writeChain.value }

    /// Append `work` to the serial write chain (FIFO, strictly ordered).
    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = writeChain
        writeChain = Task { @MainActor in
            await previous.value
            await work()
        }
    }

    /// Register a reversible action the caller has ALREADY performed, as its own
    /// closed undo group: `inverse` runs on undo, `primary` re-runs on redo,
    /// ping-ponging. Neither runs now.
    private func registerReversible(_ name: String,
                                    primary: @escaping () -> Void,
                                    inverse: @escaping () -> Void) {
        undoManager.beginUndoGrouping()
        undoManager.setActionName(name)
        installUndo(name, primary: primary, inverse: inverse)
        undoManager.endUndoGrouping()
        undoToken &+= 1
    }

    /// The recursive ping-pong: install an undo that runs `inverse` then
    /// re-installs the mirror for redo. During undo/redo `UndoManager` supplies
    /// the enclosing group, so this must NOT open its own.
    private func installUndo(_ name: String,
                             primary: @escaping () -> Void,
                             inverse: @escaping () -> Void) {
        undoManager.registerUndo(withTarget: self) { model in
            inverse()
            model.installUndo(name, primary: inverse, inverse: primary)
            model.undoManager.setActionName(name)
        }
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    var undoActionName: String { undoManager.undoActionName }
    var redoActionName: String { undoManager.redoActionName }

    func undo() { undoManager.undo(); undoToken &+= 1 }
    func redo() { undoManager.redo(); undoToken &+= 1 }

    // MARK: - Write primitives (used by ops + their inverses)

    private func persistPlacement(_ id: UUID, _ p: Placement, reload: Bool) async {
        do {
            try await services.setSpaceItemPlacement(itemID: id, x: p.x, y: p.y, w: p.w, h: p.h, z: p.z)
            if reload { await load() }
        } catch {
            lastError = Self.message(for: error)
        }
    }

    private func performRestyle(_ id: UUID, _ style: ElementStyle) async {
        do {
            try await services.updateSpaceItemStyle(itemID: id, style: style)
            await load()
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Remove or re-insert a batch of rows, then reload once. The two directions
    /// of create / delete / add-references undo.
    private func performBatch(_ items: [SpaceItem], restore: Bool) async {
        do {
            for item in items {
                if restore { try await services.restoreSpaceItem(item) }
                else { try await services.removeSpaceItem(itemID: item.id) }
            }
            await load()
        } catch {
            lastError = Self.message(for: error)
        }
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
    /// in-memory update runs first so the tile stays put (no reload → no flicker);
    /// the write is serialized and an undo to the old placement is registered.
    /// During a frame group-move the host calls this once per carried tile, all
    /// within one event, so `groupsByEvent` folds them into a single undo.
    func moveTile(tileID: Int, to worldOrigin: CGPoint, in content: SpaceContent) {
        guard content.tiles.indices.contains(tileID),
              let itemID = content.spaceItemID(forTileID: tileID) else { return }
        let tile = content.tiles[tileID]
        let old = Placement(x: tile.x, y: tile.y, w: tile.w, h: tile.h, z: tile.z)
        let new = Placement(x: Double(worldOrigin.x), y: Double(worldOrigin.y), w: tile.w, h: tile.h, z: tile.z)
        guard old != new else { return }
        content.setPlacement(tileID: tileID, x: new.x, y: new.y)
        enqueue { await self.persistPlacement(itemID, new, reload: false) }
        // Buffer this move; the first of a synchronous burst schedules the flush
        // that folds the whole burst (a frame + its carried tiles) into ONE undo.
        let firstOfBurst = pendingMoves.isEmpty
        pendingMoves.append((itemID, old, new))
        if firstOfBurst {
            enqueue { self.flushMoveUndo() }
        }
    }

    /// Register a single undo for the buffered move burst (runs on the serial
    /// queue AFTER the synchronous `moveTile` calls, so the buffer is complete).
    private func flushMoveUndo() {
        let moves = pendingMoves
        pendingMoves = []
        guard !moves.isEmpty else { return }
        let name = moves.count > 1 ? "Move Group" : "Move"
        registerReversible(name,
            primary: { self.enqueue { await self.applyMoves(moves, forward: true) } },
            inverse: { self.enqueue { await self.applyMoves(moves, forward: false) } })
    }

    private func applyMoves(_ moves: [(id: UUID, old: Placement, new: Placement)], forward: Bool) async {
        for move in moves {
            let target = forward ? move.new : move.old
            do {
                try await services.setSpaceItemPlacement(
                    itemID: move.id, x: target.x, y: target.y, w: target.w, h: target.h, z: target.z)
            } catch {
                lastError = Self.message(for: error)
            }
        }
        await load()
    }

    // MARK: - Remove

    /// Remove a tile's row from the space (a placement, NOT the underlying
    /// asset), then reload. No-op if the tile can't be resolved.
    func removeTile(tileID: Int, in content: SpaceContent) {
        guard let itemID = content.spaceItemID(forTileID: tileID) else { return }
        removeItem(itemID)
    }

    /// Remove a space_item by id (a placement, never the asset), then reload.
    /// Undoable — the removed row is captured and restored verbatim (stable id).
    func removeItem(_ itemID: UUID) {
        guard let detail = items.first(where: { $0.item.id == itemID }) else {
            // Not in our current snapshot — remove without an undo record.
            enqueue {
                do { try await self.services.removeSpaceItem(itemID: itemID); await self.load() }
                catch { self.lastError = Self.message(for: error) }
            }
            return
        }
        let item = detail.item
        if selectedItemID == itemID { selectedItemID = nil }
        enqueue { await self.performBatch([item], restore: false) }
        registerReversible("Delete",
            primary: { self.enqueue { await self.performBatch([item], restore: false) } },
            inverse: { self.enqueue { await self.performBatch([item], restore: true) } })
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
        enqueue {
            do {
                var created: [SpaceItem] = []
                for (asset, rect) in zip(assets, rects) {
                    let item = try await self.services.addAssetToSpace(
                        assetID: asset.id, to: self.spaceID,
                        x: rect.x, y: rect.y, w: rect.w, h: rect.h, z: rect.z)
                    created.append(item)
                }
                self.registerReversible(created.count == 1 ? "Add Reference" : "Add References",
                    primary: { self.enqueue { await self.performBatch(created, restore: true) } },
                    inverse: { self.enqueue { await self.performBatch(created, restore: false) } })
                await self.load()
            } catch {
                self.lastError = Self.message(for: error)
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
        enqueue {
            do {
                let created = try await self.services.addElement(
                    to: self.spaceID, kind: kind, style: style,
                    x: Double(rect.minX), y: Double(rect.minY),
                    w: Double(rect.width), h: Double(rect.height), z: z)
                self.selectedItemID = created.id
                self.registerReversible(kind == .frame ? "Add Frame" : "Add Text",
                    primary: { self.enqueue { await self.performBatch([created], restore: true) } },
                    inverse: { self.enqueue { await self.performBatch([created], restore: false) } })
                await self.load()
            } catch {
                self.lastError = Self.message(for: error)
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
    /// Undoable — the previous style is captured and restored on undo.
    func updateStyle(itemID: UUID, style newStyle: ElementStyle) {
        let oldStyle = style(forItemID: itemID)
        guard oldStyle != newStyle else { return }
        enqueue { await self.performRestyle(itemID, newStyle) }
        registerReversible("Restyle",
            primary: { self.enqueue { await self.performRestyle(itemID, newStyle) } },
            inverse: { self.enqueue { await self.performRestyle(itemID, oldStyle) } })
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
