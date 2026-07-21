//
//  MasonryGridHost.swift
//  AtelierRefs
//
//  036 §2 A1 — the SwiftUI ↔ AppKit seam for the collection grid, behind the
//  `AtelierUseAppKitGrid` flag. An `NSViewRepresentable` over `NSScrollView` →
//  ``MasonryNSCollectionView`` with the ``MasonryCollectionLayout`` and layer-
//  backed ``MasonryGridItem`` cells, ported from the read-only spike measured in
//  038 §3.4. READ-ONLY in A1: `isSelectable = false` (native selection bypassed
//  entirely — the `GridSelection` reducer stays the only truth), no mouse /
//  hover / keyboard / drag / drop / context-menu / marquee routing. Those are
//  A2/A3; the coordinator subclass and the cell's inert seams exist so they slot
//  in without restructuring.
//
//  Data is an `NSCollectionViewDiffableDataSource<Int, UUID>` keyed on membership
//  `item.id`. A wholesale `items` republish (load / move / delete / reorder)
//  applies a snapshot with `animatingDifferences: false`; a same-id content edit
//  reconfigures the live cells in place (re-running `configure`, NEVER
//  `reloadItems` — reload flashes). Cells load through ``ThumbnailPipeline`` with a per-cell bucket
//  derived from the ANALYTIC frame (`thumbnailPixelBucket`), and the coordinator
//  adopts `NSCollectionViewPrefetching` onto the same pipeline.
//

import AppKit
import AtelierCore
import Combine
import SwiftUI

// MARK: - Configuration

/// Everything the host needs, as a plain value struct rebuilt on every SwiftUI
/// body pass (036 §2 A1). The closure bundle carries no model object — the
/// coordinator holds it — so the struct stays cheap to diff. `updateNSView`
/// diffs `(itemsVersion, density)` and `collectionID`; width changes are observed
/// by the layout off the clip view, not here.
struct GridHostConfiguration {
    var items: [CollectionItemDetail]
    /// The model's monotonic items version — bumped on every republish, so it is
    /// the single "the item set changed" signal, including in-place content edits.
    var itemsVersion: Int
    /// The density notch (columns are derived at the live width by the layout).
    var density: GridDensity
    var spacing: CGFloat
    var topInset: CGFloat
    /// Which collection these items belong to — a change resets the scroll offset.
    var collectionID: UUID
    /// Backing scale for the thumbnail pixel bucket (the other half alongside the
    /// analytic frame — 036 §4 C3).
    var displayScale: CGFloat
    /// `IngestionModel.thumbnailURL(for:)`, forwarded as a closure so the config
    /// carries no model object. `nil` for media-less kinds.
    var thumbnailURL: (CollectionItemDetail) -> URL?
    /// `IngestionModel.blobURL(for:)` — the ORIGINAL bytes, for the A3 GIF overlay.
    /// Held for the A3 seam; unused in A1.
    var blobURL: (CollectionItemDetail) -> URL?

    // MARK: A2 — selection + interaction seams

    /// The selection store (036 A0). The coordinator SUBSCRIBES to its
    /// `$selection` for layer-only reconciliation and mutates it through the same
    /// reducer seams (`apply`) the SwiftUI path used — a reference, so it is stable
    /// across the config's per-body rebuilds. This is the ONE model object the
    /// config carries; everything else stays a closure.
    var selectionStore: GridSelectionStore
    /// Open the detail overlay for a membership id — the `GridSelectionEffect`
    /// `.openDetail` sink (SwiftUI's `open(_:)`: lead + record-view + raise nav).
    var onOpenDetail: (UUID) -> Void
    /// Delete the current selection (`deleteBackward`/`deleteForward`, replacing
    /// `.onDeleteCommand` → `model.requestDeleteSelected()`).
    var onRequestDelete: () -> Void
    /// Spacebar Quick Look over the selection / lead (`presentQuickLook`).
    var onQuickLook: () -> Void
    /// ⌘+ / ⌘= — bigger cells, fewer columns (`gridPrefs.zoomIn`).
    var onZoomIn: () -> Void
    /// ⌘− — smaller cells, more columns (`gridPrefs.zoomOut`).
    var onZoomOut: () -> Void
}

// MARK: - The collection view subclass (A2 seam)

