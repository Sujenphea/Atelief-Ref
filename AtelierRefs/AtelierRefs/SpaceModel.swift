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
    /// The selected rows' space_item ids (049 · D1 — multi-select). Empty when
    /// nothing is selected. The canvas engine owns the interaction-time set in
    /// tile-index space; this is its persisted-identity mirror (delete / z-order /
    /// action-bar gating).
    @Published private(set) var selectedItemIDs: Set<UUID> = []
    /// Single-selection convenience: the lone selected id, or `nil` when the
    /// selection is empty OR holds more than one row. Derived, never stored — no
    /// parallel state to drift (the inspector + single-item paths read this).
    var selectedItemID: UUID? { selectedItemIDs.count == 1 ? selectedItemIDs.first : nil }
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

    /// Persist a batch of placements in ONE transaction (049 · D13); optionally
    /// reload after. The live-drag flush passes `reload: false` (flicker-free — the
    /// tiles already moved in memory); undo/redo pass `reload: true` to resync
    /// ``items``. An empty batch is a no-op.
    private func persistPlacements(_ placements: [(id: UUID, p: Placement)], reload: Bool) async {
        guard !placements.isEmpty else { return }
        do {
            try await services.setSpaceItemPlacements(placements.map {
                SpaceItemPlacement(itemID: $0.id, x: $0.p.x, y: $0.p.y, w: $0.p.w, h: $0.p.h, z: $0.p.z)
            })
            if reload { await load() }
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Single-placement convenience over ``persistPlacements(_:reload:)`` (DRY).
    private func persistPlacement(_ id: UUID, _ p: Placement, reload: Bool) async {
        await persistPlacements([(id, p)], reload: reload)
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
            // Prune the selection to ids that survived the reload (049 · D7) — the
            // set peer of the old stale-single guard.
            let present = Set(rows.map { $0.item.id })
            let pruned = selectedItemIDs.intersection(present)
            if pruned != selectedItemIDs { selectedItemIDs = pruned }
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

    /// The tile ids matching the shared selection, so the canvas highlights the
    /// same rows the model has selected (drawable ids only).
    func selectedTileIDs(in content: SpaceContent) -> Set<Int> {
        Set(selectedItemIDs.compactMap { content.tileID(forSpaceItemID: $0) })
    }

    // MARK: - Selection

    /// Replace the selection with the rows the given tiles draw (049 · D1). An empty
    /// set clears. Maps tile ids (canvas indices) → space_item ids, dropping any
    /// that can't be resolved.
    func select(tileIDs: Set<Int>, in content: SpaceContent) {
        selectedItemIDs = Set(tileIDs.compactMap { content.spaceItemID(forTileID: $0) })
    }

    /// Single-tile convenience (nil clears) over ``select(tileIDs:in:)``.
    func select(tileID: Int?, in content: SpaceContent) {
        select(tileIDs: tileID.map { [$0] } ?? [], in: content)
    }

    // MARK: - Drag-to-place

    /// Move a tile to `worldOrigin` and PERSIST the placement (keeps w/h/z). The
    /// in-memory update runs first so the tile stays put (no reload → no flicker).
    /// The host calls this once per carried tile within ONE synchronous event — a
    /// frame + its group, OR a multi-select drag — so the whole burst is buffered
    /// and flushed as a SINGLE batched write + a SINGLE undo step (049 · D13 / D7).
    func moveTile(tileID: Int, to worldOrigin: CGPoint, in content: SpaceContent) {
        guard content.tiles.indices.contains(tileID),
              let itemID = content.spaceItemID(forTileID: tileID) else { return }
        let tile = content.tiles[tileID]
        let old = Placement(x: tile.x, y: tile.y, w: tile.w, h: tile.h, z: tile.z)
        let new = Placement(x: Double(worldOrigin.x), y: Double(worldOrigin.y), w: tile.w, h: tile.h, z: tile.z)
        guard old != new else { return }
        content.setPlacement(tileID: tileID, x: new.x, y: new.y)
        // Buffer this move; the first of a synchronous burst schedules the flush
        // that writes the whole burst as one transaction and folds it into ONE undo.
        let firstOfBurst = pendingMoves.isEmpty
        pendingMoves.append((itemID, old, new))
        if firstOfBurst {
            enqueue { await self.flushMoves() }
        }
    }

    /// Write the buffered move burst as a single batched placement write, then
    /// register ONE undo for it. Runs on the serial queue AFTER the synchronous
    /// `moveTile` calls, so the buffer is complete.
    private func flushMoves() async {
        let moves = pendingMoves
        pendingMoves = []
        guard !moves.isEmpty else { return }
        await persistPlacements(moves.map { (id: $0.id, p: $0.new) }, reload: false)
        let name = moves.count > 1 ? "Move Group" : "Move"
        registerReversible(name,
            primary: { self.enqueue { await self.persistPlacements(moves.map { (id: $0.id, p: $0.new) }, reload: true) } },
            inverse: { self.enqueue { await self.persistPlacements(moves.map { (id: $0.id, p: $0.old) }, reload: true) } })
    }

    // MARK: - Restack (z-order)

    /// Bring a tile to the FRONT (highest z). No-op if it's already the sole top.
    func bringToFront(itemID: UUID) { restack(itemID, toFront: true) }

    /// Send a tile to the BACK (lowest z). No-op if it's already the sole bottom.
    func sendToBack(itemID: UUID) { restack(itemID, toFront: false) }

    /// Resolve a tile id (canvas index) to its space-item id, then restack it. Lets
    /// the canvas context menu act on the right-clicked tile without a selection.
    func bringTileToFront(tileID: Int, in content: SpaceContent) {
        if let id = content.spaceItemID(forTileID: tileID) { bringToFront(itemID: id) }
    }
    func sendTileToBack(tileID: Int, in content: SpaceContent) {
        if let id = content.spaceItemID(forTileID: tileID) { sendToBack(itemID: id) }
    }

    /// Set a tile's z to one past the current front / back and PERSIST it, undoable
    /// via the same placement write as a move (so it interleaves correctly). Skips a
    /// tile that is already the sole item at that extreme — no pointless undo entry.
    private func restack(_ itemID: UUID, toFront: Bool) {
        guard items.contains(where: { $0.item.id == itemID }) else { return }
        // Read the LIVE placement from content, not `items`: a drag updates content
        // in place and persists with reload:false, so `items` holds the stale
        // pre-drag x/y. Writing those back here would revert the move. z is never
        // touched by a drag, so the extreme is still computed from `items`.
        let content = self.content()
        let current = livePlacement(itemID, in: content)
        let zs = items.map(\.item.z)
        let extreme = toFront ? (zs.max() ?? current.z) : (zs.min() ?? current.z)
        // Already the lone tile at the target edge → nothing to do.
        if current.z == extreme, zs.filter({ $0 == current.z }).count == 1 { return }
        let targetZ = toFront ? extreme + 1 : extreme - 1
        let old = current
        let new = Placement(x: current.x, y: current.y, w: current.w, h: current.h, z: targetZ)
        enqueue { await self.persistPlacement(itemID, new, reload: true) }
        registerReversible(toFront ? "Bring to Front" : "Send to Back",
            primary: { self.enqueue { await self.persistPlacement(itemID, new, reload: true) } },
            inverse: { self.enqueue { await self.persistPlacement(itemID, old, reload: true) } })
    }

    /// Bring the whole SELECTION to the front (or send it to the back), preserving
    /// the selected tiles' relative stacking order, as ONE batched write + ONE undo
    /// step (049 · D7). The block is lifted just past the extreme of the
    /// NON-selected tiles, so a selection already sitting at that edge is a true
    /// no-op (no z inflation on repeated clicks). No-op when nothing is selected or
    /// everything is selected (there is no "other" to sit above/below).
    func bringSelectionToFront() { restackSelection(toFront: true) }
    func sendSelectionToBack() { restackSelection(toFront: false) }

    private func restackSelection(toFront: Bool) {
        let ids = selectedItemIDs
        guard !ids.isEmpty else { return }
        let content = self.content()
        // Selected rows with their LIVE placement (a drag may not have reloaded),
        // ordered by current z so relative stacking is preserved as the block moves.
        let selected = items
            .filter { ids.contains($0.item.id) }
            .map { (id: $0.item.id, p: livePlacement($0.item.id, in: content)) }
            .sorted { $0.p.z < $1.p.z }
        // The extreme of the tiles NOT being restacked; nothing to sit relative to
        // when the whole board is selected.
        let othersZ = items.filter { !ids.contains($0.item.id) }.map(\.item.z)
        guard !selected.isEmpty, let edge = (toFront ? othersZ.max() : othersZ.min()) else { return }

        var forward: [(id: UUID, p: Placement)] = []
        var backward: [(id: UUID, p: Placement)] = []
        for (offset, entry) in selected.enumerated() {
            // Consecutive z's past the edge, preserving the block's internal order.
            let newZ = toFront ? edge + 1 + offset : edge - selected.count + offset
            forward.append((id: entry.id, p: Placement(
                x: entry.p.x, y: entry.p.y, w: entry.p.w, h: entry.p.h, z: newZ)))
            backward.append((id: entry.id, p: entry.p))
        }
        // Already exactly in place → no write, no undo entry.
        guard zip(forward, backward).contains(where: { $0.0.p.z != $0.1.p.z }) else { return }
        enqueue { await self.persistPlacements(forward, reload: true) }
        registerReversible(toFront ? "Bring to Front" : "Send to Back",
            primary: { self.enqueue { await self.persistPlacements(forward, reload: true) } },
            inverse: { self.enqueue { await self.persistPlacements(backward, reload: true) } })
    }

    /// The freshest placement for `itemID`: the in-memory tile (which carries a
    /// not-yet-reloaded drag position) when present, else the stored row.
    private func livePlacement(_ itemID: UUID, in content: SpaceContent) -> Placement {
        if let tid = content.tileID(forSpaceItemID: itemID),
           content.tiles.indices.contains(tid) {
            let t = content.tiles[tid]
            return Placement(x: t.x, y: t.y, w: t.w, h: t.h, z: t.z)
        }
        let item = items.first(where: { $0.item.id == itemID })!.item
        return Placement(x: item.x, y: item.y, w: item.w, h: item.h, z: item.z)
    }

    // MARK: - Remove

    /// Remove the rows the given tiles draw (a placement each, NEVER the asset) as
    /// ONE batched undo step (049 · D7). No-op for tiles that can't be resolved.
    func removeTiles(tileIDs: Set<Int>, in content: SpaceContent) {
        removeItems(Set(tileIDs.compactMap { content.spaceItemID(forTileID: $0) }))
    }

    /// Single-tile convenience over ``removeTiles(tileIDs:in:)``.
    func removeTile(tileID: Int, in content: SpaceContent) {
        if let itemID = content.spaceItemID(forTileID: tileID) { removeItems([itemID]) }
    }

    /// Single-id convenience over ``removeItems(_:)``.
    func removeItem(_ itemID: UUID) { removeItems([itemID]) }

    /// Remove a batch of space_item rows by id (placements, never the assets) as ONE
    /// undo step. Rows still in the current snapshot are captured and restored
    /// verbatim on undo (stable ids); ids that already vanished are removed without
    /// an undo record (idempotent). Drops the removed ids from the selection.
    func removeItems(_ itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        selectedItemIDs.subtract(itemIDs)
        let known = items.filter { itemIDs.contains($0.item.id) }.map(\.item)
        let unknown = itemIDs.subtracting(known.map(\.id))

        if !known.isEmpty {
            enqueue { await self.performBatch(known, restore: false) }
            registerReversible(known.count == 1 ? "Delete" : "Delete Items",
                primary: { self.enqueue { await self.performBatch(known, restore: false) } },
                inverse: { self.enqueue { await self.performBatch(known, restore: true) } })
        }
        for id in unknown {
            // Not in our snapshot — remove without an undo record.
            enqueue {
                do { try await self.services.removeSpaceItem(itemID: id); await self.load() }
                catch { self.lastError = Self.message(for: error) }
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
                self.selectedItemIDs = [created.id] // select the new element
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
