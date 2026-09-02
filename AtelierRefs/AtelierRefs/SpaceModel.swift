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
    /// Bumped when a reload adds or removes a ROW — i.e. when the tile set itself
    /// changed, not merely its geometry. Observability only: nothing is `.id`-bound to
    /// it any more, and nothing rebuilds the canvas host.
    ///
    /// It used to drive `SpaceView`'s `.id(space.contentVersion)`, which meant every
    /// reload destroyed the host and built a fresh one — and a fresh host frames the
    /// board to fit. That is the whole story behind "the zoom jumps when I delete
    /// something": `load()` is reached by delete, create, drop, paste, add-from-library,
    /// both z-ops, and **every undo/redo of a placement edit** (they all pass
    /// `reload: true`). A reload now reconciles the live ``SpaceContent`` in place.
    @Published private(set) var contentVersion = 0
    /// Bumped whenever what the canvas draws changed with no host rebuild — a reload,
    /// an align / distribute, a restyle, a resize. `SpaceView` feeds it to the canvas
    /// as `syncToken`, which is the renderer's "re-read the provider" signal. Unlike a
    /// drag (the host's gesture loop drives `sync()` per frame), these fire no gesture
    /// and may fire no selection change — nothing would otherwise trigger
    /// `engine.sync()`, so the changed tiles would stay stale until the next unrelated
    /// event.
    @Published private(set) var renderRevision = 0
    /// The last surfaced error, or `nil`.
    @Published var lastError: String?

    private let services: AppServices
    private let store: MediaStore

    /// Monotonic load id so a slow read can't clobber a newer one.
    private var loadID = 0
    private var cachedContent: SpaceContent?

    /// Undo/redo scoped to THIS open space (history resets on close — v1). Every
    /// write funnels through ``enqueue(_:)`` so an undo can't reorder ahead of an
    /// in-flight write. Each action is its own closed group (`groupsByEvent` is
    /// off), so a frame's per-tile group-move is coalesced by ``flushMoves()``
    /// draining the burst buffer — NOT by the run loop.
    ///
    /// `lazy` only because the callback needs `self`; it is created on the first
    /// undoable write and never replaced.
    private lazy var undoStack = UndoStack { [weak self] in self?.undoToken &+= 1 }
    /// Bumped on every register / undo / redo so the toolbar's enabled state +
    /// action names refresh (UndoManager isn't `ObservableObject`).
    @Published private(set) var undoToken = 0

    private struct Placement: Equatable {
        var x: Double, y: Double, w: Double, h: Double
        var z: Int
    }

    /// Pending moves in the current synchronous drag burst (a frame group-drag
    /// delivers one `moveTile` per carried tile). Flushed to a SINGLE undo step.
    private var pendingMoves: [(id: UUID, old: Placement, new: Placement)] = []

    /// How long a camera change waits before it is written (018 · Cluster C).
    /// Injectable so a test can drive the debounce without sleeping through it —
    /// the `SnapshotManager(now:)` pattern applied to a duration rather than a clock.
    private let cameraFlushDelay: Duration

    init(spaceID: UUID, services: AppServices, store: MediaStore,
         cameraFlushDelay: Duration = .milliseconds(400)) {
        self.spaceID = spaceID
        self.services = services
        self.store = store
        self.cameraFlushDelay = cameraFlushDelay
        Task { await load() }
    }

    // MARK: - Serialized writes + undo

    /// Await the current tail of the serial write chain — for tests to observe a
    /// settled state after an edit / undo / redo.
    func waitForWrites() async { await undoStack.waitForWrites() }

    /// Append `work` to the serial write chain (FIFO, strictly ordered).
    private func enqueue(_ work: @escaping () async -> Void) { undoStack.enqueue(work) }

    /// Register a reversible action the caller has ALREADY performed, as its own
    /// closed undo group: `inverse` runs on undo, `primary` re-runs on redo,
    /// ping-ponging. Neither runs now.
    private func registerReversible(_ name: String,
                                    primary: @escaping () -> Void,
                                    inverse: @escaping () -> Void) {
        undoStack.registerReversible(name, primary: primary, inverse: inverse)
    }

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }
    var undoActionName: String { undoStack.undoActionName }
    var redoActionName: String { undoStack.redoActionName }

    func undo() { undoStack.undo() }
    func redo() { undoStack.redo() }

    // MARK: - Write primitives (used by ops + their inverses)

    /// Persist a batch of placements in ONE transaction (049 · D13); optionally
    /// reload after. The live-drag flush passes `reload: false` (the tiles already
    /// moved in memory, so re-reading them would be pure work); undo/redo pass
    /// `reload: true` to resync ``items`` from the durable truth. Both are
    /// flicker-free and both keep the camera — a reload reconciles the live content in
    /// place. An empty batch is a no-op.
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

    /// The ONE placement-mutation path (051 · 4A): filter exact no-ops, persist the
    /// forward batch, and register a single reversible undo group. Targets are
    /// recomputed (never accumulated), so `new == old` is real equality with no
    /// float drift (051 · 7A) — dropping unchanged edits avoids empty writes +
    /// pointless undo entries; if nothing remains, this does nothing at all.
    ///
    /// `reload` governs only the FORWARD apply: geometry ops that already moved the
    /// tiles in memory pass `false` (nothing to re-read, like a drag); z-ops pass
    /// `true` (051 · 13A). Undo/redo always reload, because they restore geometry the
    /// live content has no other way to learn about.
    ///
    /// This is `async` and awaits the write INLINE, so a caller already running on
    /// the serial queue (``flushMoves``) folds the write into its own task — an
    /// inner `enqueue` awaiting the outer would deadlock the chain. OFF-queue
    /// callers (restack / arrange) wrap the call in ``enqueue(_:)``.
    private func applyPlacementEdit(name: String,
                                    edits: [(id: UUID, old: Placement, new: Placement)],
                                    reload: Bool) async {
        let changed = edits.filter { $0.new != $0.old }
        guard !changed.isEmpty else { return }
        let forward = changed.map { (id: $0.id, p: $0.new) }
        let backward = changed.map { (id: $0.id, p: $0.old) }
        await persistPlacements(forward, reload: reload)
        registerReversible(name,
            primary: { self.enqueue { await self.persistPlacements(forward, reload: true) } },
            inverse: { self.enqueue { await self.persistPlacements(backward, reload: true) } })
    }

    /// Persist a restyle and, when `placement` is set, the derived geometry in ONE
    /// transaction (054 §4.3 · R6) — style + auto-size can never half-persist and
    /// one undo reverts both. `placement == nil` writes style only (the `.fixed`
    /// path). Does NOT reload: the caller (``applyRestyle``) already updated ``items``
    /// and the live content in memory, so a reload would only re-read the database to
    /// learn what it just wrote (the style peer of a drag's `reload: false`).
    private func persistRestyle(_ id: UUID, _ style: ElementStyle, placement: Placement?) async {
        do {
            let sp = placement.map {
                SpaceItemPlacement(itemID: id, x: $0.x, y: $0.y, w: $0.w, h: $0.h, z: $0.z)
            }
            try await services.updateSpaceItemStyleAndPlacement(itemID: id, style: style, placement: sp)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Apply a restyle to ``items`` and the LIVE ``SpaceContent`` in memory, bump
    /// ``renderRevision`` so the canvas re-syncs the tile IN PLACE (no host rebuild),
    /// then persist durably with no reload. `placement` carries the derived auto-size
    /// geometry (nil = style only, geometry untouched). Mirrors the drag path: mutate
    /// the shared content instance the renderer holds, then signal a re-sync. Both the
    /// forward edit and its undo/redo route through here so every restyle is
    /// flicker-free.
    private func applyRestyle(_ id: UUID, _ style: ElementStyle, placement: Placement?) {
        guard let idx = items.firstIndex(where: { $0.item.id == id }) else { return }
        let content = self.content()
        // Preserve the LIVE position when the restyle carries no geometry of its own —
        // a style-only edit must not reset a not-yet-reloaded drag position (this also
        // de-stales `items` back to the live rect).
        let geom = placement ?? livePlacement(id, in: content)
        var item = items[idx].item
        item.style = style.jsonString()
        item.x = geom.x; item.y = geom.y; item.w = geom.w; item.h = geom.h; item.z = geom.z
        let detail = SpaceItemDetail(item: item, asset: items[idx].asset, source: items[idx].source)
        items[idx] = detail
        // Mirror into the content the renderer is already holding so the next sync
        // draws the change without a new `SpaceContent` (no `.id` change → no rebuild).
        if let tileID = content.tileID(forSpaceItemID: id) {
            content.setElementStyle(tileID: tileID, detail: detail)
        }
        renderRevision &+= 1
        enqueue { await self.persistRestyle(id, style, placement: placement) }
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
            // Adopt the stored camera as the write baseline, but ONLY while the
            // canvas has never reported one of its own (018 · Cluster C). Once it
            // has, the live camera is the truth: a load that lands after a write —
            // and `init`'s own load can, since a newer load makes it return early
            // without ever getting here — re-reads a row that write has not reached,
            // and adopting THAT would make the next identical report look like a
            // change and put a redundant write on every open.
            if !hasReportedCamera { persistedCamera = SpaceCamera(jsonString: space.camera) }
            self.items = refitTextRows(rows)
            // Prune the selection to ids that survived the reload (049 · D7) — the
            // set peer of the old stale-single guard.
            let present = Set(rows.map { $0.item.id })
            let pruned = selectedItemIDs.intersection(present)
            if pruned != selectedItemIDs { selectedItemIDs = pruned }
            // Update the content the renderer is ALREADY holding, rather than handing
            // it a new one — the host is never torn down, so the camera never moves.
            // Surviving rows keep their tile ids, so an open inline editor, the
            // selection and the format chrome all stay pointed at the same rows.
            if content().reconcile(items: items) { contentVersion &+= 1 }
            renderRevision &+= 1
        } catch {
            guard id == loadID else { return }
            lastError = Self.message(for: error)
        }
    }

    // MARK: - Camera (018 · Cluster C)

    /// The camera the board should OPEN at, in renderer terms — or `nil` to fit the
    /// content, which is both the never-opened case and the couldn't-decode case.
    var openingCamera: CanvasCamera? { Self.openingCamera(from: space?.camera) }

    /// The stored `space.camera` blob as an opening camera, or `nil` to fit.
    ///
    /// Pure, so the fallback arms are testable without a database. One rule, one
    /// fallback: ``SpaceCamera/resolved`` collapses "no column", "malformed JSON"
    /// and "a blob missing half its fields" into the same `nil`, and the renderer
    /// adds the third arm — a camera whose viewport would show no content re-fits
    /// too (``CanvasEngine/restoreCamera(_:padding:)``). Three ways to have no
    /// usable camera, ONE answer.
    static func openingCamera(from stored: String?) -> CanvasCamera? {
        guard let saved = SpaceCamera(jsonString: stored)?.resolved else { return nil }
        return CanvasCamera(centre: CGPoint(x: saved.x, y: saved.y), zoom: CGFloat(saved.zoom))
    }

    /// The camera waiting to be written, or `nil` when nothing is pending.
    private var pendingCamera: SpaceCamera?
    /// What the `space.camera` column already holds, as far as this model knows —
    /// seeded from the first load, then advanced by each flush. It exists so the
    /// opening restore, which arrives back through ``cameraChanged(_:)`` as a
    /// "change" to the value it was just given, does not write it straight back.
    private var persistedCamera: SpaceCamera?
    /// Whether the canvas has reported a camera yet. Until it has, every load may
    /// refresh ``persistedCamera`` from disk; after it has, none may (see ``load()``).
    private var hasReportedCamera = false
    private var cameraFlushTask: Task<Void, Never>?

    /// Camera writes actually issued — introspection for the tests, in the same
    /// spirit as ``CanvasEngine/syncCount``. The debounce's entire job is that a
    /// gesture's worth of changes is ONE of these.
    private(set) var cameraWriteCount = 0

    /// The camera moved: a pan, a zoom, or the opening restore/fit. Coalesced —
    /// a whole gesture becomes ONE write, ``cameraFlushDelay`` after its last frame.
    ///
    /// A change back to the value already on disk cancels the pending write instead
    /// of scheduling another: a restore sets the transform to exactly what was
    /// saved, and echoing that back would put a write on every board open.
    func cameraChanged(_ camera: CanvasCamera) {
        hasReportedCamera = true
        let value = SpaceCamera(
            x: Double(camera.centre.x), y: Double(camera.centre.y), zoom: Double(camera.zoom))
        guard value != persistedCamera else {
            pendingCamera = nil
            cameraFlushTask?.cancel()
            cameraFlushTask = nil
            return
        }
        pendingCamera = value
        cameraFlushTask?.cancel()
        cameraFlushTask = Task { [cameraFlushDelay] in
            try? await Task.sleep(for: cameraFlushDelay)
            guard !Task.isCancelled else { return }
            self.flushCameraPersist()
        }
    }

    /// Write the pending camera NOW — on space-switch and on close.
    ///
    /// This is the half that actually matters. Without it the debounce eats the
    /// LAST gesture of every session: you pan, you close the board, and the 0.4s
    /// timer dies with the view holding the only copy of where you were. No-op when
    /// nothing is pending, so calling it on every teardown costs nothing.
    ///
    /// The write goes on the same serial chain as every other board write, so it
    /// cannot overtake an in-flight edit — and so ``waitForWrites()`` settles it.
    func flushCameraPersist() {
        cameraFlushTask?.cancel()
        cameraFlushTask = nil
        guard let camera = pendingCamera else { return }
        pendingCamera = nil
        persistedCamera = camera
        cameraWriteCount &+= 1
        enqueue { await self.persistCamera(camera) }
    }

    /// Not undoable, deliberately: a camera is view state, and putting "where you
    /// were looking" in the undo stack would make ⌘Z sometimes mean "scroll back".
    private func persistCamera(_ camera: SpaceCamera) async {
        do {
            try await services.setSpaceCamera(spaceID: spaceID, camera: camera)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    // MARK: - Content provider

    /// The `SpaceContent` this board draws — built once, then kept in step by
    /// ``SpaceContent/reconcile(items:)``. Always non-nil (even for an empty space) so
    /// the canvas is present to draw the first frame / text onto; the empty-state hint
    /// is a non-blocking overlay the view adds when ``items`` is empty.
    ///
    /// ONE instance for the model's lifetime, deliberately: the renderer holds this
    /// reference, so replacing it would mean replacing the host, and replacing the host
    /// means reframing the camera. Every mutation path — a drag, a restyle, a resize,
    /// and now a reload — updates this instance and signals with ``renderRevision``.
    func content() -> SpaceContent {
        if let cached = cachedContent { return cached }
        let content = SpaceContent(items: items, store: store)
        cachedContent = content
        return content
    }

    /// The tile ids matching the shared selection, so the canvas highlights the
    /// same rows the model has selected (drawable ids only).
    func selectedTileIDs(in content: SpaceContent) -> Set<Int> {
        Set(selectedItemIDs.compactMap { content.tileID(forSpaceItemID: $0) })
    }

    /// The board rows for EXPORT — each carrying its LIVE placement (052 · B3).
    /// A drag / arrange moves the tile in the in-memory ``SpaceContent`` and
    /// persists with `reload: false`, so ``items`` keeps stale pre-move x/y/z
    /// until the next reload (the canvas draws the live content; ``restack`` /
    /// ``arrange`` already read it via ``livePlacement``). Export is WYSIWYG, so
    /// it must read the SAME live placements — never `items` directly, which would
    /// export moved tiles at their pre-move positions.
    var placedItems: [SpaceItemDetail] {
        let content = self.content()
        return items.map { detail in
            let p = livePlacement(detail.item.id, in: content)
            var item = detail.item
            item.x = p.x; item.y = p.y; item.w = p.w; item.h = p.h; item.z = p.z
            return SpaceItemDetail(item: item, asset: detail.asset, source: detail.source)
        }
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
        guard let tile = content.tile(forTileID: tileID),
              let itemID = content.spaceItemID(forTileID: tileID) else { return }
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
    /// `moveTile` calls, so the buffer is complete. The tiles already moved in
    /// memory (see ``moveTile``), so the forward apply is `reload: false`.
    private func flushMoves() async {
        let moves = pendingMoves
        pendingMoves = []
        guard !moves.isEmpty else { return }
        await applyPlacementEdit(
            name: moves.count > 1 ? "Move Group" : "Move",
            edits: moves.map { (id: $0.id, old: $0.old, new: $0.new) },
            reload: false)
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

        let edits: [(id: UUID, old: Placement, new: Placement)] = selected.enumerated().map { offset, entry in
            // Consecutive z's past the edge, preserving the block's internal order.
            let newZ = toFront ? edge + 1 + offset : edge - selected.count + offset
            return (id: entry.id, old: entry.p,
                    new: Placement(x: entry.p.x, y: entry.p.y, w: entry.p.w, h: entry.p.h, z: newZ))
        }
        // A z-op reloads to resync `items`; the helper drops an already-in-place
        // selection (no write, no undo entry).
        enqueue {
            await self.applyPlacementEdit(
                name: toFront ? "Bring to Front" : "Send to Back", edits: edits, reload: true)
        }
    }

    // MARK: - Arrange (align + distribute, 051 Phase 1)

    /// Align or distribute the current multi-selection (051 · E-3 — one method for
    /// all 8 ops). The selection is filtered through ``items`` first (the
    /// ``restackSelection`` pattern), which keeps ``livePlacement``'s force-unwrap
    /// unreachable. Below the op's `minimumCount` this is a no-op (the bar also
    /// gates the buttons). Live rects feed the pure ``CanvasArrange`` kernel; the
    /// results zip back to ids by index, apply IN-MEMORY (flicker-free, like a
    /// drag), and persist through the shared placement path as ONE undo step —
    /// forward `reload: false` (tiles already moved), undo/redo `reload: true`
    /// (051 · 3A / 13A). `z` is always carried from the live rect; `w`/`h` come back
    /// from the kernel, which for every op but `.reflowGrid` hands them straight back
    /// unchanged.
    func arrange(_ op: CanvasArrange.Operation) {
        applySelectionLayout(minimumCount: op.minimumCount, name: op.actionName) {
            CanvasArrange.apply(op, to: $0)
        }
    }

    /// Pack the selection along `axis` at an exact `gap` (066) — the numeric peer of
    /// the ops above.
    ///
    /// Deliberately NOT a `CanvasArrange.Operation` case: `Operation` is `CaseIterable`
    /// and the action bar renders it with `ForEach(allCases)`, and a case carrying an
    /// associated value cannot be `CaseIterable`. Rather than break that wiring for
    /// every other op, the gap gets its own entry point over the same kernel.
    func pack(axis: CanvasArrange.Axis, gap: CGFloat) {
        applySelectionLayout(minimumCount: 2, name: "Set Gap") {
            CanvasArrange.pack($0, axis: axis, gap: gap)
        }
    }

    /// The shared body every selection-layout op ends in: live rects → `transform` →
    /// zip back to ids by index, apply IN-MEMORY (flicker-free, like a drag), and
    /// persist through the shared placement path as ONE undo step.
    ///
    /// Extracted so `arrange` and `pack` cannot drift on any of it — the no-op filter,
    /// the in-memory mirror, the `renderRevision` bump and the `reload: false` are each
    /// load-bearing, and each is easy to omit when writing a second copy.
    ///
    /// The rect that comes back is written whole, size included. `old` therefore carries
    /// the pre-op size and `applyPlacementEdit`'s inverse restores it, so ⌘Z after a
    /// resizing op puts the tiles back at the sizes the user had.
    private func applySelectionLayout(
        minimumCount: Int, name: String, transform: ([CGRect]) -> [CGRect]
    ) {
        let ids = selectedItemIDs
        let selected = items.filter { ids.contains($0.item.id) }
        guard selected.count >= minimumCount else { return }
        let content = self.content()
        // Live placements, index-aligned to the rects handed to the kernel.
        let entries = selected.map { (id: $0.item.id, p: livePlacement($0.item.id, in: content)) }
        let rects = entries.map { CGRect(x: $0.p.x, y: $0.p.y, width: $0.p.w, height: $0.p.h) }
        let arranged = transform(rects)

        var edits: [(id: UUID, old: Placement, new: Placement)] = []
        for (index, entry) in entries.enumerated() {
            let r = arranged[index]
            // The WHOLE rect round-trips — origin AND size. Every op but
            // `.reflowGrid` returns the size it was handed, so this is a no-op for
            // them; reflow normalises tiles to a uniform row height, and writing only
            // x/y (which this did until then) made it move tiles into a grid the
            // sizes no longer fitted. `z` never reaches the kernel (051 · 5A) and is
            // carried from the live placement.
            let new = Placement(x: Double(r.minX), y: Double(r.minY),
                                w: Double(r.width), h: Double(r.height), z: entry.p.z)
            guard new != entry.p else { continue }
            edits.append((id: entry.id, old: entry.p, new: new))
            // Move (and, for a reflow, resize) the tile in memory so the canvas shows
            // the result immediately.
            if let tid = content.tileID(forSpaceItemID: entry.id) {
                content.setPlacement(tileID: tid, x: new.x, y: new.y, w: new.w, h: new.h)
            }
        }
        guard !edits.isEmpty else { return } // already arranged → no write, no undo
        // Tiles moved in memory but nothing triggers a redraw (no gesture, no
        // selection change, no reload) — bump the revision so the host re-syncs.
        renderRevision &+= 1
        enqueue { await self.applyPlacementEdit(name: name, edits: edits, reload: false) }
    }

    /// The freshest placement for `itemID`: the in-memory tile (which carries a
    /// not-yet-reloaded drag position) when present, else the stored row.
    private func livePlacement(_ itemID: UUID, in content: SpaceContent) -> Placement {
        if let tid = content.tileID(forSpaceItemID: itemID),
           let t = content.tile(forTileID: tid) {
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

    /// Where a batch of new references seats on the board (059 · SP2 / 6A).
    enum PlacementSeed: Equatable {
        /// Flow BELOW the current content (the "Add from Library" append).
        case belowContent
        /// Centre the flowed block on a WORLD point (a drag / drop / paste).
        case point(CGPoint)
    }

    /// Add already-resolved assets to this space, flowed BELOW the current content
    /// (005 — the "Add from Library" flow-in). Reloads on completion.
    func addAssets(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        enqueue { await self.insertPlaced(assets, seededAt: .belowContent) }
    }

    /// Place a drag / drop of EXISTING references (059 · SP2 / S2): resolve the
    /// dragged ids to assets, then flow them centred on the drop point. Skips ids
    /// that no longer resolve; a fully-stale drop is a silent no-op.
    func placeDroppedAssets(ids: [UUID], at worldPoint: CGPoint) {
        guard !ids.isEmpty else { return }
        enqueue {
            var assets: [Asset] = []
            for id in ids {
                if let detail = try? await self.services.getAsset(id: id) {
                    assets.append(detail.asset)
                }
            }
            guard !assets.isEmpty else { return }
            await self.insertPlaced(assets, seededAt: .point(worldPoint))
        }
    }

    /// Import EXTERNAL drop content (files / images / a web URL) and place it
    /// centred on `worldPoint` (059 · SP3 / S1 · 10A). `ingest` is the async step
    /// that turns the decoded drop into placeable assets — production binds
    /// `IngestionModel.importInputs` / `importRemoteURL`; tests inject a fake. The
    /// ingest runs OFF the serial write chain so a slow download never freezes board
    /// edits (undo / move); only the fast placement is enqueued, once the assets are
    /// ready. A drop that yields no assets is a no-op here — the ingest step has
    /// already raised its own notice toast saying why. Awaitable so tests can settle it.
    func importAndPlace(at worldPoint: CGPoint, ingest: @escaping () async -> [Asset]) async {
        let assets = await ingest()
        guard !assets.isEmpty else { return }
        enqueue { await self.insertPlaced(assets, seededAt: .point(worldPoint)) }
    }

    /// The ONE placement writer (059 · SP2 / 6A): seed → `flowIn` → batch insert in
    /// one transaction (13A) → placement-only undo (7A / S2) → a single reload
    /// (14A). Runs inside the serial write chain, so it reads `items` at its own
    /// commit time (below whatever content exists when it runs).
    private func insertPlaced(_ assets: [Asset], seededAt seed: PlacementSeed) async {
        let startZ = (items.map(\.item.z).max() ?? -1) + 1
        let aspects = assets.map(SpaceLayout.aspect)
        let rects: [PlacedRect]
        switch seed {
        case .belowContent:
            let startY: Double = {
                let maxBottom = items.map { $0.item.y + $0.item.h }.max() ?? 0
                return maxBottom > 0 ? maxBottom + SpaceLayout.spacing : 0
            }()
            rects = SpaceLayout.flowIn(aspects: aspects, originY: startY, startZ: startZ)
        case let .point(p):
            rects = SpaceLayout.flowIn(
                aspects: aspects, centeredOn: (x: p.x, y: p.y), startZ: startZ)
        }
        let placements = zip(assets, rects).map { asset, rect in
            SpaceAssetPlacement(
                assetID: asset.id, x: rect.x, y: rect.y, w: rect.w, h: rect.h, z: rect.z)
        }
        do {
            let created = try await services.addAssetsToSpace(placements, to: spaceID)
            registerReversible(created.count == 1 ? "Add Reference" : "Add References",
                primary: { self.enqueue { await self.performBatch(created, restore: true) } },
                inverse: { self.enqueue { await self.performBatch(created, restore: false) } })
            await load()
        } catch {
            lastError = Self.message(for: error)
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
    /// Place a new text box. The dragged rect's WIDTH is the user's choice; its
    /// height is derived from the default string immediately (062), so a box is
    /// never born taller or shorter than its content — the same invariant every
    /// later edit maintains. A click-placed box arrives at a default width from the
    /// host, so this is the only place the created height is decided.
    /// `string` overrides the placeholder — a text box pasted from the clipboard (065)
    /// arrives with its content already set, so its height is derived from the REAL
    /// text rather than from "Text" and then re-derived a moment later.
    func addText(worldRect: CGRect, string: String? = nil) {
        var style = ElementRendering.defaultTextStyle()
        if let string { style.text = string }
        // The gesture decides who owns the width (063). A rubber-band drag hands over
        // the rect the user dragged — they chose that width, so honour it. A CLICK
        // arrives as an origin-only rect (`CanvasHostView.finishCreate`), which is the
        // host saying "no width was chosen": the box is born hugging and measures its
        // own, rather than starting at a literal nobody picked.
        let hugs = worldRect.width <= 0
        if hugs { style.textAutoWidth = true }
        let ts = ElementRendering.textStyle(for: style)
        let measured = TextMetrics.size(
            for: ts, hugging: hugs, outerWidth: worldRect.width)
        let rect = CGRect(
            x: worldRect.minX, y: worldRect.minY,
            width: hugs ? measured.width + 2 * TextMetrics.padding : worldRect.width,
            height: measured.height + 2 * TextMetrics.padding)
        addElement(kind: .text, style: style, rect: rect, behind: false)
    }

    /// Paste plain text from another app as a text box centred on `worldPoint` (065).
    ///
    /// The LAST resort in the paste chain, deliberately: a pasteboard carrying a URL
    /// also carries that URL as a string, so running this before the importer would
    /// turn every pasted link into a text box instead of a reference.
    func pasteText(_ string: String, at worldPoint: CGPoint) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addText(
            worldRect: CGRect(
                x: worldPoint.x - Self.pastedTextWidth / 2, y: worldPoint.y,
                width: Self.pastedTextWidth, height: 0),
            string: trimmed)
    }

    /// How wide a text box pasted from plain text starts. A fixed, readable column:
    /// the height is then derived from the text wrapped to it (062), so a long paste
    /// grows downward rather than off the side of the board.
    static let pastedTextWidth: CGFloat = 320

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

    // MARK: - Duplicate (065)

    /// The rows a duplicate would create — pure, so the identity and stacking rules
    /// are tested without a database.
    ///
    /// Three rules, and each one is a bug if it is missed:
    ///
    /// - **Fresh `id`, everything else carried.** `kind`, `assetID`, `style` and size
    ///   all copy across, which is what makes ONE function serve a text box, a frame
    ///   and an asset placement. Duplicating an asset row makes a second *placement* of
    ///   the same asset, never a second asset — the board owns placements (059 · SP7).
    /// - **Relative order preserved.** Sources are taken in `z` order and re-stacked
    ///   from the top, so duplicating a stack keeps the stack.
    /// - **`spaceID` carried, not re-read.** A copy belongs to the board its source is
    ///   on; pasting into a *different* board rewrites it at the call site.
    static func duplicatedRows(
        of sources: [SpaceItem], offset: CGSize, startZ: Int, makeID: () -> UUID = UUID.init
    ) -> [SpaceItem] {
        sources
            .sorted { $0.z < $1.z }
            .enumerated()
            .map { index, source in
                var copy = source
                copy.id = makeID()
                copy.x += Double(offset.width)
                copy.y += Double(offset.height)
                copy.z = startZ + index
                return copy
            }
    }

    /// Duplicate rows by id, offset by `offset`, selecting the copies. One undo entry.
    ///
    /// Shared by ⌘D, an ⌥-drag drop and a paste of copied elements, so all three can
    /// never disagree about what a copy is. Routes through ``performBatch`` — the same
    /// primitive create/delete undo uses — because a duplicate IS a create, and giving
    /// it its own write path is how the two drift.
    func duplicate(itemIDs: Set<UUID>, offset: CGSize) {
        let sources = items.filter { itemIDs.contains($0.item.id) }.map(\.item)
        guard !sources.isEmpty else { return }
        insertRows(
            Self.duplicatedRows(of: sources, offset: offset, startZ: nextZ),
            name: sources.count == 1 ? "Duplicate" : "Duplicate Items")
    }

    /// The z a newly created row should take to sit on top of everything.
    private var nextZ: Int { (items.map(\.item.z).max() ?? -1) + 1 }

    /// Create `rows` as one undoable step and select them.
    ///
    /// The shared tail of ⌘D, an ⌥-drag drop and a paste. It routes through
    /// ``performBatch`` — the primitive create/delete undo already uses — because all
    /// three ARE creates, and giving any of them its own write path is how they drift.
    private func insertRows(_ rows: [SpaceItem], name: String) {
        guard !rows.isEmpty else { return }
        enqueue {
            await self.performBatch(rows, restore: true)
            // After the write, so the selection survives `load()`'s pruning of ids that
            // do not exist yet at the time it runs.
            self.selectedItemIDs = Set(rows.map(\.id))
            self.registerReversible(name,
                primary: { self.enqueue { await self.performBatch(rows, restore: true) } },
                inverse: { self.enqueue { await self.performBatch(rows, restore: false) } })
        }
    }

    /// Paste a copied piece of a board (065), CENTRED on `worldPoint` — a paste has no
    /// cursor position, so it lands on what the user is looking at rather than hanging
    /// off to the bottom-right of it.
    ///
    /// The payload's `spaceID` is this board's, not the one it was copied from, so a
    /// copy pastes into any board. An asset row pastes as another *placement* of the
    /// same asset; if that asset isn't in this library the write fails and surfaces on
    /// `lastError` rather than half-pasting.
    func pasteElements(_ payload: SpaceElementPayload, at worldPoint: CGPoint) {
        let size = payload.size
        let origin = CGPoint(
            x: worldPoint.x - size.width / 2, y: worldPoint.y - size.height / 2)
        insertRows(
            payload.rows(forSpaceID: spaceID, at: origin, startZ: nextZ),
            name: payload.rows.count == 1 ? "Paste" : "Paste Items")
    }

    /// Duplicate the current selection — ⌘D. Offset so the copy is visibly a copy
    /// rather than perfectly hidden behind its source.
    func duplicateSelection() {
        duplicate(itemIDs: selectedItemIDs, offset: Self.duplicateOffset)
    }

    /// Where a ⌘D copy lands relative to its source. Down-right, matching Figma and
    /// Finder, so the copy reads as "on top of and after" the original.
    static let duplicateOffset = CGSize(width: 10, height: 10)

    /// Duplicate the tiles an ⌥-drag carried, landing them at the drag's world offset
    /// (065). The originals stay where they were.
    func duplicateTiles(tileIDs: Set<Int>, offset: CGSize, in content: SpaceContent) {
        duplicate(
            itemIDs: Set(tileIDs.compactMap { content.spaceItemID(forTileID: $0) }),
            offset: offset)
    }

    /// The current `ElementStyle` for an element row (empty style if unset / not
    /// found), so the inspector can seed its editors.
    func style(forItemID id: UUID) -> ElementStyle {
        guard let detail = items.first(where: { $0.item.id == id }) else { return ElementStyle() }
        return ElementStyle(jsonString: detail.item.style) ?? ElementStyle()
    }

    /// The auto-sized world frame for a `.text` element under `style`, or `nil` when
    /// no geometry write is due — a non-`.text` row, or one whose measured fit
    /// already matches its current box (054 §4.2 · R4 · D7 · 062).
    ///
    /// The **height** is always derived from the text and is never the user's to set
    /// (062's invariant, unchanged). What 063 adds is a second, opt-in question — who
    /// owns the *width*:
    ///
    /// | `style.hugsWidth` | measured with | result |
    /// | --- | --- | --- |
    /// | `false` (062) | the box's own width | `x`, `y`, `w` frozen; `h` derived |
    /// | `true` (063) | unconstrained, capped | `y` frozen; `w` derived; `x` anchored |
    ///
    /// So a fixed box still grows and shrinks downward from a stationary top-left, and
    /// a hugging box additionally grows sideways from whichever edge its alignment
    /// names (see ``anchoredMinX(oldMinX:oldWidth:newWidth:alignment:)``).
    ///
    /// Measurement uses the SAME font as drawing (``ElementRendering/textStyle`` →
    /// ``TextMetrics``, which shapes through ``TextShaper``), so the box can't drift
    /// from the glyphs, and truncation is unreachable: the box always fits its text.
    func autosizedFrame(item: SpaceItem, style: ElementStyle) -> CGRect? {
        guard item.kind == .text else { return nil }
        let pad = Double(TextMetrics.padding)
        let ts = ElementRendering.textStyle(for: style)
        let measured = TextMetrics.size(
            for: ts, hugging: style.hugsWidth, outerWidth: CGFloat(item.w))
        let newHeight = Double(measured.height) + 2 * pad
        let newWidth = style.hugsWidth ? Double(measured.width) + 2 * pad : item.w
        let newX = style.hugsWidth
            ? Double(canvasInlineEditorAnchoredMinX(
                oldMinX: CGFloat(item.x), oldWidth: CGFloat(item.w),
                newWidth: CGFloat(newWidth), alignment: ts.alignment))
            : item.x
        // No change → no geometry write (the shrink-back / grow tests pin this).
        guard newHeight != item.h || newWidth != item.w || newX != item.x else { return nil }
        return CGRect(x: newX, y: item.y, width: newWidth, height: newHeight)
    }


    /// Bring every `.text` row's stored height into line with its text (062).
    ///
    /// 062 guarantees a text box fits its content, but rows written before it carry
    /// `.fixed`-era heights that don't — the mode used to let text overflow and be
    /// truncated. Re-deriving on load is what makes those boards correct the moment
    /// they are opened, rather than staying wrong until the row happens to be edited.
    ///
    /// Deliberately **in memory only**: no write, no undo entry, no `renderRevision`
    /// bump. The canvas is built from `items`, so correcting them here is enough to
    /// render right, and the corrected height persists on the row's next real edit.
    /// Writing during a load would put a mutation on every board open — churn, and a
    /// migration masquerading as the user's own change in the undo stack.
    func refitTextRows(_ rows: [SpaceItemDetail]) -> [SpaceItemDetail] {
        rows.map { detail in
            guard detail.item.kind == .text,
                  let fitted = autosizedFrame(
                    item: detail.item, style: ElementStyle(jsonString: detail.item.style) ?? ElementStyle())
            else { return detail }
            var item = detail.item
            // The whole fitted rect, not just the height: a hugging row (063) derives
            // its x and width too, and for a fixed row those are returned unchanged.
            item.x = Double(fitted.minX)
            item.w = Double(fitted.width)
            item.h = Double(fitted.height)
            return SpaceItemDetail(item: item, asset: detail.asset, source: detail.source)
        }
    }

    /// Commit a resize-handle drag (062): the dragged rect's origin + WIDTH are
    /// authoritative, and a text row's HEIGHT is re-derived from the text wrapped to
    /// that new width — so setting the width is the only thing a resize does, and the
    /// box still ends up exactly as tall as its content.
    ///
    /// Both halves land in ONE undo step, exactly as a restyle folds its auto-size in
    /// (054 §4.3 · D5): one ⌘Z restores the previous width AND height together.
    /// Mirrors ``moveTile(tileID:to:in:)`` — the tile is updated in the live content
    /// first (so nothing snaps between the drop and the write), then persisted with
    /// `reload: false`.
    ///
    /// **A drag that changes the width of a hugging box makes it fixed** (063 §3.4).
    /// Setting a width by hand is the plainest possible statement that the user wants
    /// to own it, so the box stops deriving one — otherwise the very next keystroke
    /// would undo the drag. A `.top` / `.bottom` drag changes no width and leaves the
    /// box hugging, which is what those handles imply. Turning hugging back ON is the
    /// Width control, never a gesture: that asymmetry is deliberate, and is only
    /// acceptable because the state is visible in the UI (062 §2's objection).
    func resizeTile(tileID: Int, to worldRect: CGRect, in content: SpaceContent) {
        guard let tile = content.tile(forTileID: tileID),
              let itemID = content.spaceItemID(forTileID: tileID),
              var item = items.first(where: { $0.item.id == itemID })?.item else { return }
        let old = Placement(x: tile.x, y: tile.y, w: tile.w, h: tile.h, z: tile.z)

        let oldStyle = style(forItemID: itemID)
        let converts = oldStyle.hugsWidth && Double(worldRect.width) != old.w
        var newStyle = oldStyle
        if converts { newStyle.textAutoWidth = false }

        // Anchor on the DRAGGED geometry before deriving, so the height is measured
        // against the width the user just chose rather than the stale one — and under
        // the NEW style, so a converting box derives its height at the dragged width
        // rather than re-hugging and discarding the drag.
        item.x = Double(worldRect.minX)
        item.y = Double(worldRect.minY)
        item.w = Double(worldRect.width)
        item.h = Double(worldRect.height)
        let derived = autosizedFrame(item: item, style: newStyle)
        let new = Placement(
            x: Double(worldRect.minX), y: Double(worldRect.minY),
            w: Double(worldRect.width), h: Double(derived?.height ?? worldRect.height), z: tile.z)
        guard old != new || converts else { return }

        // A conversion is a style change AND a geometry change, so it goes through the
        // path that already folds both into one undo entry rather than a second
        // registration next to the placement edit — two entries would mean two ⌘Zs to
        // undo one drag, with a half-converted box in between.
        if converts {
            applyRestyle(itemID, newStyle, placement: new)
            registerReversible("Resize",
                primary: { self.applyRestyle(itemID, newStyle, placement: new) },
                inverse: { self.applyRestyle(itemID, oldStyle, placement: old) })
            return
        }

        content.setPlacement(tileID: tileID, x: new.x, y: new.y, w: new.w, h: new.h)
        renderRevision += 1 // geometry changed in place → re-sync
        enqueue {
            await self.applyPlacementEdit(
                name: "Resize", edits: [(id: itemID, old: old, new: new)], reload: false)
        }
    }

    /// Persist an element's restyle (text, colours, stroke, label). For an auto-sized
    /// `.text` element the derived `w`/`h` rides along in the SAME transaction and the
    /// SAME undo step (054 §4.3 · D5) — one ⌘Z reverts both text and size. The change
    /// is applied to the live content IN MEMORY and re-synced via ``renderRevision``
    /// (never a host rebuild), so any visible restyle — geometry OR style-only — bumps
    /// ``renderRevision`` once as its redraw signal. Undoable — the prior style (and
    /// geometry, when it changed) is captured and restored, flicker-free, on undo.
    func updateStyle(itemID: UUID, style newStyle: ElementStyle) {
        guard var item = items.first(where: { $0.item.id == itemID })?.item else { return }
        let oldStyle = style(forItemID: itemID)

        // Geometry truth is the LIVE content: a drag / arrange persists with
        // `reload: false`, leaving `items` x/y/w/h stale until the next reload (see
        // ``livePlacement``). Anchor the restyle + auto-size on the live rect so an
        // edit after a move can't snap the element back to its pre-move position.
        let oldPlacement = livePlacement(itemID, in: content())
        item.x = oldPlacement.x; item.y = oldPlacement.y
        item.w = oldPlacement.w; item.h = oldPlacement.h; item.z = oldPlacement.z

        let newPlacement: Placement? = autosizedFrame(item: item, style: newStyle).map {
            Placement(x: Double($0.minX), y: Double($0.minY),
                      w: Double($0.width), h: Double($0.height), z: item.z)
        }
        let geomChanged = newPlacement != nil
        guard oldStyle != newStyle || geomChanged else { return }

        let name = item.kind == .text ? "Restyle Text" : "Restyle"
        applyRestyle(itemID, newStyle, placement: newPlacement)
        registerReversible(name,
            primary: { self.applyRestyle(itemID, newStyle, placement: newPlacement) },
            inverse: { self.applyRestyle(itemID, oldStyle, placement: geomChanged ? oldPlacement : nil) })
    }

    // MARK: - Errors

    /// The sentence this surface shows for a failure (099 · 6A).
    ///
    /// One override: a `.notFound` on the SPACE is the board being deleted out from
    /// under an open window, and this model exists to be that window. It is scoped
    /// to the space entity — the same switch used to answer "That space no longer
    /// exists." for a missing ASSET on the board, which is a different thing and
    /// Core says so.
    ///
    /// `.invalidPlacement` was an override and is not one any more: Core's "That
    /// position on the board isn't a place something can go." is this surface's own
    /// sentence, written once, where a new case cannot skip it.
    static func message(for error: Error) -> String {
        ErrorMessage.notFound(error, entity: "space", say: "That space no longer exists.")
            ?? ErrorMessage.text(for: error)
    }
}