/// What the collection view forwards to the coordinator (036 §4 A2). Keyboard,
/// hover tracking, and the delete responder methods live here; the per-cell mouse
/// routing arrives via ``MasonryGridInteraction`` on the cell instead.
@MainActor
protocol MasonryGridViewEvents: AnyObject {
    /// A `keyDown` for arrows / return / esc / space / x / delete. Returns whether
    /// it was handled (an unhandled key falls through to `super`, so Escape when NOT
    /// selecting still reaches the detail overlay's own close).
    func gridKeyDown(_ event: NSEvent) -> Bool
    /// A `performKeyEquivalent` for the ⌘-combos (⌘A / ⌘± ). Returns handled.
    func gridPerformKeyEquivalent(_ event: NSEvent) -> Bool
    /// A responder-chain delete (Delete / Backspace / Forward-Delete).
    func gridDeleteCommand()
    /// The pointer moved to a window point (or `nil` on exit) — re-hit for hover.
    func gridMouseMoved(toWindowPoint point: CGPoint?)
    /// The clip view scrolled — re-hit hover at the last pointer location so a
    /// scroll under a stationary pointer updates the hovered cell (structurally
    /// fixes hover-during-scroll + the stranded circle; no `hoverAfterWindowChange`).
    func gridClipBoundsChanged()
}

/// `NSCollectionView` subclass. A1 turned native selection off; A2 makes it a
/// first responder and forwards keyboard + hover here so the SwiftUI delivery hacks
/// (`.focusable()/.onKeyPress`, per-cell `.onHover`) die. Cell mouse-down is
/// forwarded by the cell (``MasonryGridItem``), not intercepted here.
final class MasonryNSCollectionView: NSCollectionView {
    weak var events: MasonryGridViewEvents?
    private var hoverTrackingArea: NSTrackingArea?

    /// First responder so `keyDown`/`performKeyEquivalent` are delivered once a
    /// click has focused the grid (036 §4 A2 — focus follows the click).
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // ONE tracking area over the visible rect (036 §4 A2), rebuilt on resize.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        events?.gridMouseMoved(toWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        events?.gridMouseMoved(toWindowPoint: nil)
    }

    override func keyDown(with event: NSEvent) {
        if events?.gridKeyDown(event) == true { return }
        // Unhandled (incl. Escape when not selecting) → fall through so the
        // responder chain / detail overlay still sees it.
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if events?.gridPerformKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func deleteBackward(_ sender: Any?) { events?.gridDeleteCommand() }
    override func deleteForward(_ sender: Any?) { events?.gridDeleteCommand() }
}

// MARK: - The representable

struct MasonryGridHost: NSViewRepresentable {
    let configuration: GridHostConfiguration

    func makeCoordinator() -> MasonryGridCoordinator {
        MasonryGridCoordinator(configuration: configuration)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(configuration: configuration)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: MasonryGridCoordinator) {
        coordinator.tearDown()
    }
}

// MARK: - The coordinator

