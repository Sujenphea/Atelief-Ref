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
import AtelierArchive
import AtelierCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    /// It ALSO bumps when the group-carousels toggle flips (307): collapsing changes
    /// the display list without changing the underlying items, and this version is
    /// the only key `MasonryLayoutCache` has — without the bump it would serve the
    /// previous solve and lay cells out against stale analytic frames.
    var itemsVersion: Int
    /// The feed bucketed by originating post (307 · carousel grouping), built ONCE
    /// by the owning model and passed down. The host used to rebuild an identical
    /// index from the same items; one owner means the two can no longer disagree.
    var postGroups: PostGroups = PostGroups()
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
    /// **⌫** — remove the current selection from the container in view (022 · D2).
    /// The collection grid drops the membership (undoable, no dialog); a
    /// membership-less grid (search) passes a no-op, which is the correct answer
    /// there rather than a missing feature.
    ///
    /// Split from ``onRequestDelete`` because ⌫ and ⌘⌫ now mean different verbs:
    /// this used to be the same closure, which made the SOFTEST key on the keyboard
    /// the one that left the library.
    var onRequestRemove: () -> Void
    /// **⌘⌫** — delete the current selection from the library (`model.requestDelete`
    /// → the shared confirmation → `deleteAssetsRecoverable`). The one destructive
    /// path; it arrives through `performKeyEquivalent`, not the delete responder
    /// methods.
    var onRequestDelete: () -> Void
    /// Copy the current selection to the pasteboard (Edit ▸ Copy / ⌘C, 052 · B1) —
    /// wraps `model.copyToPasteboard(assets:sourceCollectionID:)` over the
    /// grid-ordered selection.
    var onCopy: () -> Void
    /// Spacebar Quick Look over the selection / lead (`presentQuickLook`).
    var onQuickLook: () -> Void
    /// ⌘+ / ⌘= — bigger cells, fewer columns (`gridPrefs.zoomIn`).
    var onZoomIn: () -> Void
    /// ⌘− — smaller cells, more columns (`gridPrefs.zoomOut`).
    var onZoomOut: () -> Void
    /// **`M` / `A`** — raise the shared destination picker on "Move to…" / "Add to…"
    /// (024 · K3). The grid reports only WHICH verb was pressed: what it acts on is
    /// the owning view's business, and it is deliberately the same rule ⌫ and ⌘D
    /// already use (``IngestionModel/destinationActionTargets``) rather than a second
    /// one read off the cells here.
    ///
    /// `nil` — the default — leaves the two keys UNBOUND on this grid rather than
    /// bound to nothing: the decoded command falls through to `super.keyDown` exactly
    /// as it did before K3. That is the right answer on a membership-less surface (the
    /// search grid has no collection to move out of), and it matters that the key is
    /// unhandled rather than silently eaten, since a swallowed letter is how a surface
    /// acquires a key that does nothing and cannot be explained.
    var onDestinationVerb: ((CollectionDestinationMenu.Verb) -> Void)?
    /// Filled with the grid's own view so the owning SwiftUI view can hand first
    /// responder BACK after a keyboard-raised popover closes (024 · K3) — the
    /// discipline `DetailKeyCatcher.restoreResponder` and `SpaceView`'s
    /// `restoreCanvasFocus` both follow. `nil` on a surface that raises no popover.
    var focusHandle: GridFocusHandle?

    // MARK: A3 — drag out / drop / context menu seams

    /// The `AssetDragPayload` for a drag starting on a cell `itemID`: the whole
    /// selection when the cell is selected, else the cell alone
    /// (`IngestionModel.dragPayload(forCellItemID:)`). `nil` only if the cell
    /// vanished — the coordinator falls back to a lone-cell payload.
    var dragPayload: (UUID) -> AssetDragPayload?
    /// The drag image for a cell `itemID`, rendered on the SwiftUI side via
    /// `ImageRenderer` over the EXISTING `dragPreview` (thumbnail + count badge),
    /// so the AppKit drag looks identical to the SwiftUI one.
    var dragImage: (UUID) -> NSImage?
    /// Whether this collection can be reordered by dragging — `sortMode ==
    /// .manual` (040). Gates the live reorder preview at `draggingEntered`: a
    /// non-manual sort shows NO preview and reports "no drop" (`[]`), so the
    /// cursor never lies about a reorder that would then be refused.
    var canReorder: Bool
    /// Commit a reorder previewed on the grid (040): the dragged payload and the
    /// insertion `slot` the live preview settled on. Wraps `handleSlotDrop` →
    /// `routeDrop` → `reorderItems(movingAssetIDs:insertAt:)`. Returns whether the
    /// drop was accepted.
    var onReorderCommit: (AssetDragPayload, _ insertAt: Int) -> Bool

    /// The assets a menu / drag acts on for the cell `itemID` — the Finder scope
    /// rule (`IngestionModel.actionTargets(forCellItemID:)`): a right-click INSIDE
    /// the selection acts on the whole selection, OUTSIDE it on that one cell.
    var actionTargets: (UUID) -> [UUID]
    /// The WHOLE collection hierarchy as move/copy destinations (027 · G2), from
    /// the memoized ``MoveTargetsCache`` — carried as a value so the native menu
    /// nests its submenus on right-click without re-grouping the folder tree.
    /// Replaced the old flat `MoveTargets` (direct subfolders + roots), which made
    /// anything two levels down unreachable by right-click at any depth.
    var destinationTree: [DestinationTreeNode]
    /// The protected Unsorted root's id — the destination menu pins it first and
    /// separates it from the user's own folders.
    var destinationUnsortedID: UUID
    /// Destinations listed but GREYED: the collection on screen (filing where the
    /// items already live is a no-op). Empty on a membership-less surface.
    var disabledDestinations: Set<UUID> = []
    /// Move the given assets into a collection (menu "Move to ▸").
    var onMoveToCollection: (_ assetIDs: [UUID], _ targetID: UUID) -> Void
    /// Copy (add) the given assets into a collection (menu "Add to ▸").
    var onCopyToCollection: (_ assetIDs: [UUID], _ targetID: UUID) -> Void
    /// Set a single asset as this collection's cover (menu "Set as Cover").
    var onSetCover: (_ assetID: UUID) -> Void
    /// Remove the given assets from this collection (menu "Remove from Collection").
    var onRemoveFromCollection: (_ assetIDs: [UUID]) -> Void
    /// Delete the given assets from the library entirely (menu "Delete", confirmed).
    var onDelete: (_ assetIDs: [UUID]) -> Void
    /// The carousel chip was clicked on this tile (307) — open or close its post in
    /// place. Defaults to a no-op so a surface without grouping needn't supply it.
    var onToggleExpand: (UUID) -> Void = { _ in }
    /// Representative ids of posts opened in place (307), so a cell knows whether it
    /// still stands for hidden members and should draw the pile.
    var expandedPosts: Set<UUID> = []
    /// Whether the full-window detail page is up over this grid (069).
    ///
    /// The grid is still FIRST RESPONDER behind the overlay — it takes focus on the
    /// click that opens the page (`gridCellMouseDown`) and nothing resigns for it — so
    /// without this gate its `keyDown` swallows the arrows the page's own pager needs,
    /// and each press silently walks + scrolls a grid the user cannot see. Defaulted
    /// false so a surface with no detail page needn't supply it.
    var isDetailPresented: Bool = false

    // MARK: 048 — membership-less (search) reuse

    /// Which context-menu verbs the grid offers. `.collection` is the full
    /// membership menu; `.looseAssets` is for membership-less hits (search),
    /// where Move / Set Cover / Remove don't apply — see ``GridMenuStyle``.
    /// Defaulted so the collection grid's call site is unchanged (048).
    var menuStyle: GridMenuStyle = .collection
    /// Reveal a single byte-backed asset (cell `itemID`) in Finder — offered only
    /// in the `.looseAssets` menu for a lone hit that has bytes on disk. A no-op
    /// by default (the collection menu has no Reveal verb).
    var onReveal: (UUID) -> Void = { _ in }

    // MARK: 023 · A2 — the archive shelf

    /// Take assets off the archive shelf — offered only by the `.shelf` menu.
    /// A no-op by default: every other surface shows items that are, by
    /// construction, not archived, so there is nothing there to unarchive.
    var onUnarchive: (_ assetIDs: [UUID]) -> Void = { _ in }

    /// The `E` key's archive verb (023 · A3), raised for the surface to resolve
    /// against its own selection — the same shape as ``onDestinationVerb``, and
    /// `nil` for the same reason: a surface that does not bind the letter lets
    /// it fall through rather than swallowing it.
    var onArchiveVerb: (() -> Void)?

    /// Put specific assets on the shelf — the menu's Archive item, which acts on
    /// the cell's Finder-scope targets rather than on the keyboard selection.
    /// A no-op by default, so a surface that binds neither is unchanged.
    var onArchive: (_ assetIDs: [UUID]) -> Void = { _ in }

    // MARK: 011 · A2/A3 — out-flow (originals folder + share sheet)

    /// Export the cell's Finder-scope targets as a folder of ORIGINALS (011 · A2).
    ///
    /// `nil`-means-absent, the ``onArchiveVerb`` rule: a surface that does not bind
    /// it gets no menu item rather than a dead one. Note this acts on the
    /// RIGHT-CLICK's targets, not the keyboard selection — so a right-click outside
    /// the selection exports the one cell under the cursor, which is what the same
    /// gesture does for every other verb in this menu.
    var onExportAssets: ((_ assetIDs: [UUID]) -> Void)?

    /// The two halves of sharing (011 · A3), paired so a surface cannot bind the
    /// expensive one without the cheap one. `nil` on a surface that does not offer
    /// sharing at all.
    ///
    /// They are split because building the menu and performing the share ask
    /// different questions at wildly different costs — see ``AssetShare`` for the
    /// measurement that forced the split.
    struct ShareHooks {
        /// Cheap: is ANYTHING here shareable? Answered before the menu draws, so it
        /// must not build URLs, stat files or sanitize names.
        var canShareAny: (_ assetIDs: [UUID]) -> Bool
        /// Expensive: the real payload, resolved only once the user picks Share.
        var resolve: (_ assetIDs: [UUID]) -> ExportSelection
    }
    var share: ShareHooks?

    // MARK: 222 — scroll-away header

    /// A header hosted INSIDE the grid's scroll region (222), so it scrolls away
    /// with the content instead of pinning above the grid. `nil` = no header (the
    /// search grid and every prior caller). Rebuilt each body pass like the rest of
    /// the config; the coordinator pushes it onto the live header view on update.
    var header: AnyView?
    /// The header's fixed height in points; must be > 0 whenever `header != nil`.
    /// The layout reserves this band at the top and offsets every item by it.
    var headerHeight: CGFloat = 0

    // MARK: 200 — whole-panel marquee content margins

    /// Content margins folded into the layout (not a SwiftUI `.padding` around the
    /// grid), so the collection view spans the panel edge-to-edge and the marquee
    /// background covers the margins + the empty area below a short grid (200).
    /// Defaulted to zero so the search grid — which keeps its own SwiftUI padding
    /// for now — and every prior caller are unchanged.
    var contentInsets = NSEdgeInsets()
}

