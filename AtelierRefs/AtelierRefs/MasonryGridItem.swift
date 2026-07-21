//
//  MasonryGridItem.swift
//  AtelierRefs
//
//  036 §2 A1 — the AppKit grid cell, "hybrid, mostly native" (ported from the
//  read-only `MasonryBakeoffItem` spike). The dominant cell kind is just
//  "image + border", so that path is a single layer-backed `CALayer`:
//  `layer.contents` + `.resizeAspectFill` + a corner radius, decoded off-main
//  through ``ThumbnailPipeline`` — no per-cell `NSHostingView`, whose layout
//  cost was the ORIGINAL measured bottleneck (035 §1). A media-less card tile
//  (bare link / tweet / colour) has no thumbnail, so it — and only it — lazily
//  hosts the existing SwiftUI ``AssetContentThumbnail`` render seam.
//
//  ── What is WIRED in A1 (read-only) ──────────────────────────────────────
//   • The image layer + async decode with an identity re-check on reuse.
//   • The lazy hosted card for media-less kinds (`sizingOptions = []`, rootView
//     updated on reuse, never recreated).
//   • The accessibility label, via the shared pure ``gridCellAccessibilityLabel``.
//
//  ── Wired in A2 (036 §4 A2) ──────────────────────────────────────────────
//   • ``selectionRingLayer`` / ``cursorRingLayer`` + ``applySelectionState(_:)`` —
//     the targeted-invalidation entry point the coordinator drives from
//     `selectionStore`; layer-only, no relayout.
//   • ``circleButton`` — the enter-selection affordance, wired to `.tapCircle`
//     via ``MasonryGridInteraction``. Visible while SELECTING (all cells) or
//     HOVERED (idle), combined by ``updateCircleVisibility()``.
//   • Cell-view ``mouseDown`` forwarding + ``setHovered(_:)`` — the coordinator
//     owns the routing tables and the drag-threshold loop; the cell only reports.
//
//  ── Still INERT until A3 ─────────────────────────────────────────────────
//   • ``gifSlot`` — the hover-dwell animated-GIF overlay A3 populates.
//   • The drag hand-off itself (the threshold loop's CLASSIFICATION is A2; the
//     drag session is A3 — see the coordinator's stub).
//

import AppKit
import AtelierCore
import SwiftUI

// MARK: - Selection state (the A2 entry point, inert in A1)

/// The per-cell selection inputs ``MasonryGridItem/applySelectionState(_:)``
/// renders as layers. A value type so A2's `selectionCellDelta` can diff two of
/// them cheaply. In A1 the data source always passes the all-false default.
struct CellSelectionState: Equatable {
    /// In the selection set — draws the selection ring.
    var isSelected = false
    /// The keyboard/detail cursor (`lead`) — draws a focus ring when not also
    /// selected (a selected cell already reads as focused).
    var isCursor = false
    /// Selection mode is active somewhere in the grid — circles show on ALL cells
    /// so any can be toggled (A2 wiring).
    var isSelecting = false

    static let inert = CellSelectionState()
}

// MARK: - Interaction delegate (A2)

/// What a cell reports back to the coordinator (036 §4 A2). The cell owns no
/// selection logic — it forwards the raw mouse-down (so the coordinator runs the
/// pure `gridPressRouting`/`gridClickAction` tables + the drag-threshold loop) and
/// the circle click (`.tapCircle`). Weakly held; the coordinator outlives its cells.
@MainActor
protocol MasonryGridInteraction: AnyObject {
    /// A mouse-down landed on the cell's image area (NOT the circle — that hit-tests
    /// to the button). The coordinator applies the down-edge routing, then runs a
    /// local drag-threshold loop to classify click vs drag.
    func gridCellMouseDown(id: UUID, event: NSEvent)
    /// The enter-selection circle was clicked → `.tapCircle`.
    func gridCellCircleClicked(id: UUID)
}

// MARK: - Accessibility (shared pure function)

/// The VoiceOver label for a grid cell: the asset kind plus its best available
/// human name (title → author handle → bare kind). Pure and free-standing so it
/// is unit-tested without a view and shared between the SwiftUI cell and this
/// AppKit one (036 §2 A1). Mirrors `CollectionCell.accessibilityLabel` exactly.
func gridCellAccessibilityLabel(for detail: CollectionItemDetail) -> String {
    let kind: String
    switch detail.asset.kind {
    case .image: kind = "Image"
    case .video: kind = "Video"
    case .tweet: kind = "Tweet"
    case .link: kind = "Link"
    case .color: kind = "Color"
    }
    if let title = detail.source.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty {
        return "\(kind), \(title)"
    }
    if let handle = detail.source.authorHandle, !handle.isEmpty {
        return "\(kind) by \(handle)"
    }
    return kind
}