/// Owns the AppKit objects, the diffable data source, the prefetch bridge, and
/// (A2) all live interaction: it subscribes to `selectionStore.$selection` for
/// layer-only reconciliation and implements the mouse / hover / keyboard routing,
/// funnelling every gesture through the SAME pure tables the SwiftUI path used
/// (`gridPressRouting`/`gridClickAction`, `GridNavigation`, the `GridSelection`
/// reducer). It never mutates selection except through the store's reducer seams.
@MainActor
final class MasonryGridCoordinator: NSObject, NSCollectionViewPrefetching,
    MasonryGridInteraction, MasonryGridViewEvents {
    private var configuration: GridHostConfiguration
    private let layout = MasonryCollectionLayout()

    private var scrollView: NSScrollView?
    private var collectionView: MasonryNSCollectionView?
    private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>?

    /// The rendered item set, index-aligned to the snapshot order.
    private(set) var items: [CollectionItemDetail] = []
    /// Membership id → row, kept for the A2 coordinator's selection reconciliation
    /// (and unit-tested via ``gridIDToIndex(for:)``).
    private(set) var idToIndex: [UUID: Int] = [:]

    /// The `$selection` subscription driving layer-only reconciliation (A2).
    private var selectionCancellable: AnyCancellable?
    /// The selection the visible cells currently reflect — diffed against each new
    /// value so ``reconcileSelection(to:)`` touches only the CHANGED cells.
    private var reflectedSelection = GridSelection()
    /// The membership id under the pointer, if any (A2 hover). The circle shows on
    /// this cell while idle; driven by the one tracking area, re-hit on scroll.
    private var hoveredID: UUID?

    init(configuration: GridHostConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: Construction

    func makeScrollView() -> NSScrollView {
        layout.density = configuration.density
        layout.spacing = configuration.spacing
        layout.topInset = configuration.topInset

        let collectionView = MasonryNSCollectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Native selection bypassed entirely (036 §2 A1) — and A1 is read-only.
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.collectionViewLayout = layout
        collectionView.register(
            MasonryGridItem.self, forItemWithIdentifier: MasonryGridItem.identifier)
        collectionView.prefetchDataSource = self
        // A2 — keyboard + hover forwarding (cell mouse-down arrives via the cell).
        collectionView.events = self

        let scrollView = NSScrollView(frame: collectionView.frame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = collectionView

        let dataSource = NSCollectionViewDiffableDataSource<Int, UUID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, _ in
            let item = collectionView.makeItem(
                withIdentifier: MasonryGridItem.identifier, for: indexPath)
            if let self, let cell = item as? MasonryGridItem {
                self.configure(cell, at: indexPath.item)
            }
            return item
        }
        collectionView.dataSource = dataSource

        self.scrollView = scrollView
        self.collectionView = collectionView
        self.dataSource = dataSource

        observeClipView(scrollView.contentView)
        bindSelection()

        // Initial data.
        applyItems(configuration.items, resetScroll: true)

        return scrollView
    }

    /// Subscribe to the selection store for layer-only reconciliation (036 §4 A2).
    /// `@Published` replays the current value on subscribe; seeding
    /// `reflectedSelection` first makes that first emit a no-op.
    private func bindSelection() {
        reflectedSelection = configuration.selectionStore.selection
        selectionCancellable = configuration.selectionStore.$selection
            .sink { [weak self] newValue in self?.reconcileSelection(to: newValue) }
    }

    func tearDown() {
        selectionCancellable = nil
        NotificationCenter.default.removeObserver(self)
        // Drop any outstanding prefetches for this grid's hashes (visible loads
        // are never prefetch-tagged, so this cannot blank an on-screen cell).
        let hashes = items.compactMap { $0.asset.blobHash }
        if !hashes.isEmpty { ThumbnailPipeline.shared.cancelPrefetch(hashes: hashes) }
    }

    // MARK: Updates

    /// Push the config's inputs into the layout + data source. Diffs
    /// `(itemsVersion, density)` and `collectionID`; a scroll never reaches here,
    /// and a width change is handled by the clip-view observer, not this method.
    func update(configuration: GridHostConfiguration) {
        let old = self.configuration
        self.configuration = configuration
        layout.density = configuration.density
        layout.spacing = configuration.spacing
        layout.topInset = configuration.topInset

        let collectionChanged = old.collectionID != configuration.collectionID
        let versionChanged = old.itemsVersion != configuration.itemsVersion

        if collectionChanged || versionChanged || items.count != configuration.items.count {
            applyItems(configuration.items, resetScroll: collectionChanged)
        } else if old.density != configuration.density {
            // A density step (⌘±) at an unchanged item set: re-solve the masonry,
            // reconfigure the visible cells so their thumbnail bucket tracks the new
            // cell size, and keep the topmost visible item anchored across the
            // re-layout so the viewport doesn't jump (036 §4 A2 — non-animated first).
            let topIndex = topmostVisibleIndex()
            layout.invalidateLayout()
            reconfigureVisibleItems()
            restoreTopIndex(topIndex)
        }
    }

    /// The lowest visible item index — the topmost cell in the flipped grid — used
    /// to anchor the viewport across a density re-layout.
    private func topmostVisibleIndex() -> Int? {
        collectionView?.indexPathsForVisibleItems().map(\.item).min()
    }

    /// Scroll `index` back to the top of the viewport after a density re-layout
    /// (non-animated). A `nil` index (nothing was visible) leaves the offset alone.
    private func restoreTopIndex(_ index: Int?) {
        guard let collectionView, let index, items.indices.contains(index) else { return }
        collectionView.layoutSubtreeIfNeeded()
        collectionView.scrollToItems(
            at: [IndexPath(item: index, section: 0)], scrollPosition: .top)
    }

    /// Apply a new item set. Same-id, same-order republishes reconfigure in place
    /// (a content edit); anything else applies a fresh snapshot. `resetScroll`
    /// returns to the top on a collection switch.
    private func applyItems(_ newItems: [CollectionItemDetail], resetScroll: Bool) {
        let oldIDs = gridSnapshotIDs(for: items)
        let newIDs = gridSnapshotIDs(for: newItems)

        items = newItems
        idToIndex = gridIDToIndex(for: newItems)
        layout.itemsVersion = configuration.itemsVersion
        layout.aspects = newItems.map { aspect(for: $0) }
        layout.invalidateLayout()

        switch gridApplyStrategy(oldIDs: oldIDs, newIDs: newIDs, collectionChanged: resetScroll) {
        case .reconfigure:
            // Same membership + order — a content edit. Re-run `configure` on the
            // live cells directly: no snapshot, and NEVER `reloadItems` (it
            // flashes — 036 §2 A1). `NSCollectionViewDiffableDataSource` has no
            // `reconfigureItems` on this SDK, so the in-place reconfigure IS this
            // visible-cell pass; recycled cells reconfigure through the item
            // provider when they next scroll in.
            reconfigureVisibleItems()
        case .snapshot:
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(newIDs, toSection: 0)
            dataSource?.apply(snapshot, animatingDifferences: false)
            if resetScroll { scrollToTop() }
        }
    }

    /// Re-run `configure` on every materialized cell in place — no snapshot, no
    /// reload. Used for a same-id content edit and a density step (the thumbnail
    /// bucket tracks the new cell size). Offscreen cells reconfigure through the
    /// item provider when they next scroll into view.
    private func reconfigureVisibleItems() {
        guard let collectionView else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: indexPath) as? MasonryGridItem else { continue }
            configure(cell, at: indexPath.item)
        }
    }

    private func scrollToTop() {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Cell configuration

    private func configure(_ cell: MasonryGridItem, at index: Int) {
        guard items.indices.contains(index) else { return }
        let detail = items[index]
        cell.interaction = self
        cell.configure(
            detail: detail,
            url: configuration.thumbnailURL(detail),
            bucket: bucket(at: index))
        // Paint the cell's CURRENT selection + hover, so a freshly materialized or
        // reconfigured cell (scroll-in, snapshot, density step) shows the right
        // rings/circle without waiting for a reconcile tick — this is also how a
        // cell scrolled off mid-change, or a lead that wasn't visible, repaints
        // correctly when it next comes on screen (036 §4 A2).
        let selection = configuration.selectionStore.selection
        cell.applySelectionState(cellSelectionState(for: detail.item.id, selection: selection))
        cell.setHovered(hoveredID == detail.item.id)
    }

    /// The per-cell selection inputs for `id` under `selection` — the pure mapping
    /// both ``configure`` and ``reconcileSelection(to:)`` render via
    /// ``MasonryGridItem/applySelectionState(_:)``.
    private func cellSelectionState(for id: UUID, selection: GridSelection) -> CellSelectionState {
        CellSelectionState(
            isSelected: selection.ids.contains(id),
            isCursor: selection.lead == id,
            isSelecting: selection.isSelecting)
    }

    /// The pixel bucket for a cell, from its ANALYTIC frame (the cell never
    /// guesses its own size — 036 §4 C3). Falls back to the solved column width
    /// before a frame exists.
    private func bucket(at index: Int) -> Int {
        gridThumbnailBucket(
            frame: layout.analyticFrame(at: index),
            columnWidth: layout.solvedColumnWidth,
            scale: configuration.displayScale)
    }

    // MARK: Clip-view observation (width → invalidate)

    private func observeClipView(_ clipView: NSClipView) {
        clipView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification, object: clipView)
        // A2 hover: a scroll moves content under a stationary pointer without a
        // `mouseMoved`, so re-hit hover on the clip view's BOUNDS change too.
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clipView)
    }

    @objc private func clipBoundsChanged() { gridClipBoundsChanged() }

    /// The viewport RESIZED — the one event that legitimately re-solves the
    /// masonry. AppKit does not necessarily ask `shouldInvalidateLayout` for this
    /// (the collection view's own width is derived from the content size, so
    /// waiting for its bounds to move is circular), hence the explicit
    /// invalidation off the clip view.
    @objc private func clipFrameChanged() {
        guard let width = scrollView?.contentSize.width, width > 0 else { return }
        if abs(width - layout.preparedWidth) > 0.5 {
            layout.invalidateLayout()
        }
    }

    // MARK: Prefetching (036 §4 C3 → ThumbnailPipeline)

    func collectionView(
        _ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let requests = indexPaths.compactMap { request(at: $0.item) }
        if !requests.isEmpty { ThumbnailPipeline.shared.prefetch(requests) }
    }

    func collectionView(
        _ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        // A visible request JOINS an in-flight prefetch task, so a hash that
        // crossed into the visible window must NOT be cancelled or the on-screen
        // cell awaiting that decode blanks (036 §4 C1). AppKit already stops
        // treating a now-visible item as a prefetch candidate; excluding the live
        // set here is the belt-and-braces guard.
        let visible = Set(collectionView.indexPathsForVisibleItems().map(\.item))
        let hashes = indexPaths.compactMap { path -> String? in
            guard !visible.contains(path.item), items.indices.contains(path.item) else { return nil }
            return items[path.item].asset.blobHash
        }
        if !hashes.isEmpty { ThumbnailPipeline.shared.cancelPrefetch(hashes: hashes) }
    }

    private func request(at index: Int) -> ThumbnailRequest? {
        guard items.indices.contains(index) else { return nil }
        let detail = items[index]
        guard let hash = detail.asset.blobHash,
              let url = configuration.thumbnailURL(detail) else { return nil }
        return ThumbnailRequest(hash: hash, url: url, bucket: bucket(at: index))
    }

    // MARK: Selection reconciliation (036 §4 A2 — layer-only, the multi-select win)

    /// The store published a new selection. Diff it against what the cells reflect
    /// and mutate ONLY the changed VISIBLE cells' layers — no snapshot, no relayout.
    /// This is the payoff: a shift-click adding 200 items still only repaints the
    /// handful of cells actually on screen whose state changed (or, on a mode flip,
    /// every visible cell — to add/remove all circles). Cells that changed while
    /// OFF screen are not touched here; they repaint from ``configure`` on scroll-in.
    private func reconcileSelection(to newValue: GridSelection) {
        let old = reflectedSelection
        reflectedSelection = newValue
        guard collectionView != nil else { return }
        let delta = selectionCellDelta(from: old, to: newValue)
        let targets = selectionReconcileTargets(delta: delta, visibleIDs: visibleItemIDs())
        for id in targets {
            guard let index = idToIndex[id], let cell = cellIfVisible(at: index) else { continue }
            cell.applySelectionState(cellSelectionState(for: id, selection: newValue))
        }
    }

    /// The membership ids of the currently materialized (visible) cells.
    private func visibleItemIDs() -> Set<UUID> {
        guard let collectionView else { return [] }
        var ids = Set<UUID>()
        for path in collectionView.indexPathsForVisibleItems() where items.indices.contains(path.item) {
            ids.insert(items[path.item].item.id)
        }
        return ids
    }

    private func cellIfVisible(at index: Int) -> MasonryGridItem? {
        collectionView?.item(at: IndexPath(item: index, section: 0)) as? MasonryGridItem
    }

    /// The live column count for `nextGridIndex`'s arrow math — the solved value,
    /// matching the SwiftUI path's `gridColumns(forWidth:)`.
    private func currentColumns() -> Int { layout.solvedColumns }

    // MARK: Mouse (036 §4 A2 — reuse gridPressRouting / gridClickAction)

    func gridCellMouseDown(id: UUID, event: NSEvent) {
        guard idToIndex[id] != nil else { return }
        // Focus follows the click, so keyboard nav works afterwards.
        collectionView?.window?.makeFirstResponder(collectionView)

        let selection = configuration.selectionStore.selection
        let (shift, command) = gridMouseModifiers(from: event.modifierFlags)
        // Down-edge routing (Finder): ⇧/⌘ and toggling an unselected cell ON while
        // selecting fire immediately, so a drag activation can't swallow them.
        let routing = gridPressRouting(
            imageID: id, isSelecting: selection.isSelecting,
            isSelected: selection.ids.contains(id), shift: shift, command: command)
        if let action = routing.pressAction {
            execute(configuration.selectionStore.apply(action, columns: currentColumns()))
        }
        classifyClickOrDrag(
            id: id, downEvent: event, consumesRelease: routing.consumesRelease,
            shift: shift, command: command)
    }

    /// The local drag-threshold loop (036 §4 A2). Tracks drag/up until the pointer
    /// crosses ~4pt: a drag hands off to A3 (a no-op stub here), an up before the
    /// threshold is a CLICK — which applies the mouse-up action unless the press
    /// already consumed it (`gridClickAction`, the pure table). This is the AppKit
    /// peer of the SwiftUI press-vs-click split, minus the delivery hacks.
    private func classifyClickOrDrag(
        id: UUID, downEvent: NSEvent, consumesRelease: Bool, shift: Bool, command: Bool
    ) {
        let didDrag = trackDragThreshold(from: downEvent)
        if didDrag {
            // A3: begin the `NSDraggingSource` session from here. Classification is
            // A2; the drag hand-off itself is deliberately a no-op stub until A3.
            beginDragHandoffStub(id: id)
            return
        }
        guard !consumesRelease else { return }
        let action = gridClickAction(imageID: id, shift: shift, command: command)
        execute(configuration.selectionStore.apply(action, columns: currentColumns()))
    }

    /// Pump left-drag/up events until the pointer moves past the 4pt threshold
    /// (returns `true`, a drag) or the mouse comes up first (returns `false`, a
    /// click). Runs on the main run loop via `nextEvent` — the standard AppKit
    /// drag-detection idiom.
    private func trackDragThreshold(from downEvent: NSEvent) -> Bool {
        guard let window = collectionView?.window else { return false }
        let start = downEvent.locationInWindow
        let threshold: CGFloat = 4
        while true {
            guard let event = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp]) else { return false }
            if event.type == .leftMouseUp { return false }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            if (dx * dx + dy * dy) >= threshold * threshold { return true }
        }
    }

    /// A3 stub — the drag classified above will start an `NSDraggingSource` session
    /// carrying the `AssetDragPayload`. In A2 it is intentionally inert.
    private func beginDragHandoffStub(id: UUID) {}

    func gridCellCircleClicked(id: UUID) {
        collectionView?.window?.makeFirstResponder(collectionView)
        execute(configuration.selectionStore.apply(.tapCircle(id), columns: currentColumns()))
    }

    // MARK: Effects

    /// Carry out a reducer ``GridSelectionEffect`` — the AppKit peer of
    /// `CollectionView.execute`: open a detail page, or scroll a cell into view.
    private func execute(_ effect: GridSelectionEffect) {
        switch effect {
        case .none:
            break
        case let .scrollTo(id):
            scrollItemIntoView(id)
        case let .openDetail(id):
            configuration.onOpenDetail(id)
        }
    }

    /// Scroll a cell to the vertical centre — matches `proxy.scrollTo(id,
    /// anchor: .center)` (036 §4 A2 — animated).
    private func scrollItemIntoView(_ id: UUID) {
        guard let collectionView, let index = idToIndex[id] else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            collectionView.animator().scrollToItems(
                at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        }
    }

    // MARK: Keyboard (036 §4 A2 — reuse GridNavigation + the reducer)

    func gridKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        // ⌘-combos travel through `performKeyEquivalent`, earlier in the chain.
        if mods.contains(.command) { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        if gridIsDeleteKey(characters: chars) {
            configuration.onRequestDelete()
            return true
        }
        guard let command = gridKeyCommand(characters: chars, modifiers: mods) else { return false }
        return execute(keyCommand: command)
    }

    func gridPerformKeyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        guard mods.contains(.command) else { return false }
        guard let command = gridKeyCommand(
            characters: event.charactersIgnoringModifiers ?? "", modifiers: mods) else { return false }
        return execute(keyCommand: command)
    }

    func gridDeleteCommand() { configuration.onRequestDelete() }

    /// Execute a resolved ``GridKeyCommand``; returns whether it was HANDLED (an
    /// unhandled result falls through to `super.keyDown`). Selection commands route
    /// through the store's reducer; density/QuickLook/open ride the config closures.
    private func execute(keyCommand command: GridKeyCommand) -> Bool {
        let store = configuration.selectionStore
        switch command {
        case let .arrow(key, extend):
            execute(store.apply(.arrow(key, extend: extend), columns: currentColumns()))
        case .openLead:
            // Parity with the SwiftUI Return handler: `.none` (no cursor) is
            // "ignored", so it falls through rather than being swallowed.
            let effect = store.apply(.openLead, columns: currentColumns())
            execute(effect)
            return effect != .none
        case .escape:
            // Consume ONLY when selecting; otherwise fall through to `super` so the
            // detail overlay's own Escape close still works (parity with the
            // SwiftUI `.onKeyPress(.escape)` guard).
            guard store.selection.isSelecting else { return false }
            store.apply(.clear)
        case .quickLook:
            configuration.onQuickLook()
        case .toggleLead:
            store.apply(.toggleLead)
        case .selectAll:
            store.apply(.selectAll)
        case .zoomIn:
            configuration.onZoomIn()
        case .zoomOut:
            configuration.onZoomOut()
        }
        return true
    }

    // MARK: Hover (036 §4 A2 — one tracking area, zero-rect hit-test)

    func gridMouseMoved(toWindowPoint point: CGPoint?) {
        guard let collectionView else { return }
        let index: Int?
        if let point {
            index = layout.hitTestIndex(at: collectionView.convert(point, from: nil))
        } else {
            index = nil
        }
        let id = index.flatMap { items.indices.contains($0) ? items[$0].item.id : nil }
        setHovered(id)
    }

    func gridClipBoundsChanged() {
        guard let collectionView, let window = collectionView.window else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = collectionView.convert(windowPoint, from: nil)
        // Only track hover while the pointer is actually over the visible grid — a
        // scroll with the pointer elsewhere (e.g. over the scroller) strands nothing.
        if collectionView.visibleRect.contains(viewPoint) {
            setHovered(layout.hitTestIndex(at: viewPoint).flatMap {
                items.indices.contains($0) ? items[$0].item.id : nil
            })
        } else {
            setHovered(nil)
        }
    }

    /// Move the hover to `id` (or clear it), toggling the circle on the leaving and
    /// entering cells only — layer-only, like selection reconciliation.
    private func setHovered(_ id: UUID?) {
        guard id != hoveredID else { return }
        if let old = hoveredID, let index = idToIndex[old], let cell = cellIfVisible(at: index) {
            cell.setHovered(false)
        }
        hoveredID = id
        if let id, let index = idToIndex[id], let cell = cellIfVisible(at: index) {
            cell.setHovered(true)
        }
    }
}

