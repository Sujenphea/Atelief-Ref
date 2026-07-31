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
    /// Something ELSE from this cell's post is selected while this cell is not —
    /// draws the dashed "same post" ring so a carousel's remaining members are
    /// visible the moment one of them is picked (307 · carousel grouping).
    var isPostSibling = false

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
/// `postMemberCount` (307) is the size of the multi-item post this cell belongs to
/// — 0 or 1 when it stands alone. When it is a carousel member the label says so,
/// because the visual badge that carries it sighted is a pixmap VoiceOver can't read.
func gridCellAccessibilityLabel(for detail: CollectionItemDetail, postMemberCount: Int = 0) -> String {
    let suffix = postMemberCount > 1 ? ", one of \(postMemberCount) from the same post" : ""
    return gridCellBaseAccessibilityLabel(for: detail) + suffix
}

private func gridCellBaseAccessibilityLabel(for detail: CollectionItemDetail) -> String {
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

// MARK: - Carousel badge (307 · carousel grouping)

/// The "N items from this post" chip painted into a cell's top-leading corner.
///
/// Pre-rendered to an `NSImage` and cached by count, then handed to a plain
/// `CALayer.contents` — the cell's whole reason for existing is that it does NOT
/// host SwiftUI or lay out subviews per cell (036 §2 A1), and a badge is a fixed
/// pixmap per distinct count, so there is at most a handful of them in the cache
/// for any real feed.
@MainActor
enum PostBadge {
    /// Rendered chips by member count. Small and bounded (one per distinct
    /// carousel length seen), never invalidated — the artwork is appearance-
    /// independent (white on translucent black reads on every backdrop).
    private static var cache: [Int: NSImage] = [:]

    static let height: CGFloat = 18
    /// The inset from the cell's top-leading corner (the selection circle owns
    /// the opposite corner, so the two never collide).
    static let inset: CGFloat = 6

    /// The chip for `count` members — a translucent-dark capsule holding the
    /// stacked-squares glyph and the count.
    static func image(count: Int) -> NSImage? {
        guard count > 1 else { return nil }
        if let hit = cache[count] { return hit }
        guard let made = render(count: count) else { return nil }
        cache[count] = made
        return made
    }

    private static func render(count: Int) -> NSImage? {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        guard let glyph = NSImage(
            systemSymbolName: "square.on.square", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) else { return nil }

        let text = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let hPad: CGFloat = 6, gap: CGFloat = 3
        let width = (hPad * 2 + glyph.size.width + gap + textSize.width).rounded(.up)
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        // A soft dark capsule rather than the accent: the badge is a permanent
        // fixture on every carousel tile, and accent-coloured chrome that is
        // always on would compete with the accent SELECTION ring right next to it.
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: height / 2, yRadius: height / 2).fill()
        glyph.isTemplate = true
        NSColor.white.set()
        let glyphRect = NSRect(
            x: hPad, y: ((height - glyph.size.height) / 2).rounded(),
            width: glyph.size.width, height: glyph.size.height)
        glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
        text.draw(
            at: NSPoint(x: glyphRect.maxX + gap, y: ((height - textSize.height) / 2).rounded()),
            withAttributes: attributes)
        image.unlockFocus()
        return image
    }
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

    /// A dim scrim painted over the thumbnail — the Photos-style "pull the image
    /// back" cue that makes the ring and checkmark pop AND signals the state on its
    /// own. Sits below the rings/circle so those stay crisp.
    ///
    /// ONE layer carries both states, selected and hovered, so they can never drift
    /// into different blacks nor stack into a double dim on a cell that is both.
    /// ``updateScrim()`` is the only thing that sets it.
    private let scrimLayer = CALayer()
    /// Inert-until-A2 selection ring (drawn when selected).
    private let selectionRingLayer = CALayer()
    /// A translucent-dark hairline nested just INSIDE the accent selection ring so
    /// the border keeps a luminance edge on light/bright images (the accent stroke
    /// alone vanishes against a pale photo). Drawn only when selected.
    private let selectionContrastLayer = CALayer()
    /// Inert-until-A2 keyboard-cursor ring (drawn when lead && !selected).
    private let cursorRingLayer = CALayer()
    /// The dashed "same post" ring (307): drawn on an UNSELECTED cell while a
    /// sibling from its carousel IS selected. A `CAShapeLayer` because a dash
    /// pattern needs a stroked path — `CALayer.borderWidth` can only draw solid,
    /// and a solid accent ring here would be indistinguishable from selection.
    private let siblingRingLayer = CAShapeLayer()
    /// The carousel count chip (307), painted top-leading whenever this cell's post
    /// has more than one item in the feed. Purely informational — hit-transparent
    /// (it's a layer, not a view) so it can't intercept a click or a drag.
    private let postBadgeLayer = CALayer()
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

    private let cornerRadius: CGFloat = Theme.Radius.tile
    /// The selected-cell ring width. The contrast hairline nests inside it.
    private let selectionRingWidth: CGFloat = 3
    /// The keyboard-cursor ring width — thinner AND half-transparent, so a cursor
    /// can never be mistaken for a selection now that both are white.
    private let cursorRingWidth: CGFloat = 2
    /// The selected cell's dim. Strong enough to read as a state on its own.
    private let selectedScrimOpacity: Float = 0.18
    /// The hovered cell's dim — the same gesture at roughly half strength. Hover
    /// says "this is the one under the pointer"; selection says "this is chosen",
    /// and the app's own rule (see `Theme.Colors.hoverRow`) is that hover must not
    /// be mistakable for it. A hovered cell also has no ring and no checkmark, so
    /// the two never read alike even at a glance.
    private let hoverScrimOpacity: Float = 0.10
    /// The contrast hairline's own width. Half-opaque black at 2pt, not the 1pt
    /// whisper it was: under the blue accent it only had to survive pale images,
    /// where the blue still read; under a white ring it IS the edge there.
    private let contrastHairlineWidth: CGFloat = 2

    /// The ring the contrast hairline currently nests inside — the hairline hugs
    /// whichever ring is drawn, so there is never a gap of bare image between them.
    private var activeRingWidth: CGFloat {
        currentSelection.isSelected ? selectionRingWidth : cursorRingWidth
    }
    /// The dashed same-post ring's stroke — thinner than the selection ring so the
    /// two are never confused at a glance (307).
    private let siblingRingWidth: CGFloat = 2

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
    /// How many feed items share this cell's post (307) — 0 when it stands alone.
    /// Drives the carousel chip and the VoiceOver suffix.
    private var postMemberCount = 0

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
            // The token, not `quaternaryLabelColor`: a translucent, appearance-derived
            // system grey was the one thing `Theme`'s header names as drift — and it
            // shifted tone with whatever showed through it.
            layer.backgroundColor = Theme.NS.mediaBackdrop.cgColor
        }

        // Selected-cell dim scrim (below the rings so they stay crisp). Sized in
        // `viewDidLayout`; opacity toggled in `applySelectionState`.
        scrimLayer.cornerRadius = cornerRadius
        scrimLayer.backgroundColor = NSColor.black.cgColor
        scrimLayer.opacity = 0
        scrimLayer.isHidden = true
        container.layer?.addSublayer(scrimLayer)

        // Rings: built now, hidden in A1. Sized in `viewDidLayout`.
        for ring in [selectionRingLayer, cursorRingLayer] {
            ring.cornerRadius = cornerRadius
            ring.borderWidth = 0
            ring.isHidden = true
            container.layer?.addSublayer(ring)
        }
        selectionRingLayer.borderColor = Theme.NS.selectionMark.cgColor
        cursorRingLayer.borderColor = Theme.NS.selectionMark.withAlphaComponent(0.6).cgColor

        // Contrast hairline nested just inside the white ring (sized in
        // `viewDidLayout`). Added last of the rings so it paints ABOVE the ring's
        // inner edge: the white reads against dark artwork and this reads against
        // light, so the pair keeps an edge at both ends of the range. Shown for the
        // CURSOR ring too — a white ring needs it more than the blue accent did.
        selectionContrastLayer.borderColor = Theme.NS.selectionMarkContrast.cgColor
        selectionContrastLayer.borderWidth = 0
        selectionContrastLayer.isHidden = true
        container.layer?.addSublayer(selectionContrastLayer)

        // Dashed same-post ring (307). Inset by half the stroke so the dash sits
        // fully inside the tile instead of being clipped by `masksToBounds`.
        siblingRingLayer.fillColor = nil
        siblingRingLayer.strokeColor = NSColor.controlAccentColor.cgColor
        siblingRingLayer.lineWidth = siblingRingWidth
        siblingRingLayer.lineDashPattern = [5, 4]
        siblingRingLayer.isHidden = true
        container.layer?.addSublayer(siblingRingLayer)

        // Carousel count chip (307), top-leading. Contents are set per-configure
        // from the cached artwork; the frame is sized to that image.
        postBadgeLayer.contentsGravity = .resizeAspect
        postBadgeLayer.isHidden = true
        container.layer?.addSublayer(postBadgeLayer)

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
        // Soft halo so the circle's edge survives any backing — a pale image would
        // otherwise swallow the accent circle and the white empty-state ring.
        circleButton.wantsLayer = true
        circleButton.layer?.shadowColor = NSColor.black.cgColor
        circleButton.layer?.shadowOpacity = 0.35
        circleButton.layer?.shadowRadius = 2.5
        circleButton.layer?.shadowOffset = .zero
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
        scrimLayer.frame = bounds
        selectionRingLayer.frame = bounds
        layOutContrastHairline(in: bounds)
        cursorRingLayer.frame = bounds
        siblingRingLayer.frame = bounds
        let ringRect = bounds.insetBy(dx: siblingRingWidth / 2, dy: siblingRingWidth / 2)
        siblingRingLayer.path = CGPath(
            roundedRect: ringRect,
            cornerWidth: max(0, cornerRadius - siblingRingWidth / 2),
            cornerHeight: max(0, cornerRadius - siblingRingWidth / 2),
            transform: nil)
        if let badge = postBadgeLayer.contents as? NSImage {
            postBadgeLayer.frame = NSRect(
                x: bounds.minX + PostBadge.inset, y: bounds.minY + PostBadge.inset,
                width: badge.size.width, height: badge.size.height)
        }
        cardHost?.frame = bounds
        gifSlot?.frame = bounds
        CATransaction.commit()
        // Top-trailing, matching the SwiftUI circle's corner.
        let side: CGFloat = 32
        circleButton.frame = NSRect(
            x: bounds.maxX - side, y: bounds.minY, width: side, height: side)
    }

    /// Paint the dim for the cell's current state — selected wins over hovered, and
    /// a cell that is both gets ONE dim, not two stacked. Called from
    /// ``applySelectionState(_:)`` and ``setHovered(_:)``, the two things that can
    /// change either input.
    ///
    /// Instant, like everything else in this cell and like the app's SwiftUI
    /// `HoverHighlight`: implicit CALayer animation is suppressed throughout so a
    /// recycled cell never cross-fades a previous item's state into this one's.
    private func updateScrim() {
        let opacity: Float =
            currentSelection.isSelected ? selectedScrimOpacity
            : isHovered ? hoverScrimOpacity : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrimLayer.isHidden = opacity == 0
        scrimLayer.opacity = opacity
        CATransaction.commit()
    }

    /// Nest the contrast hairline immediately inside whichever ring is showing.
    /// Called from both `viewDidLayout` (bounds changed) and `applySelectionState`
    /// (the ring changed) — the two inputs are independent, so neither can own it.
    private func layOutContrastHairline(in bounds: CGRect) {
        let inset = activeRingWidth
        selectionContrastLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        selectionContrastLayer.cornerRadius = max(0, cornerRadius - inset)
    }

    // MARK: Configure

    /// Bind this cell to `detail`. A byte-backed kind (image / video / card WITH
    /// an image) paints via the layer + ``ThumbnailPipeline``; a media-less card
    /// kind hosts ``AssetContentThumbnail``. `url` is the on-disk 512-tier
    /// thumbnail (nil for media-less), `bucket` the analytic-frame pixel bucket
    /// the host computed (the cell never guesses its own size — 036 §4 C3).
    /// `postMemberCount` is how many items of the CURRENT feed came from this
    /// item's post (0 when it isn't part of a multi-item post) — the carousel chip.
    func configure(
        detail: CollectionItemDetail, url: URL?, bucket: Int, gifURL: URL?,
        postMemberCount: Int = 0
    ) {
        setPostMemberCount(postMemberCount)
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
        view.setAccessibilityLabel(
            gridCellAccessibilityLabel(for: detail, postMemberCount: postMemberCount))

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
        updateScrim()
        selectionRingLayer.isHidden = !state.isSelected
        selectionRingLayer.borderWidth = state.isSelected ? selectionRingWidth : 0
        let showCursor = state.isCursor && !state.isSelected
        cursorRingLayer.isHidden = !showCursor
        cursorRingLayer.borderWidth = showCursor ? cursorRingWidth : 0
        // The hairline backs EITHER ring, so its inset has to be re-derived here —
        // `activeRingWidth` reads `currentSelection`, which this method just set.
        let showHairline = state.isSelected || showCursor
        selectionContrastLayer.isHidden = !showHairline
        selectionContrastLayer.borderWidth = showHairline ? contrastHairlineWidth : 0
        layOutContrastHairline(in: view.bounds)
        // The dashed same-post ring never competes with the selection ring: a
        // SELECTED cell already draws the solid border, so the sibling cue is only
        // for the members still to be picked up.
        siblingRingLayer.isHidden = !(state.isPostSibling && !state.isSelected)
        CATransaction.commit()
        // Selected: a palette checkmark (BLACK tick on a WHITE-filled circle) so the
        // tick has intrinsic contrast on any image, unlike a monochrome tint whose
        // knocked-out check reads the backing photo. Unselected: the empty ring stays
        // white (its halo carries it against pale images).
        if state.isSelected {
            let config = NSImage.SymbolConfiguration(
                paletteColors: [.black, Theme.NS.selectionMark])
            circleButton.image = NSImage(
                systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            circleButton.contentTintColor = nil
        } else {
            circleButton.image = NSImage(
                systemSymbolName: "circle", accessibilityDescription: nil)
            circleButton.contentTintColor = .white
        }
        updateCircleVisibility()
    }

    /// Paint (or clear) the carousel chip. Layer-only, like every other cell
    /// state: the artwork is a cached pixmap keyed on the count, so a scroll
    /// through a feed of carousels re-uses one image per distinct length.
    private func setPostMemberCount(_ count: Int) {
        postMemberCount = count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let badge = PostBadge.image(count: count) {
            postBadgeLayer.contents = badge
            postBadgeLayer.frame = NSRect(
                x: view.bounds.minX + PostBadge.inset, y: view.bounds.minY + PostBadge.inset,
                width: badge.size.width, height: badge.size.height)
            postBadgeLayer.isHidden = false
        } else {
            postBadgeLayer.contents = nil
            postBadgeLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Show/hide the enter-selection circle (idle-hover half — 036 §4 A2). Layer-
    /// only, like ``applySelectionState``; the coordinator drives it from its one
    /// tracking area, replacing the SwiftUI per-cell `.onHover` (and its
    /// `hoverAfterWindowChange` stranded-circle workaround).
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateScrim()
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
        setPostMemberCount(0)
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
            image == nil ? Theme.NS.mediaBackdrop.cgColor : NSColor.clear.cgColor
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