// MARK: - The cell

final class MasonryGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MasonryGridItem")

    /// Bumped on every (re)configure and on reuse. An in-flight decode that
    /// completes after the cell was recycled sees a stale token and drops its
    /// result — the identity re-check that stops a fast scroll from painting item
    /// A's thumbnail into item B's cell.
    private var loadToken = 0
    private var loadTask: Task<Void, Never>?

    /// The lazily-created host for a media-less card kind (bare link / tweet /
    /// colour). Created ONCE and reused: its rootView is swapped on reuse, never
    /// the view itself (036 §2 A1 — per-cell `NSHostingView` recreation was the
    /// measured cost). `nil` until the first card kind lands in this cell.
    private var cardHost: NSHostingView<AnyView>?

    /// Inert-until-A2 selection ring (drawn when selected).
    private let selectionRingLayer = CALayer()
    /// Inert-until-A2 keyboard-cursor ring (drawn when lead && !selected).
    private let cursorRingLayer = CALayer()
    /// Inert-until-A2 enter-selection circle affordance.
    private let circleButton = NSButton()
    /// The hover-dwell animated-GIF overlay slot (A3). Populated only after the
    /// dwell elapses AND this cell wins the single-animation slot; hit-transparent.
    private var gifSlot: NSView?

    /// The ORIGINAL blob URL when this cell is an animatable GIF (else nil — the
    /// static thumbnail tiers are flattened posters and can't animate). Set in
    /// ``configure``; the coordinator already gates it on `mimeType == image/gif`.
    private var gifURL: URL?
    /// The GIF's byte size, for the animation budget (a huge GIF stays static —
    /// a hover peek isn't worth decoding multi-MB into memory).
    private var gifFileSize: Int?
    /// The pending dwell timer before a hovered GIF animates (cancelled on
    /// hover-out / reuse), ported verbatim from `CollectionCell` (011-B5 · 15A).
    private var gifDwell: Task<Void, Never>?
    /// The id currently holding the ``GifAnimationCoordinator`` slot via this cell,
    /// so reuse / hover-out releases exactly what it claimed (a stale release from
    /// another cell is already a no-op in the coordinator).
    private var animatingGifID: UUID?

    private let cornerRadius: CGFloat = 8

    /// The membership id this cell is currently bound to — the coordinator reads it
    /// back when the cell reports a mouse-down / circle click (A2). Set in
    /// ``configure(detail:url:bucket:)``.
    var itemID: UUID?
    /// The coordinator, which owns all selection/mouse routing (A2). Weak: the
    /// coordinator holds the cells, never the reverse.
    weak var interaction: MasonryGridInteraction?

    /// The last selection state applied — combined with ``isHovered`` to decide the
    /// circle's visibility (the circle shows while SELECTING or HOVERED).
    private var currentSelection = CellSelectionState.inert
    /// Whether the pointer is over this cell (driven by the coordinator's one
    /// tracking area — 036 §4 A2). Idle-hover is the other reason the circle shows.
    private var isHovered = false

    // MARK: View

    override func loadView() {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.owner = self
        container.wantsLayer = true
        container.layerContentsRedrawPolicy = .never
        if let layer = container.layer {
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            layer.cornerRadius = cornerRadius
            layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }

        // Rings: built now, hidden in A1. Sized in `viewDidLayout`.
        for ring in [selectionRingLayer, cursorRingLayer] {
            ring.cornerRadius = cornerRadius
            ring.borderWidth = 0
            ring.isHidden = true
            container.layer?.addSublayer(ring)
        }
        selectionRingLayer.borderColor = NSColor.controlAccentColor.cgColor
        cursorRingLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor

        // Circle affordance: the enter-selection toggle (A2). Hidden until the cell
        // is selecting or hovered (``updateCircleVisibility``); its click routes to
        // `.tapCircle` via the coordinator. Kept hidden from VoiceOver exactly as the
        // SwiftUI circle was (`.accessibilityHidden(true)`) — the cell itself
        // announces + toggles selection, so exposing the circle would double up.
        circleButton.isBordered = false
        circleButton.bezelStyle = .regularSquare
        circleButton.imagePosition = .imageOnly
        circleButton.image = NSImage(
            systemSymbolName: "circle", accessibilityDescription: nil)
        circleButton.isHidden = true
        circleButton.setAccessibilityHidden(true)
        circleButton.target = self
        circleButton.action = #selector(circleClicked)
        container.addSubview(circleButton)

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Rings and any hosted card track the cell bounds. Implicit CALayer
        // animations are suppressed so a recycle/relayout never cross-fades.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = view.bounds
        selectionRingLayer.frame = bounds
        cursorRingLayer.frame = bounds
        cardHost?.frame = bounds
        gifSlot?.frame = bounds
        CATransaction.commit()
        // Top-trailing, matching the SwiftUI circle's corner.
        let side: CGFloat = 32
        circleButton.frame = NSRect(
            x: bounds.maxX - side, y: bounds.minY, width: side, height: side)
    }

    // MARK: Configure

    /// Bind this cell to `detail`. A byte-backed kind (image / video / card WITH
    /// an image) paints via the layer + ``ThumbnailPipeline``; a media-less card
    /// kind hosts ``AssetContentThumbnail``. `url` is the on-disk 512-tier
    /// thumbnail (nil for media-less), `bucket` the analytic-frame pixel bucket
    /// the host computed (the cell never guesses its own size — 036 §4 C3).
    func configure(detail: CollectionItemDetail, url: URL?, bucket: Int, gifURL: URL?) {
        loadToken &+= 1
        let token = loadToken
        loadTask?.cancel()
        loadTask = nil

        itemID = detail.item.id
        // GIF hover-preview inputs (A3): the original bytes (nil unless this is an
        // animatable GIF) plus its size for the budget. A (re)configure that lands
        // on a different item cancels any in-flight dwell for the old one.
        cancelGifDwell()
        self.gifURL = gifURL
        gifFileSize = detail.asset.fileSize
        view.setAccessibilityLabel(gridCellAccessibilityLabel(for: detail))

        // Media-less card kinds (bare link / tweet / colour / unknown) have no
        // thumbnail — host the existing SwiftUI render seam instead of the layer.
        guard let hash = detail.asset.blobHash, let url else {
            showCard(for: detail)
            return
        }
        hideCard()

        // Synchronous cache hit paints with no async hop — the common warm case,
        // and why a recycled cell does not flash.
        if let hit = ThumbnailPipeline.shared.cached(hash: hash, bucket: bucket) {
            setImage(hit)
            return
        }
        setImage(nil)
        loadTask = Task { [weak self] in
            let image = await ThumbnailPipeline.shared.image(
                hash: hash, url: url, bucket: bucket)
            guard let self, !Task.isCancelled, self.loadToken == token else { return }
            // Re-read the bucket-tolerant cache so a fallback bitmap still paints.
            self.setImage(image ?? ThumbnailPipeline.shared.cached(hash: hash, bucket: bucket))
        }
    }

    /// The targeted-invalidation entry point (036 §4 A2) — mutates LAYERS only, no
    /// relayout, no snapshot. This is what keeps multi-select smooth: the
    /// coordinator calls it on the handful of changed cells, not the whole grid.
    /// Circle VISIBILITY is deferred to ``updateCircleVisibility()`` because it also
    /// depends on hover; here we only pick the circle's checkmark/empty symbol.
    func applySelectionState(_ state: CellSelectionState) {
        currentSelection = state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionRingLayer.isHidden = !state.isSelected
        selectionRingLayer.borderWidth = state.isSelected ? 3 : 0
        let showCursor = state.isCursor && !state.isSelected
        cursorRingLayer.isHidden = !showCursor
        cursorRingLayer.borderWidth = showCursor ? 2 : 0
        CATransaction.commit()
        circleButton.image = NSImage(
            systemSymbolName: state.isSelected ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: nil)
        circleButton.contentTintColor = state.isSelected ? .controlAccentColor : .white
        updateCircleVisibility()
    }

    /// Show/hide the enter-selection circle (idle-hover half — 036 §4 A2). Layer-
    /// only, like ``applySelectionState``; the coordinator drives it from its one
    /// tracking area, replacing the SwiftUI per-cell `.onHover` (and its
    /// `hoverAfterWindowChange` stranded-circle workaround).
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateCircleVisibility()
        updateGifAnimation()
    }

    /// The dwell-gated, budgeted, single-slot GIF animation (011-B5 · 15A), ported
    /// from `CollectionCell.handleHover`. Reduce Motion (read live off
    /// `NSWorkspace`), a non-GIF cell, or an over-budget GIF short-circuits BEFORE
    /// any decode; otherwise a 150 ms dwell must elapse and the single-animation
    /// slot must be free before the overlay is created.
    private func updateGifAnimation() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let gifURL, let itemID, isHovered,
              shouldAnimateGif(
                mimeType: GifMotion.gifMimeType, reduceMotion: reduceMotion, isHovering: true),
              gifWithinBudget(fileSize: gifFileSize) else {
            cancelGifDwell()
            return
        }
        gifDwell?.cancel()
        gifDwell = Task { @MainActor [weak self] in
            try? await Task.sleep(for: GifMotion.hoverDwell)
            guard let self, !Task.isCancelled, self.itemID == itemID else { return }
            if GifAnimationCoordinator.shared.claim(itemID) {
                self.animatingGifID = itemID
                self.showGif(url: gifURL)
            }
        }
    }

    /// Cancel any pending dwell, release the animation slot iff this cell holds it,
    /// and tear down the overlay (frees the decoded frames). Idempotent.
    private func cancelGifDwell() {
        gifDwell?.cancel()
        gifDwell = nil
        if let id = animatingGifID {
            GifAnimationCoordinator.shared.release(id)
            animatingGifID = nil
        }
        releaseGifSlot()
    }

    /// The circle shows while SELECTING (every cell is toggleable) or, when idle,
    /// only on the hovered cell — the exact SwiftUI rule
    /// (`isSelecting || hoveredItemID == id`).
    private func updateCircleVisibility() {
        circleButton.isHidden = !(currentSelection.isSelecting || isHovered)
    }

    /// The image-area mouse-down, forwarded from the cell view (A2). A circle click
    /// hit-tests to the button instead and never reaches here.
    func handleViewMouseDown(_ event: NSEvent) {
        guard let itemID else { return }
        interaction?.gridCellMouseDown(id: itemID, event: event)
    }

    @objc private func circleClicked() {
        guard let itemID else { return }
        interaction?.gridCellCircleClicked(id: itemID)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        loadTask?.cancel()
        loadTask = nil
        itemID = nil
        isHovered = false
        // Cancels the dwell AND releases the animation slot this cell held (A3), so
        // a recycled GIF cell never leaks the single-animation slot — this is the
        // real-recycling hook NSCollectionView calls before re-vending the item.
        cancelGifDwell()
        gifURL = nil
        gifFileSize = nil
        setImage(nil)
        hideCard()
        applySelectionState(.inert)
    }

    // MARK: Layer / host swaps

    private func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contents = image
        view.layer?.backgroundColor =
            image == nil ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    /// Show the media-less card, creating the host on first use and only swapping
    /// its rootView thereafter.
    private func showCard(for detail: CollectionItemDetail) {
        setImage(nil)
        let root = AnyView(
            AssetContentThumbnail(
                asset: detail.asset, url: nil, cornerRadius: cornerRadius, fill: true))
        if let host = cardHost {
            host.rootView = root
            host.isHidden = false
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            // Below the rings/circle, which are added last / on the container.
            view.addSubview(host, positioned: .below, relativeTo: circleButton)
            cardHost = host
        }
        // The card draws its own background; clear the placeholder tint.
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func hideCard() {
        cardHost?.isHidden = true
    }

    /// Mount the animated GIF over the static poster (011-B5). Reuses the proven
    /// ``AnimatedGifView`` player through a hit-transparent host so selection / drag
    /// still land on the cell underneath (the SwiftUI overlay used
    /// `.allowsHitTesting(false)`; the host below returns `nil` from `hitTest`).
    private func showGif(url: URL) {
        releaseGifSlot()
        let host = HitTransparentHostingView(rootView: AnimatedGifView(url: url))
        host.sizingOptions = []
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        // Above the image layer, below the circle/rings (added on the container).
        view.addSubview(host, positioned: .below, relativeTo: circleButton)
        gifSlot = host
    }

    private func releaseGifSlot() {
        gifSlot?.removeFromSuperview()
        gifSlot = nil
    }
}

/// An `NSHostingView` that never claims a hit, so the animated-GIF overlay it
/// carries can't steal the cell's mouse-down / drag (the SwiftUI peer used
/// `.allowsHitTesting(false)`).
private final class HitTransparentHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The cell container. Flipped so any A2/A3 subview geometry shares the grid's
/// top-left content space, matching the flipped collection view. Forwards its
/// image-area mouse-down to the owning item (A2); a circle click hit-tests to the
/// button subview and never reaches here.
private final class FlippedContentView: NSView {
    weak var owner: MasonryGridItem?
    override var isFlipped: Bool { true }
    /// Register the click even when it also brings the window forward (Finder-like),
    /// so a first click into an inactive window still selects.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        owner?.handleViewMouseDown(event)
    }
}