// MARK: - Pure coordinator helpers (unit-tested)

/// The thumbnail pixel bucket for a cell from its ANALYTIC masonry `frame` (036
/// §4 C3 — the cell never guesses its own size). The long side, because the tile
/// crop-FILLS its rect; a `nil` frame (before the layout has solved) falls back
/// to the solved `columnWidth`. Shared by the coordinator's visible-cell path
/// and its prefetch requests so the pixels prefetched and the pixels drawn agree.
func gridThumbnailBucket(frame: CGRect?, columnWidth: CGFloat, scale: CGFloat) -> Int {
    let longSide = max(frame?.width ?? columnWidth, frame?.height ?? 0)
    return thumbnailPixelBucket(pointLongSide: longSide, scale: scale)
}

/// The snapshot's item identifiers: membership `item.id` in display order.
func gridSnapshotIDs(for items: [CollectionItemDetail]) -> [UUID] {
    items.map { $0.item.id }
}

/// The id → row index map the coordinator keeps for A2 selection reconciliation.
/// A later duplicate id (which should not occur — memberships are unique) keeps
/// its LAST position, matching the snapshot's own last-wins behavior.
func gridIDToIndex(for items: [CollectionItemDetail]) -> [UUID: Int] {
    var map: [UUID: Int] = [:]
    map.reserveCapacity(items.count)
    for (index, detail) in items.enumerated() { map[detail.item.id] = index }
    return map
}