/// A handle onto the live grid view, so whoever raised a popover over the grid can
/// give the keyboard back when it closes (024 · K3).
///
/// A popover takes key window; when it goes away AppKit does not necessarily return
/// first responder to the view that was focused before, and a grid that has lost it is
/// deaf to the arrow keys — the exact symptom `SpaceView.restoreCanvasFocus` was
/// written for on the board. The owning view holds one of these in `@State` and the
/// coordinator fills it in; nothing else may write `view`.
@MainActor
final class GridFocusHandle {
    fileprivate weak var view: NSView?

    /// Return first responder to the grid, deferred off the current view update —
    /// `onDisappear` runs inside one, and `makeFirstResponder` republishes focus state.
    func restore() {
        guard let view else { return }
        Task { @MainActor [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

/// The one boundary supplementary kind — the scroll-away Collection header (222).
let masonryHeaderKind = "MasonryHeaderKind"

/// Hosts the SwiftUI Collection header inside the AppKit grid's scroll region (222)
/// as a boundary supplementary view, so it scrolls away with the content. A thin
/// `NSView` wrapper around an `NSHostingView`; the coordinator swaps its `rootView`
/// as the collection name / count change (the diffable data source never re-invokes
/// the supplementary provider for a live content edit).
final class MasonryHeaderContainer: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("MasonryHeaderContainer")
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fall through to the collection view's background `mouseDown` (200), so a
    /// press anywhere on the scroll-away header band starts a marquee / click-to-
    /// clear like the rest of the panel — the whole-panel marquee. Safe as a blanket
    /// `nil` because the header hosts PURELY non-interactive content (title + count;
    /// the New Subfolder button was removed). NSHostingView reports `host` for ANY
    /// point with content — empty OR a control — so identity can't distinguish them;
    /// if an interactive control is ever added back, this must carve out its frame
    /// explicitly rather than return a blanket `nil`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The context-menu vocabulary a grid host offers (048). The collection grid
/// shows the full membership menu; a membership-less surface (search results)
/// can only Add (copy), Reveal a lone byte-backed hit, and Delete — Move / Set
/// Cover / Remove have no meaning without a collection membership to act on.
enum GridMenuStyle {
    case collection
    case looseAssets
    /// The archive shelf (023 · A2): Unarchive and Delete, and nothing else. No
    /// Move / Add / Set Cover / Remove — every one of those needs a membership
    /// the shelf does not have, and an archive you can file into is just another
    /// collection.
    case shelf
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
    /// A responder-chain delete (`deleteBackward:` / `deleteForward:`). AppKit only
    /// sends these for a BARE Delete key — ⌘⌫ maps to `deleteToBeginningOfLine:` and
    /// ⌥⌫ to `deleteWordBackward:`, neither of which we implement — so this is the
    /// REMOVE verb, never the destructive one (022 · D2).
    func gridDeleteCommand()
    /// A responder-chain Copy (⌘C / Edit ▸ Copy, 052 · B1) — copy the selection.
    func gridCopyCommand()
    /// Whether the grid currently has a selection — gates Copy's enabled state.
    var gridHasSelection: Bool { get }
    /// The pointer moved to a window point (or `nil` on exit) — re-hit for hover.
    func gridMouseMoved(toWindowPoint point: CGPoint?)
    /// The clip view scrolled — re-hit hover at the last pointer location so a
    /// scroll under a stationary pointer updates the hovered cell (structurally
    /// fixes hover-during-scroll + the stranded circle; no `hoverAfterWindowChange`).
    func gridClipBoundsChanged()

    // MARK: A3 — background mouse (marquee + click-to-clear) and context menu

    /// A `mouseDown` on EMPTY space (a cell forwards its own image-area down via
    /// ``MasonryGridInteraction`` instead, so this only fires in a gap / inset /
    /// past content) — begins a marquee, or, if it turns out to be a click, clears.
    func gridBackgroundMouseDown(_ event: NSEvent)
    /// A `mouseDragged` after a background down — extends the live marquee box.
    func gridBackgroundMouseDragged(_ event: NSEvent)
    /// A `mouseUp` ending a background gesture — commits the marquee, or clears the
    /// selection on a bare (un-modified) click (the A2-deferred click-to-clear).
    func gridBackgroundMouseUp(_ event: NSEvent)
    /// Build the right-click / Menu-key context menu for `event`, hit-testing its
    /// location against the analytic frames (036 §4 A3 — native `menu(for:)`).
    func gridMenu(for event: NSEvent) -> NSMenu?

    // MARK: A3 — drop reception (NSView-level, not the NSCollectionView delegate)

    /// A same-app asset drag hovering the grid: the drag operation to show
    /// (`.move` over a cell, `[]` over a gap). Handled at the `NSView`
    /// dragging-destination level because `NSCollectionView`'s own
    /// `validateDrop`/`acceptDrop` delegate translation does NOT fire for our
    /// manually-started `beginDraggingSession` (011 — the reorder/move regression).
    func gridDraggingOperation(_ info: NSDraggingInfo) -> NSDragOperation
    /// The drag left the grid without dropping here (040) — tear down any live
    /// reorder preview so the cells slide back to the real order.
    func gridDraggingExited()
    /// A drop landed on the grid: commit the live reorder preview's slot
    /// (same-collection manual reorder; everything else showed no preview and is
    /// refused here).
    func gridPerformDrop(_ info: NSDraggingInfo) -> Bool
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

    // Edit ▸ Copy (⌘C, 052 · B1) — the standard responder action, so the system's
    // unmodified Copy menu item routes to the focused grid (and text fields keep
    // their own Cut/Copy/Paste). `copy(_:)` is not declared by NSView, so it is a
    // fresh `@objc` action, not an override.
    @objc func copy(_ sender: Any?) { events?.gridCopyCommand() }

    // A3 — a down/drag/up that reaches the collection view itself is on EMPTY space
    // (cell views intercept their own; see `FlippedContentView`). Route it to the
    // marquee + click-to-clear. Not calling `super` avoids native selection (off).
    override func mouseDown(with event: NSEvent) { events?.gridBackgroundMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { events?.gridBackgroundMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { events?.gridBackgroundMouseUp(event) }

    /// The native context menu (036 §4 A3) — right-click anywhere over the grid,
    /// resolved to a target cell by the coordinator; `nil` over a true gap so empty
    /// space shows no menu (parity with the SwiftUI container menu).
    override func menu(for event: NSEvent) -> NSMenu? { events?.gridMenu(for: event) }

    // A3 — drop reception at the NSView level (011). `NSCollectionView`'s own
    // `validateDrop`/`acceptDrop` delegate methods do not fire for a drag started
    // via `beginDraggingSession` (bypassing the native item-drag data source), so
    // an intra-app reorder / move silently no-op'd. Overriding the
    // `NSDraggingDestination` methods (registered for `.assetIDs` in `makeScrollView`)
    // handles them ourselves; we intentionally do NOT call `super` (there is no
    // native item drop to run — the grid is manual end to end).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        events?.gridDraggingOperation(sender) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        events?.gridDraggingOperation(sender) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        events?.gridDraggingExited()
    }
    // Always proceed to `performDragOperation` — `NSCollectionView`'s own
    // `prepareForDragOperation` (geared to native item drops we don't use) could
    // otherwise refuse and swallow the drop.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        events?.gridPerformDrop(sender) ?? false
    }
}

extension MasonryNSCollectionView: NSUserInterfaceValidations {
    /// Enable Edit ▸ Copy only when the grid has a selection (052 · B1); other
    /// actions this view vends stay enabled. Used in place of `validateMenuItem`
    /// so no NSView ObjC override is needed.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return events?.gridHasSelection ?? false }
        return true
    }
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
    NSCollectionViewDelegate, NSDraggingSource,
    MasonryGridInteraction, MasonryGridViewEvents {
    private var configuration: GridHostConfiguration
    private let layout = MasonryCollectionLayout()

    private var scrollView: NSScrollView?
    private var collectionView: MasonryNSCollectionView?
    private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>?
    /// The live scroll-away header view (222), retained weakly so its SwiftUI
    /// `rootView` can be refreshed on `update` (the diffable data source does not
    /// re-invoke the supplementary provider for an in-place content edit).
    private weak var headerContainer: MasonryHeaderContainer?

    /// The AppKit marquee (036 §4 A3): background rubber-band + edge auto-scroll +
    /// click-to-clear, drawing ONE `CALayer` and mutating only changed cells per
    /// tick. Created once the collection view exists.
    private var marquee: GridMarqueeController?

    /// The rendered item set, index-aligned to the snapshot order.
    private(set) var items: [CollectionItemDetail] = []
    /// Membership id → row, kept for the A2 coordinator's selection reconciliation
    /// (and unit-tested via ``gridIDToIndex(for:)``).
    private(set) var idToIndex: [UUID: Int] = [:]

    /// Where the last context menu was raised, in CONTENT space — the share sheet's
    /// anchor (011 · A3). The sheet is presented from a menu action, long after the
    /// `NSEvent` that carried the location has gone.
    private var lastMenuPoint: CGPoint?
    /// The share sheet's picker, held while the sheet is up: `NSSharingServicePicker`
    /// does not retain itself when shown, so a local would die on return.
    private var sharePicker: NSSharingServicePicker?

    /// The feed bucketed by post (307 · carousel grouping), mirrored from the
    /// configuration on every `applyItems`. Feeds the per-cell carousel chip. The
    /// model builds it; the host never does.
    private(set) var postGroups = PostGroups()

    /// The `$selection` subscription driving layer-only reconciliation (A2).
    private var selectionCancellable: AnyCancellable?
    /// The selection the visible cells currently reflect — diffed against each new
    /// value so ``reconcileSelection(to:)`` touches only the CHANGED cells.
    private var reflectedSelection = GridSelection()
    /// The membership id under the pointer, if any (A2 hover). The circle shows on
    /// this cell while idle; driven by the one tracking area, re-hit on scroll.
    private var hoveredID: UUID?

    /// Whether the in-flight drag session carries file promises (011 · Cluster A).
    /// Read by ``draggingSession(_:sourceOperationMaskFor:)`` to allow an external
    /// `.copy` (drag-out) only when there are byte-backed assets to export; a
    /// media-less-only drag stays internal (reorder / move) exactly as before.
    private var draggingHasFilePromise = false

    /// The live reorder drop preview (040) while an eligible same-collection drag
    /// hovers the grid: the dragged block and the insertion slot it currently
    /// previews. `nil` in the steady state. Drives `layout.preview`; the ghost
    /// (dimmed block) is ``ghostBlockIDs``.
    private struct ReorderPreviewState {
        var payload: AssetDragPayload
        /// The dragged block's DATA indices into `items`, feed (ascending) order.
        var blockIndices: [Int]
        /// The insertion slot in the block-removed order (`0...remaining.count`).
        var slot: Int
        /// The point the current slot was computed at — the hysteresis anchor.
        var lastSlotPoint: CGPoint
    }
    private var reorderPreview: ReorderPreviewState?
    /// The membership ids of the dragged block, dimmed as the ghost while a
    /// preview is active. Re-applied in ``configure(_:at:)`` so a cell scrolled in
    /// mid-drag dims correctly. Empty in the steady state.
    private var ghostBlockIDs: Set<UUID> = []
    /// Set the instant a grid drop commits: the model republish that follows
    /// clears the preview in ``update(configuration:)`` (frame-identical to the
    /// preview — 040 decision 7), so the drag-end / exit nets must NOT also clear
    /// it and cause a snap-back.
    private var awaitingReorderCommit = false
    /// The ghost's dimmed opacity while dragging (040).
    private static let ghostAlpha: CGFloat = 0.35
    /// The reflow slide duration when the insertion slot changes (040 decision 8).
    private static let reorderAnimationDuration: TimeInterval = 0.18

    init(configuration: GridHostConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: Construction

    func makeScrollView() -> NSScrollView {
        layout.density = configuration.density
        layout.spacing = configuration.spacing
        layout.topInset = configuration.topInset
        layout.headerHeight = configuration.headerHeight
        layout.contentInsets = configuration.contentInsets

        let collectionView = MasonryNSCollectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Native selection bypassed entirely (036 §2 A1) — and A1 is read-only.
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.wantsLayer = true
        collectionView.collectionViewLayout = layout
        collectionView.register(
            MasonryGridItem.self, forItemWithIdentifier: MasonryGridItem.identifier)
        // The scroll-away header supplementary (222) — only ever materialized when
        // `headerHeight > 0` (the collection grid); search leaves it unregistered-but-
        // harmless since the layout emits no header attributes there.
        collectionView.register(
            MasonryHeaderContainer.self,
            forSupplementaryViewOfKind: masonryHeaderKind,
            withIdentifier: MasonryHeaderContainer.identifier)
        collectionView.prefetchDataSource = self
        collectionView.delegate = self
        // Register ONLY the intra-app asset-ids type (036 §4 A3): an external
        // file/image/URL drag is NOT a registered type here, so the collection view
        // is transparent to it and it falls through to the pane-level SwiftUI
        // `.onDrop` (import). Only a same-app reorder drag is accepted onto a cell.
        collectionView.registerForDraggedTypes([AssetDragPayload.pasteboardType])
        // A2 — keyboard + hover forwarding (cell mouse-down arrives via the cell).
        collectionView.events = self
        // K3 — hand the owning view a way back to this responder after it raises a
        // popover over the grid. Written here, and again on `update`, so a config
        // rebuilt with a fresh handle still finds the live view.
        configuration.focusHandle?.view = collectionView

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
        // Supply + retain the scroll-away header (222). The provider fires when the
        // header first materializes; `update` refreshes its content thereafter.
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == masonryHeaderKind,
                  let container = collectionView.makeSupplementaryView(
                    ofKind: kind, withIdentifier: MasonryHeaderContainer.identifier,
                    for: indexPath) as? MasonryHeaderContainer
            else { return nil }
            container.host.rootView = self?.configuration.header ?? AnyView(EmptyView())
            self?.headerContainer = container
            return container
        }
        collectionView.dataSource = dataSource

        self.scrollView = scrollView
        self.collectionView = collectionView
        self.dataSource = dataSource

        makeMarqueeController(on: collectionView)
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

    /// Build the AppKit marquee (036 §4 A3) and wire its callbacks to the store /
    /// layout, so a background rubber-band applies `.marquee`/`.clear` through the
    /// SAME reducer seam the SwiftUI `MarqueeCaptureLayer` used, and its hit-test
    /// reads the ANALYTIC frames (never live cell frames — the pixel-snap asterisk).
    private func makeMarqueeController(on collectionView: MasonryNSCollectionView) {
        let controller = GridMarqueeController(collectionView: collectionView)
        controller.itemIDs = { [weak self] in self?.items.map { $0.item.id } ?? [] }
        controller.frames = { [weak self] in self?.layout.solvedFrames ?? [] }
        controller.columns = { [weak self] in self?.layout.solvedColumns ?? 1 }
        controller.currentSelectionIDs = { [weak self] in
            self?.configuration.selectionStore.selection.ids ?? []
        }
        controller.onMarquee = { [weak self] hits, base in
            guard let self else { return }
            self.execute(self.configuration.selectionStore.apply(
                .marquee(hits: hits, base: base), columns: self.currentColumns()))
        }
        controller.onClear = { [weak self] in
            guard let self else { return }
            self.execute(self.configuration.selectionStore.apply(
                .clear, columns: self.currentColumns()))
        }
        marquee = controller
    }

    func tearDown() {
        selectionCancellable = nil
        marquee?.cancel()
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
        configuration.focusHandle?.view = collectionView
        layout.density = configuration.density
        layout.spacing = configuration.spacing
        layout.topInset = configuration.topInset

        // Refresh the scroll-away header (222): push the latest SwiftUI content onto
        // the live view (name / count edits never re-invoke the supplementary
        // provider), and re-solve if the reserved band changed height.
        headerContainer?.host.rootView = configuration.header ?? AnyView(EmptyView())
        if layout.headerHeight != configuration.headerHeight
            || !NSEdgeInsetsEqual(layout.contentInsets, configuration.contentInsets) {
            layout.headerHeight = configuration.headerHeight
            layout.contentInsets = configuration.contentInsets
            layout.invalidateLayout()
        }

        let collectionChanged = old.collectionID != configuration.collectionID
        let versionChanged = old.itemsVersion != configuration.itemsVersion
        let dataChanged = collectionChanged || versionChanged
            || items.count != configuration.items.count

        // A live reorder preview (040) is torn down the moment the data changes
        // under it: a commit landing (the new order's real solve reproduces the
        // preview frame-for-frame, so clearing here is jump-free — decision 7), or
        // any mid-drag reload / collection switch. A cosmetic rebuild at an
        // unchanged version leaves the preview alone (else it would flicker away
        // on every unrelated body re-eval mid-hover). Cleared BEFORE `applyItems`
        // re-solves, and never animated (the reflow already happened, or is a
        // reset). `applyGhostDimming([])` restores any dimmed cell's alpha.
        if reorderPreview != nil, dataChanged {
            reorderPreview = nil
            awaitingReorderCommit = false
            setLayoutPreview(nil, animated: false)
            applyGhostDimming(ids: [])
        }

        if dataChanged {
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

    /// The viewport pinned to an item, not an offset: the topmost visible item's
    /// id, its analytic top, and the scroll offset at capture. Finer than the
    /// density path's `restoreTopIndex` (which SNAPS its index to the viewport
    /// top): restoring by delta keeps a partially-scrolled anchor exactly where it
    /// was on screen, so an expand/collapse moves nothing above the toggled post.
    private struct GridScrollAnchor {
        let id: UUID
        let frameMinY: CGFloat
        let offsetY: CGFloat
    }

    /// Read BEFORE the item set / layout mutate — old items, old frames.
    private func captureScrollAnchor() -> GridScrollAnchor? {
        guard let scrollView, let index = topmostVisibleIndex(),
              items.indices.contains(index),
              let frame = layout.analyticFrame(at: index) else { return nil }
        return GridScrollAnchor(
            id: items[index].item.id, frameMinY: frame.minY,
            offsetY: scrollView.contentView.bounds.minY)
    }

    /// Re-pin the viewport after the new snapshot laid out: scroll by however far
    /// the anchor item's frame moved, clamped to the new content. An anchor that
    /// left the feed (it was an open post's member and the post closed) falls back
    /// to its post's lead — the tile now standing where the run stood.
    private func restoreScrollAnchor(_ anchor: GridScrollAnchor?) {
        guard let anchor, let scrollView, let collectionView else { return }
        collectionView.layoutSubtreeIfNeeded()
        let index = idToIndex[anchor.id]
            ?? postGroups.members(forItem: anchor.id).lazy.compactMap { self.idToIndex[$0] }.first
        guard let index, let frame = layout.analyticFrame(at: index) else { return }
        let clipView = scrollView.contentView
        let maxOffset = max(0, collectionView.frame.height - clipView.bounds.height)
        let target = min(max(0, anchor.offsetY + frame.minY - anchor.frameMinY), maxOffset)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Apply a new item set. Same-id, same-order republishes reconfigure in place
    /// (a content edit); anything else applies a fresh snapshot. `resetScroll`
    /// returns to the top on a collection switch; any other id change (an
    /// expand/collapse, a delete) keeps the viewport anchored instead — the reflow
    /// is instant, so an unanchored offset visibly slides the grid under a
    /// stationary cursor whenever the content height shrinks and clamps.
    private func applyItems(_ newItems: [CollectionItemDetail], resetScroll: Bool) {
        let oldIDs = gridSnapshotIDs(for: items)
        let newIDs = gridSnapshotIDs(for: newItems)
        // Captured BEFORE any mutation — the anchor reads the OLD items + frames.
        let anchor = resetScroll ? nil : captureScrollAnchor()

        items = newItems
        idToIndex = gridIDToIndex(for: newItems)
        // Mirror the model's index BEFORE any cell configures — the chip count reads
        // it. Built by the owning model, not here: an identical rebuild in both
        // places was two sources of truth for one derivation.
        postGroups = configuration.postGroups
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
            if resetScroll {
                scrollToTop()
            } else {
                restoreScrollAnchor(anchor)
            }
            // A diffable apply re-vends only the INSERTED index paths; a cell that
            // survived the change keeps whatever it was last configured with. Across
            // an expand/collapse that means the lead would keep its old fan/chip
            // state (and so a stale chip hit rect) — reconfigure the visible cells
            // so what is drawn, and what hit-tests, is the NEW state.
            reconfigureVisibleItems()
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
        // GIF hover-preview (A3) animates from the ORIGINAL bytes, and only for the
        // GIF mime — mirrors the SwiftUI cell's `gifURL` gate exactly.
        let gifURL = detail.asset.mimeType == GifMotion.gifMimeType
            ? configuration.blobURL(detail) : nil
        // The post this cell belongs to, resolved once: its lead is both the id the
        // expansion set is keyed on and (309) the only member that draws a chip
        // while the post is open.
        let lead = postGroups.members(forItem: detail.item.id).first ?? detail.item.id
        cell.configure(
            detail: detail,
            url: configuration.thumbnailURL(detail),
            bucket: bucket(at: index),
            gifURL: gifURL,
            postMemberCount: postGroups.memberCount(forItem: detail.item.id),
            postExpanded: configuration.expandedPosts.contains(lead),
            isPostLead: lead == detail.item.id)
        // Paint the cell's CURRENT selection + hover, so a freshly materialized or
        // reconfigured cell (scroll-in, snapshot, density step) shows the right
        // rings/circle without waiting for a reconcile tick — this is also how a
        // cell scrolled off mid-change, or a lead that wasn't visible, repaints
        // correctly when it next comes on screen (036 §4 A2).
        let selection = configuration.selectionStore.selection
        cell.applySelectionState(cellSelectionState(for: detail.item.id, selection: selection))
        cell.setHovered(hoveredID == detail.item.id)
        // Ghost dimming while a reorder preview is active (040): a cell scrolled in
        // mid-drag must show the dimmed state, and a normal (re)configure must not
        // leave a stale alpha behind once the preview cleared.
        cell.view.alphaValue = ghostBlockIDs.contains(detail.item.id) ? Self.ghostAlpha : 1
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
        guard let size = scrollView?.contentSize, size.width > 0 else { return }
        // A WIDTH change re-solves the masonry (the real cost). A HEIGHT change only
        // needs `collectionViewContentSize` re-read so the short-grid viewport floor
        // (200) tracks the new viewport — `prepare()`'s masonry solve is a memo hit
        // when the width held, so this stays cheap. Height alone never moves
        // `preparedWidth`, so `shouldInvalidateLayout` would otherwise miss it.
        if abs(size.width - layout.preparedWidth) > 0.5
            || abs(size.height - layout.preparedViewportHeight) > 0.5 {
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
        let visible = visibleItemIDs()
        let delta = selectionCellDelta(from: old, to: newValue)
        let targets = selectionReconcileTargets(delta: delta, visibleIDs: visible)
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

    /// A press on a cell. WHICH cell is the LAYOUT's answer, not AppKit's: the view
    /// hit-test resolves against a subview tree that the reflow of a previous click
    /// may have already permuted, and it will hand the press to a recycled cell that
    /// has since moved elsewhere — measured in 311 as a press over the lead tile
    /// arriving at a cell 200pt away, which then opened ITS item. `hitTestIndex`
    /// rides the analytic frames (038 §3.4), which are what actually got drawn, so
    /// it answers with the tile the user aimed at.
    func gridCellMouseDown(event: NSEvent) {
        let point = contentPoint(for: event)
        guard let index = layout.hitTestIndex(at: point), items.indices.contains(index)
        else { return }
        let id = items[index].item.id
        // Focus follows the click, so keyboard nav works afterwards.
        collectionView?.window?.makeFirstResponder(collectionView)

        // The chip's zone is resolved and handled FIRST, and never falls through:
        // `.tapImage` with an empty selection always returns `.openDetail`, so a
        // chip-zone press that missed had no neutral outcome — it opened something.
        // Now a chip-bearing tile either toggles or does nothing.
        if badgeZoneHit(at: point, index: index, id: id) {
            // Deliberately does NOT touch the selection: opening a post is a
            // different intent from picking it, and a triage in progress must
            // survive a look inside a carousel.
            configuration.onToggleExpand(id)
            // Swallow the matching release. Left unconsumed it bubbles to the
            // collection view's BACKGROUND mouse-up (a cell overrides `mouseDown`
            // but not `mouseUp`) and reads as a click on empty space — which
            // clears the selection this path just promised to leave alone.
            consumeRelease()
            return
        }

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
            // A3: begin the `NSDraggingSource` session from the classified drag.
            beginDragHandoff(id: id, downEvent: downEvent)
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

    /// Start the `NSDraggingSource` session for a drag classified above (036 §4 A3 +
    /// 011 · Cluster A drag-out). Two things ride the session:
    ///
    /// - **Internal payload** — the JSON-encoded `AssetDragPayload` under the
    ///   `.assetIDs` type, byte-compatible with the SwiftUI `.draggable`, so the
    ///   sidebar rows / Spaces accept an intra-app drop unchanged.
    /// - **External file promises** — one `AssetFilePromiseProvider` per byte-backed
    ///   asset (via ``gridExportPlan(assetIDs:details:blobURL:)``), so dropping OUT
    ///   to Finder / Figma writes the original file with a human name. The PRIMARY
    ///   provider also carries the `.assetIDs` payload (2A), so one session serves
    ///   both. A media-less-only drag has no promises and keeps the internal-only
    ///   `NSPasteboardItem` path.
    ///
    /// A selected cell drags the whole selection (via `dragPayload`); the drag image
    /// is the existing `dragPreview`, on the primary item only (14A).
    private func beginDragHandoff(id: UUID, downEvent: NSEvent) {
        guard let collectionView, let index = idToIndex[id],
              items.indices.contains(index) else { return }
        let detail = items[index]
        let payload = configuration.dragPayload(id)
            ?? AssetDragPayload(
                assetIDs: [detail.asset.id], sourceCollectionID: configuration.collectionID)
        guard let payloadData = try? payload.pasteboardData() else { return }

        let plan = gridExportPlan(
            assetIDs: payload.assetIDs, details: items, blobURL: configuration.blobURL)
        draggingHasFilePromise = !plan.isEmpty

        let draggingItems: [NSDraggingItem]
        if plan.isEmpty {
            // Media-less selection — internal reorder / move only (prior behaviour).
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(payloadData, forType: AssetDragPayload.pasteboardType)
            draggingItems = [NSDraggingItem(pasteboardWriter: pasteboardItem)]
        } else {
            // One file promise per byte-backed asset, in grid order; the primary
            // provider also vends the internal `.assetIDs` payload.
            draggingItems = plan.enumerated().map { offset, export in
                let provider = AssetFilePromiseProvider(
                    fileType: export.utType.identifier, delegate: AssetFilePromiseDelegate.shared)
                provider.exportItem = export
                if offset == 0 { provider.assetPayloadData = payloadData }
                return NSDraggingItem(pasteboardWriter: provider)
            }
        }

        // One drag image (the count-badged preview) on the primary item, centred on
        // the pointer in the flipped content space (the classic coordinate-bug spot,
        // 036 §A-risks; a small offset is cosmetic). Extra promise items stack
        // invisibly under it (14A).
        let image = configuration.dragImage(id)
        let size = image?.size ?? CGSize(width: 84, height: 84)
        let point = contentPoint(for: downEvent)
        let frame = CGRect(
            x: point.x - size.width / 2, y: point.y - size.height / 2,
            width: size.width, height: size.height)
        draggingItems.first?.setDraggingFrame(frame, contents: image)
        for extra in draggingItems.dropFirst() { extra.setDraggingFrame(frame, contents: nil) }

        collectionView.beginDraggingSession(
            with: draggingItems, event: downEvent, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            // Move or copy (⌥) within the window — reorder / cross-collection move.
            return [.move, .copy]
        case .outsideApplication:
            // Drag-out (011 · Cluster A): copy the original file(s) to the external
            // destination, but ONLY when the drag actually carries file promises.
            return draggingHasFilePromise ? .copy : []
        @unknown default:
            return []
        }
    }

    /// The drag session ended (040 safety net): drop the file-promise flag and
    /// tear down any stale preview left by a drag that ended WITHOUT a grid commit
    /// (dropped on a sidebar row / outside / cancelled). A committed grid drop
    /// clears via `update(configuration:)`, so it is skipped here.
    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        draggingHasFilePromise = false
        if !awaitingReorderCommit { clearReorderPreview(animated: false) }
    }

    func gridCellCircleClicked(id: UUID) {
        collectionView?.window?.makeFirstResponder(collectionView)
        execute(configuration.selectionStore.apply(.tapCircle(id), columns: currentColumns()))
    }

    /// Whether `point` (content space) is in the carousel chip's zone of the tile at
    /// `index` — resolved from the tile's ANALYTIC frame and the model's grouping
    /// state, never from the cell's live `CALayer` (which a recycled cell answers
    /// wrongly, 311).
    private func badgeZoneHit(at point: CGPoint, index: Int, id: UUID) -> Bool {
        guard let frame = layout.analyticFrame(at: index) else { return false }
        let lead = postGroups.members(forItem: id).first ?? id
        return gridBadgeZoneHit(
            point: point, tileFrame: frame,
            memberCount: postGroups.memberCount(forItem: id),
            isExpanded: configuration.expandedPosts.contains(lead),
            isLead: lead == id)
    }

    /// Pump events until this gesture's `.leftMouseUp` arrives and drop it (and any
    /// sub-threshold drags) on the floor — the chip has no drag behaviour. The same
    /// `nextEvent` idiom as ``trackDragThreshold(from:)``, which is how the ordinary
    /// tile path already consumes its release.
    private func consumeRelease() {
        guard let window = collectionView?.window else { return }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { return }
        }
    }

    // MARK: Coordinate conversion (036 §A-risks — the ONE helper)

    /// The single event → content-space conversion used by click / hover / marquee /
    /// menu / drag (036 §A-risks). `NSCollectionView` is flipped and IS the document
    /// view, so its coordinate space is the analytic content space (top inset
    /// included, `MasonryLayout`'s own space). A click inside the `topInset` or PAST
    /// the content bottom converts fine and hit-tests to no cell — the caller then
    /// treats it as empty space (a marquee / a clear), never a crash or a mis-hit.
    func contentPoint(for event: NSEvent) -> CGPoint {
        guard let collectionView else { return .zero }
        return collectionView.convert(event.locationInWindow, from: nil)
    }

    // MARK: Background mouse — marquee + click-to-clear (036 §4 A3)

    func gridBackgroundMouseDown(_ event: NSEvent) {
        // Focus the grid so keyboard nav works after a background click, matching a
        // cell click (A2). Then hand the down to the marquee controller.
        collectionView?.window?.makeFirstResponder(collectionView)
        marquee?.mouseDown(
            at: contentPoint(for: event), shiftKey: event.modifierFlags.contains(.shift))
    }

    func gridBackgroundMouseDragged(_ event: NSEvent) {
        marquee?.mouseDragged(to: contentPoint(for: event))
    }

    func gridBackgroundMouseUp(_ event: NSEvent) {
        marquee?.mouseUp()
    }

    // MARK: Context menu (036 §4 A3 — native NSMenu, hit-tested target)

    func gridMenu(for event: NSEvent) -> NSMenu? {
        // Resolve the target cell from the cursor over the ANALYTIC frames (the same
        // query the marquee / C4 container menu ran). A gap → nil (no menu), parity
        // with right-clicking empty space. A non-pointer invocation (Menu key, no
        // location) falls back to the keyboard cursor (`lead`) cell, per 036 §4 C4.
        let point = contentPoint(for: event)
        // Kept for the share sheet's anchor (011 · A3): the sheet is raised later,
        // from a menu action, by which time the event is long gone.
        lastMenuPoint = point
        var index = layout.hitTestIndex(at: point)
        if index == nil {
            let isPointer = event.type == .rightMouseDown || event.type == .leftMouseDown
            if !isPointer, let lead = configuration.selectionStore.selection.lead {
                index = idToIndex[lead]
            }
        }
        guard let index, items.indices.contains(index) else { return nil }
        return buildContextMenu(forCellItemID: items[index].item.id)
    }

    /// The cell menu (009 · N2/N6 · C4 scope) as a native `NSMenu`: Move to ▸ /
    /// Add to ▸ (the whole collection hierarchy as NESTED submenus, 027 · G2), Set
    /// as Cover (single only), Remove, Delete — counts in the destructive verbs.
    /// Actions run on the Finder-scope asset set from `actionTargets` (selection
    /// when the cell is in the selection, else the one cell), exactly as the
    /// SwiftUI `cellMenu` did.
    private func buildContextMenu(forCellItemID itemID: UUID) -> NSMenu {
        let targets = configuration.actionTargets(itemID)   // asset ids
        let n = targets.count
        let menu = NSMenu()

        switch configuration.menuStyle {
        case .collection:
            let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            moveItem.submenu = destinationSubmenu(verb: .move) { [weak self] target in
                self?.configuration.onMoveToCollection(targets, target)
            }
            menu.addItem(moveItem)

            let addItem = NSMenuItem(title: "Add to", action: nil, keyEquivalent: "")
            addItem.submenu = destinationSubmenu(verb: .add) { [weak self] target in
                self?.configuration.onCopyToCollection(targets, target)
            }
            menu.addItem(addItem)

            if n == 1 {
                menu.addItem(BlockMenuItem(title: "Set as Cover") { [weak self] in
                    self?.configuration.onSetCover(targets[0])
                })
            }
            addOutFlowItems(to: menu, targets: targets)
            menu.addItem(.separator())
            addArchiveItem(to: menu, targets: targets)
            menu.addItem(BlockMenuItem(
                title: "Remove from Collection\(Self.countSuffix(n))"
            ) { [weak self] in
                self?.configuration.onRemoveFromCollection(targets)
            })
            menu.addItem(BlockMenuItem(title: "Delete\(Self.countSuffix(n))") { [weak self] in
                self?.configuration.onDelete(targets)
            })

        case .looseAssets:
            // Membership-less hits (search): Add (copy), Reveal a lone byte-backed
            // hit, Delete. No Move / Set Cover / Remove — there's no membership.
            let addItem = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
            // 027 · G3 — the same nested tree as the collection grid. Search has no
            // current collection, so nothing is greyed.
            addItem.submenu = destinationSubmenu(verb: .add) { [weak self] target in
                self?.configuration.onCopyToCollection(targets, target)
            }
            menu.addItem(addItem)

            if n == 1, let idx = idToIndex[itemID], items.indices.contains(idx),
               configuration.blobURL(items[idx]) != nil {
                menu.addItem(BlockMenuItem(title: "Reveal in Finder") { [weak self] in
                    self?.configuration.onReveal(itemID)
                })
            }
            addOutFlowItems(to: menu, targets: targets)
            menu.addItem(.separator())
            addArchiveItem(to: menu, targets: targets)
            menu.addItem(BlockMenuItem(title: "Delete\(Self.countSuffix(n))") { [weak self] in
                self?.configuration.onDelete(targets)
            })

        case .shelf:
            // Unarchive is the shelf's ONE verb, and it reads first because it
            // is the reason anyone opens this pane. Delete stays because leaving
            // the library means the same thing from every surface (022 · D5) —
            // and it is the recoverable delete, with the same ⌘Z.
            // Titled by `ShelfVerb`, not by a second string built here: the
            // shelf is all-archived by construction, so the verb resolves to
            // unarchive and its title counts the way every other verb does.
            if let verb = shelfVerb(targets: targets, archived: Set(targets)) {
                menu.addItem(BlockMenuItem(title: verb.title) { [weak self] in
                    self?.configuration.onUnarchive(targets)
                })
            }

            if n == 1, let idx = idToIndex[itemID], items.indices.contains(idx),
               configuration.blobURL(items[idx]) != nil {
                menu.addItem(BlockMenuItem(title: "Reveal in Finder") { [weak self] in
                    self?.configuration.onReveal(itemID)
                })
            }
            menu.addItem(.separator())
            menu.addItem(BlockMenuItem(title: "Delete\(Self.countSuffix(n))") { [weak self] in
                self?.configuration.onDelete(targets)
            })
        }
        return menu
    }

    /// A Move-to / Add-to submenu: the whole collection hierarchy NESTED (027 · G2),
    /// in the same order the SwiftUI ``CollectionDestinationList`` indents — both
    /// come from ``CollectionTargets/destinationTree``. Built here, on the
    /// right-click, rather than per visible cell.
    private func destinationSubmenu(
        verb: CollectionDestinationMenu.Verb, action: @escaping @MainActor (UUID) -> Void
    ) -> NSMenu {
        CollectionDestinationMenu.menu(
            CollectionDestinationMenu.items(
                tree: configuration.destinationTree,
                unsortedID: configuration.destinationUnsortedID,
                disabled: configuration.disabledDestinations, verb: verb),
            action: action)
    }

    /// " (N)" for a multi-item action, empty for a single — mirrors
    /// `CollectionView.countSuffix`.
    private static func countSuffix(_ n: Int) -> String { n > 1 ? " (\(n))" : "" }

    /// The out-flow pair — `Share ▸` and `Export Assets…` (011 · A2/A3) — for a
    /// BROWSING menu, each added only when the surface binds it and only when the
    /// targets have something to give.
    ///
    /// They sit together, behind their own separator, because they are the one
    /// group in this menu that sends refs OUT of the app rather than moving them
    /// around inside it — and ahead of the destructive verbs, so the click that
    /// reaches for Share cannot land near Delete.
    ///
    /// The archive shelf deliberately gets neither. Its menu is three verbs on
    /// purpose (022 · D5 / 023 · A2): the shelf is where refs go to be out of the
    /// way, and a share sheet is not what "put this away" asks for.
    /// Transcribes ``outFlowMenuRows(canShare:canExport:targetCount:)`` — which owns
    /// the decision, and is unit-tested — into `NSMenuItem`s.
    ///
    /// Nothing expensive happens here. The Share row is decided by the CHEAP
    /// predicate and its payload is resolved in ``presentSharePicker(targets:)``,
    /// on the click — see ``AssetShare`` for the 77 ms this arrangement removes from
    /// a 1,000-ref right-click.
    private func addOutFlowItems(to menu: NSMenu, targets: [UUID]) {
        let canShare = configuration.share?.canShareAny(targets) ?? false
        let export = configuration.onExportAssets

        for row in outFlowMenuRows(
            canShare: canShare, canExport: export != nil, targetCount: targets.count
        ) {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .share:
                menu.addItem(BlockMenuItem(title: "Share…") { [weak self] in
                    self?.presentSharePicker(targets: targets)
                })
            case .exportAssets(let title):
                if let export {
                    menu.addItem(BlockMenuItem(title: title) { export(targets) })
                }
            }
        }
    }

    /// Resolve the share payload and put the system sheet up, anchored where the
    /// right-click landed.
    ///
    /// A click-to-sheet rather than an inline `Share ▸` submenu: the system submenu
    /// comes from `NSSharingServicePicker.standardShareMenuItem`, which needs its
    /// items AT INIT — so an inline submenu cannot be lazy without moving menu items
    /// between menus behind the picker's back. The sheet keeps the deferral simple
    /// and honest, and it is the same system UI either way.
    ///
    /// The picker is held in `sharePicker` for the sheet's lifetime: the class does
    /// not retain itself while shown, and a locally-scoped one would be released the
    /// moment this function returned.
    private func presentSharePicker(targets: [UUID]) {
        guard let hooks = configuration.share, let view = collectionView else { return }
        // THE expensive call, now on an explicit user action rather than on the
        // right-click that merely opened the menu.
        guard let picker = AssetShare.picker(for: hooks.resolve(targets)) else { return }
        sharePicker = picker
        let anchor = lastMenuPoint.map { CGRect(origin: $0, size: CGSize(width: 1, height: 1)) }
            ?? CGRect(origin: view.visibleRect.origin, size: CGSize(width: 1, height: 1))
        picker.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    /// The Archive item for a BROWSING menu (collection / loose assets), added
    /// only when the surface binds the verb. Nothing a browsing surface can show
    /// is archived (023 · A1), so the verb always resolves to Archive here —
    /// asked through ``shelfVerb(targets:archived:)`` anyway rather than
    /// hard-coded, so the title and the count come from the one place that
    /// decides them.
    private func addArchiveItem(to menu: NSMenu, targets: [UUID]) {
        guard configuration.onArchiveVerb != nil,
              let verb = shelfVerb(targets: targets, archived: [])
        else { return }
        menu.addItem(BlockMenuItem(title: verb.title) { [weak self] in
            self?.configuration.onArchive(targets)
        })
    }

    // MARK: Drop onto a cell (036 §4 A3 · 011 — NSView-level reception)

    /// Validate a same-app asset drag hovering the grid (from
    /// ``MasonryNSCollectionView/draggingEntered(_:)``/`draggingUpdated`). An
    /// ELIGIBLE reorder (same-collection, manual sort, the block resolves to
    /// current rows) drives the live preview to the pointer's insertion slot and
    /// returns `.move`; anything else clears any preview and returns `[]` — so the
    /// cursor never promises a reorder that would then be refused (040). A
    /// non-`.assetIDs` drag never reaches here (the grid only registers that type;
    /// an external file/URL drag falls through to the pane-level import `.onDrop`).
    func gridDraggingOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let collectionView, configuration.canReorder,
              let payload = reorderPayload(from: info),
              payload.sourceCollectionID == configuration.collectionID,
              let block = reorderBlockIndices(for: payload) else {
            clearReorderPreview(animated: true)
            return []
        }
        let point = collectionView.convert(info.draggingLocation, from: nil)
        updateReorderPreview(payload: payload, blockIndices: block, at: point)
        return .move
    }

    /// The drag left the grid without dropping here (040): slide the cells back to
    /// the real order. Skipped while a grid commit is pending (the drop already
    /// landed here — `update(configuration:)` will clear the preview instead).
    func gridDraggingExited() {
        guard !awaitingReorderCommit else { return }
        clearReorderPreview(animated: true)
    }

    /// Accept a drop: commit the live preview's slot (040). Keeps the preview in
    /// place and marks the commit pending, so the model republish clears it in
    /// `update(configuration:)` frame-identically (no jump — decision 7); a
    /// refused commit clears immediately. No active preview → nothing to commit.
    func gridPerformDrop(_ info: NSDraggingInfo) -> Bool {
        guard let state = reorderPreview else { return false }
        awaitingReorderCommit = true
        let accepted = configuration.onReorderCommit(state.payload, state.slot)
        if !accepted { clearReorderPreview(animated: false) }
        return accepted
    }

    // MARK: Live reorder preview (040)

    /// Decode the `.assetIDs` payload off the drag pasteboard (the ONE reliable
    /// read for an AppKit promise drag — the bridged provider registers nothing).
    private func reorderPayload(from info: NSDraggingInfo) -> AssetDragPayload? {
        guard let data = info.draggingPasteboard.data(
            forType: AssetDragPayload.pasteboardType) else { return nil }
        return AssetDragPayload.decode(from: data)
    }

    /// The dragged block's DATA indices into `items`, in feed (ascending) order —
    /// `nil` if the payload is empty or no id is a current row (a foreign drop).
    private func reorderBlockIndices(for payload: AssetDragPayload) -> [Int]? {
        let ids = Set(payload.assetIDs)
        guard !ids.isEmpty else { return nil }
        let indices = items.indices.filter { ids.contains(items[$0].asset.id) }
        return indices.isEmpty ? nil : Array(indices)
    }

    /// Establish or re-slot the preview for a hovering block. First entry seeds it
    /// at the pointer's slot; later ticks re-slot only past the hysteresis
    /// threshold and re-solve+animate only when the slot actually changes.
    private func updateReorderPreview(
        payload: AssetDragPayload, blockIndices: [Int], at point: CGPoint
    ) {
        if var state = reorderPreview {
            guard masonryShouldReslot(from: state.lastSlotPoint, to: point) else { return }
            let newSlot = reorderSlot(at: point, blockIndices: blockIndices, currentSlot: state.slot)
            let changed = newSlot != state.slot
            state.slot = newSlot
            state.blockIndices = blockIndices
            state.payload = payload
            state.lastSlotPoint = point
            reorderPreview = state
            if changed { applyReorderPreview(animated: true) }
        } else {
            let slot = reorderSlot(at: point, blockIndices: blockIndices, currentSlot: nil)
            reorderPreview = ReorderPreviewState(
                payload: payload, blockIndices: blockIndices, slot: slot, lastSlotPoint: point)
            applyReorderPreview(animated: true)
        }
    }

    /// The insertion slot for `point`, hit-tested against the CURRENTLY displayed
    /// frames (the preview when one is active — `layout.solvedFrames` reflects it),
    /// under the display order the current slot implies (identity on first entry).
    private func reorderSlot(at point: CGPoint, blockIndices: [Int], currentSlot: Int?) -> Int {
        let count = items.count
        let order = currentSlot.map {
            previewDisplayOrder(count: count, blockIndices: blockIndices, slot: $0)
        } ?? Array(0..<count)
        return masonryInsertionSlot(
            at: point, framesByDataIndex: layout.solvedFrames,
            displayOrder: order, blockIndices: blockIndices)
    }

    /// Re-solve the permuted arrangement for the current slot and push it onto the
    /// layout (animated when the slot changed), plus the ghost dimming.
    private func applyReorderPreview(animated: Bool) {
        guard let state = reorderPreview else { return }
        let order = previewDisplayOrder(
            count: items.count, blockIndices: state.blockIndices, slot: state.slot)
        let preview = previewFrames(
            displayOrder: order, aspects: layout.aspects,
            availableWidth: layout.preparedWidth, columns: layout.solvedColumns,
            spacing: layout.spacing, topInset: layout.solvedTopInset,
            leadingInset: layout.solvedLeadingInset,
            trailingInset: layout.solvedTrailingInset)
        setLayoutPreview(preview, animated: animated)
        applyGhostDimming(ids: Set(state.blockIndices.compactMap {
            items.indices.contains($0) ? items[$0].item.id : nil
        }))
    }

    /// Tear down any active preview (drag-exit / session-end / mid-drag reload).
    private func clearReorderPreview(animated: Bool) {
        guard reorderPreview != nil || layout.preview != nil || !ghostBlockIDs.isEmpty else {
            return
        }
        reorderPreview = nil
        awaitingReorderCommit = false
        setLayoutPreview(nil, animated: animated)
        applyGhostDimming(ids: [])
    }

    /// Push a preview (or `nil`) onto the layout and re-lay it out. An animated
    /// change slides cells to their new slots via implicit animation (040 decision
    /// 8; the step-3 spike's chosen mechanism — swap here for `performBatchUpdates`
    /// if a build shows a teleport). A non-animated change (commit / cancel) snaps.
    private func setLayoutPreview(_ preview: MasonryPreviewFrames?, animated: Bool) {
        layout.preview = preview
        guard let collectionView else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.reorderAnimationDuration
                context.allowsImplicitAnimation = true
                layout.invalidateLayout()
                collectionView.layoutSubtreeIfNeeded()
            }
        } else {
            layout.invalidateLayout()
        }
    }

    /// Dim the block cells to the ghost opacity, restore the rest. Records
    /// `ghostBlockIDs` so ``configure(_:at:)`` re-dims a cell scrolled in mid-drag.
    private func applyGhostDimming(ids: Set<UUID>) {
        ghostBlockIDs = ids
        guard let collectionView else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard items.indices.contains(indexPath.item),
                  let cell = collectionView.item(at: indexPath) as? MasonryGridItem
            else { continue }
            cell.view.alphaValue = ids.contains(items[indexPath.item].item.id) ? Self.ghostAlpha : 1
        }
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
        // The detail page owns the keyboard while it is up (069). The grid keeps first
        // responder behind it, so anything consumed here is a key the page never sees —
        // which is what killed its ← / →. Falling through leaves Escape working exactly
        // as it does below, and leaves Delete alone: the delete KEY still reaches
        // `gridDeleteCommand()` through `deleteBackward:`/`deleteForward:`, which are
        // responder methods and do not come through here.
        if configuration.isDetailPresented { return false }
        let mods = event.modifierFlags
        // ⌘-combos travel through `performKeyEquivalent`, earlier in the chain.
        if mods.contains(.command) { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        // ⌫ / ⌦ through the shared decoder rather than `gridIsDeleteKey` alone (022 ·
        // D2): the predicate says only WHICH keys are delete keys, and the grid used
        // to act on any of them regardless of modifiers — so ⌥⌫, a word-delete, ran
        // the destructive verb. Only `.remove` can reach here (⌘ returned above);
        // ⌘⌫ arrives at `gridPerformKeyEquivalent`.
        if let intent = deleteIntent(characters: chars, modifiers: mods) {
            execute(deleteIntent: intent)
            return true
        }
        guard let command = gridKeyCommand(characters: chars, modifiers: mods) else { return false }
        return execute(keyCommand: command)
    }

    func gridPerformKeyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        guard mods.contains(.command) else { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        // ⌘⌫ / ⌘⌦ — the destructive verb's ONLY keyboard seam (022 · D2). It has to be
        // here: ⌘-combos are dispatched through `performKeyEquivalent` before
        // `keyDown`, and `deleteBackward:` is never sent for a modified Delete.
        //
        // `isDetailPresented` gates it for the same reason `gridKeyDown` opens with
        // that check, and it matters MORE here: `performKeyEquivalent` walks the view
        // hierarchy rather than the responder chain, so the grid behind the page would
        // receive this even though the page holds first responder — and would destroy
        // the grid's selection while the user was looking at one item.
        if !configuration.isDetailPresented,
           let intent = deleteIntent(characters: chars, modifiers: mods) {
            execute(deleteIntent: intent)
            return true
        }
        guard let command = gridKeyCommand(characters: chars, modifiers: mods) else { return false }
        return execute(keyCommand: command)
    }

    func gridDeleteCommand() { configuration.onRequestRemove() }

    /// Run a decoded ``DeleteIntent`` against this grid's two seams — the ONE place
    /// the grid turns "which delete key" into "which verb", so the responder-method
    /// path, `keyDown` and `performKeyEquivalent` can never drift apart.
    private func execute(deleteIntent intent: DeleteIntent) {
        switch intent {
        case .remove: configuration.onRequestRemove()
        case .destroy: configuration.onRequestDelete()
        }
    }

    func gridCopyCommand() { configuration.onCopy() }

    var gridHasSelection: Bool { !configuration.selectionStore.selection.ids.isEmpty }

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
        // Unbound on a surface that supplies no handler — fall through rather than
        // swallowing the letter (see ``GridHostConfiguration/onDestinationVerb``).
        case .moveTo:
            guard let raise = configuration.onDestinationVerb else { return false }
            raise(.move)
        case .addTo:
            guard let raise = configuration.onDestinationVerb else { return false }
            raise(.add)
        // Unbound on a surface that supplies no handler — fall through rather
        // than swallowing the letter, exactly as Move to / Add to do.
        case .archiveVerb:
            guard let archive = configuration.onArchiveVerb else { return false }
            archive()
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

// MARK: - Block-backed menu item (036 §4 A3)

/// An `NSMenuItem` that fires a closure — the native menu's leaf actions carry
/// captured `[UUID]` target sets, so a per-item closure is cleaner than one shared
/// `@objc` selector demuxing on `representedObject`.
/// `nonisolated` because `NSMenuItem`'s designated initializers are: under this
/// target's MainActor-by-default the subclass would infer main-actor isolation and
/// fail to match what it overrides. The handler is typed `@MainActor` instead —
/// AppKit delivers menu actions on the main thread, and every closure passed here
/// touches main-actor state, so the isolation belongs on the CLOSURE rather than
/// on the menu item that merely carries it.
/// Internal (not `private`) since 027 · G2: ``CollectionDestinationMenu`` builds
/// the nested destination submenus out of the same closure-backed item.
nonisolated final class BlockMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void
    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable)
    nonisolated required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    @MainActor @objc private func fire() { handler() }
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

/// The export plan for a drag (011 · Cluster A): the ``AssetExportItem`` for every
/// dragged asset that has an exportable file, in GRID order (15A). Iterates
/// `details` once, keeping those whose `asset.id` is in the dragged set — so the
/// exported files come out in the same order they appear in the grid, and a
/// media-less / missing-blob asset is simply dropped (via
/// ``AssetExport/exportItem(asset:source:blobURL:)`` returning `nil`). An empty
/// result means "nothing to export" → the drag stays internal-only.
func gridExportPlan(
    assetIDs: [UUID], details: [CollectionItemDetail], blobURL: (CollectionItemDetail) -> URL?
) -> [AssetExportItem] {
    let wanted = Set(assetIDs)
    return details.compactMap { detail in
        guard wanted.contains(detail.asset.id) else { return nil }
        return AssetExport.exportItem(
            asset: detail.asset, source: detail.source, blobURL: blobURL(detail))
    }
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
nonisolated enum GridApplyStrategy: Equatable {
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
nonisolated enum GridKeyCommand: Equatable {
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
    /// M (bare) — open the destination picker on "Move to…" (024 · K3).
    case moveTo
    /// A (bare) — open the destination picker on "Add to…" (024 · K3).
    case addTo
    /// E (bare) — the archive verb (023 · A3). Which verb it IS — archive or
    /// unarchive — is not decided here: the key press only says "the archive
    /// verb", and ``shelfVerb(targets:archived:)`` decides what that means for
    /// the selection at hand.
    case archiveVerb
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
/// - `m` / `a` with no ⌘ / ⌥ / ⌃ → `.moveTo` / `.addTo` (024 · K3). ⇧ IS tolerated
///   here, unlike `x`: these are verbs a user types, and a stray capital meant the
///   verb. The guard that matters is the other one — ⌘A stays Select All below,
///   ⌘M is nobody's, and ⌥A still types `å` in a text field.
/// - ⌘A → `.selectAll`; ⌘+ / ⌘= → `.zoomIn`; ⌘− → `.zoomOut`.
func gridKeyCommand(
    characters: String, modifiers: NSEvent.ModifierFlags
) -> GridKeyCommand? {
    let command = modifiers.contains(.command)
    let shift = modifiers.contains(.shift)
    let bareModifiers = modifiers.intersection([.command, .shift, .option, .control])
    // ⇧ omitted on purpose — see the `m` / `a` cases below.
    let hardModifiers = modifiers.intersection([.command, .option, .control])

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
    // ⌘A stays Select All; bare (or ⇧) A opens "Add to…" (024 · K3). ⌥A / ⌃A are
    // neither — they belong to whatever a text field would do with them.
    case "a", "A":
        if command { return .selectAll }
        return hardModifiers.isEmpty ? .addTo : nil
    case "=", "+": return command ? .zoomIn : nil           // ⌘= / ⌘+
    case "-": return command ? .zoomOut : nil               // ⌘−
    case "x", "X": return bareModifiers.isEmpty ? .toggleLead : nil  // X, no modifiers
    case "m", "M": return hardModifiers.isEmpty ? .moveTo : nil      // M — "Move to…"
    // E — the archive verb (023 · A3). Same guard as M / A: ⇧ tolerated (a
    // stray capital still meant the verb), ⌘ / ⌥ / ⌃ disqualify — ⌘E is Find
    // Next by convention and ⇧⌘E is Export moodboard, so neither may be eaten,
    // and ⌥E is a dead-key accent in a text field.
    case "e", "E": return hardModifiers.isEmpty ? .archiveVerb : nil
    default: return nil
    }
}