/// How to push a new item set to the diffable data source.
enum GridApplyStrategy: Equatable {
    /// Same membership + order, same collection → reconfigure in place (a content
    /// edit such as a resolved thumbnail or a rename). Avoids the snapshot churn
    /// and the `reloadItems` flash.
    case reconfigure
    /// New / reordered membership, or a collection switch → apply a fresh snapshot.
    case snapshot
}

/// Choose the apply strategy from the id order before/after and whether the
/// collection changed. A collection switch always snapshots (and resets scroll);
/// otherwise identical id order reconfigures, any other change snapshots.
func gridApplyStrategy(
    oldIDs: [UUID], newIDs: [UUID], collectionChanged: Bool
) -> GridApplyStrategy {
    (!collectionChanged && oldIDs == newIDs) ? .reconfigure : .snapshot
}

// MARK: - Selection reconciliation (036 §4 A2 — pure, unit-tested)

/// The cells whose rendered selection state changed between two selections, plus
/// whether the grid-global "selecting" mode FLIPPED (036 §4 A2). The changed set is
/// the symmetric difference of the selected `ids` UNIONED with any `lead` (cursor)
/// move — a cell can change ring purely because the cursor left or arrived on it
/// even though its membership didn't. `modeFlipped` is the first-select /
/// last-deselect edge: it toggles the circle on EVERY cell (all become / stop being
/// toggleable), so the coordinator must repaint all visible cells, not just these.
///
/// The classic omitted case is the lead move: two selections with identical `ids`
/// but a different `lead` still change exactly two cells (old + new cursor), and a
/// delta that only diffed `ids` would miss both. Both directions of the mode flip
/// (empty → non-empty and non-empty → empty) are likewise reported.
func selectionCellDelta(
    from old: GridSelection, to new: GridSelection
) -> (changed: Set<UUID>, modeFlipped: Bool) {
    var changed = old.ids.symmetricDifference(new.ids)
    if old.lead != new.lead {
        if let lead = old.lead { changed.insert(lead) }
        if let lead = new.lead { changed.insert(lead) }
    }
    return (changed, old.isSelecting != new.isSelecting)
}

/// The VISIBLE cells the coordinator must repaint for a selection change (036 §4
/// A2). A mode flip repaints every visible cell (all circles appear / vanish);
/// otherwise only the changed cells that are actually on screen — cells changed
/// while off screen repaint from `configure` on scroll-in, so they are excluded
/// here. Keeping this pure is how the layer-only reconcile path is tested without a
/// live collection view: the set returned is exactly the set of cells touched.
func selectionReconcileTargets(
    delta: (changed: Set<UUID>, modeFlipped: Bool), visibleIDs: Set<UUID>
) -> Set<UUID> {
    delta.modeFlipped ? visibleIDs : delta.changed.intersection(visibleIDs)
}

// MARK: - Mouse + keyboard routing (036 §4 A2 — pure, unit-tested)

/// The `(shift, command)` booleans the pure `gridPressRouting`/`gridClickAction`
/// tables take, read off an `NSEvent`'s modifier flags. Isolated so the flag read
/// is testable apart from a live event (other modifiers — option / control — are
/// deliberately ignored, matching the SwiftUI cell's `shift`/`command` reads).
func gridMouseModifiers(from flags: NSEvent.ModifierFlags) -> (shift: Bool, command: Bool) {
    (flags.contains(.shift), flags.contains(.command))
}

/// Whether `characters` (from `charactersIgnoringModifiers`) is a Delete key —
/// Backspace (DEL, `0x7F`) or Forward-Delete (`NSDeleteFunctionKey`). Routed to
/// `requestDeleteSelected` (replacing SwiftUI's `.onDeleteCommand`).
func gridIsDeleteKey(characters: String) -> Bool {
    guard let scalar = characters.unicodeScalars.first else { return false }
    return scalar.value == 0x7F || Int(scalar.value) == NSDeleteFunctionKey
}

/// A resolved grid keyboard command (036 §4 A2). The NSEvent → command mapping is
/// pure and testable; the coordinator executes each through the SAME reducer /
/// nav seams the SwiftUI `.onKeyPress` chain used.
enum GridKeyCommand: Equatable {
    /// An arrow key; `extend` is ⇧ held (grow the range vs move the cursor).
    case arrow(GridArrowKey, extend: Bool)
    /// Return — open the cursor item's detail.
    case openLead
    /// Escape — clear the selection when selecting, else fall through.
    case escape
    /// Space — Quick Look the selection / lead.
    case quickLook
    /// X (no modifiers) — toggle the cursor cell in place.
    case toggleLead
    /// ⌘A — select all.
    case selectAll
    /// ⌘+ / ⌘= — bigger cells (fewer columns).
    case zoomIn
    /// ⌘− — smaller cells (more columns).
    case zoomOut
}

/// Map a key (its `charactersIgnoringModifiers` + `modifiers`) to a
/// ``GridKeyCommand``, or `nil` when the grid doesn't handle it (036 §4 A2).
/// Mirrors the SwiftUI `.onKeyPress` handlers exactly:
///
/// - Arrows (Up/Down/Left/Right) → cursor move, ⇧ extends. Command-arrows are NOT
///   claimed (the caller routes ⌘-combos through `performKeyEquivalent`, and the
///   grid has no ⌘-arrow binding).
/// - Return → `.openLead`; Escape → `.escape`; Space → `.quickLook` — none under ⌘.
/// - `x` with NO modifiers → `.toggleLead` (SwiftUI guards `modifiers.isEmpty`, so
///   even ⇧X is ignored — it never eats ⌘X etc).
/// - ⌘A → `.selectAll`; ⌘+ / ⌘= → `.zoomIn`; ⌘− → `.zoomOut`.
func gridKeyCommand(
    characters: String, modifiers: NSEvent.ModifierFlags
) -> GridKeyCommand? {
    let command = modifiers.contains(.command)
    let shift = modifiers.contains(.shift)
    let bareModifiers = modifiers.intersection([.command, .shift, .option, .control])

    // Function keys (arrows) arrive as their unicode scalars.
    if let scalar = characters.unicodeScalars.first {
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return command ? nil : .arrow(.up, extend: shift)
        case NSDownArrowFunctionKey: return command ? nil : .arrow(.down, extend: shift)
        case NSLeftArrowFunctionKey: return command ? nil : .arrow(.left, extend: shift)
        case NSRightArrowFunctionKey: return command ? nil : .arrow(.right, extend: shift)
        default: break
        }
    }

    switch characters {
    case "\r", "\u{3}": return command ? nil : .openLead    // Return / Enter
    case "\u{1b}": return command ? nil : .escape           // Escape
    case " ": return command ? nil : .quickLook             // Space
    case "a", "A": return command ? .selectAll : nil        // ⌘A
    case "=", "+": return command ? .zoomIn : nil           // ⌘= / ⌘+
    case "-": return command ? .zoomOut : nil               // ⌘−
    case "x", "X": return bareModifiers.isEmpty ? .toggleLead : nil  // X, no modifiers
    default: return nil
    }
}
