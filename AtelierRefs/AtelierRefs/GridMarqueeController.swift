//
//  GridMarqueeController.swift
//  AtelierRefs
//
//  036 §4 A3 — the AppKit peer of `GridMarquee`'s `MarqueeCaptureLayer` /
//  `MarqueeRectangleLayer`, for the `NSCollectionView` grid. It KEEPS the proven
//  pure pieces verbatim — `marqueeRect`, `masonryMarqueeIndices` (via
//  ``marqueeHitIDs``), the `.marquee(hits:base:)` reducer action, and the
//  `DisplayLinkPump` velocity-ramped edge auto-scroll — and only moves the
//  event + drawing layer:
//
//   • `mouseDown` on EMPTY space (a cell intercepts its own down) begins the box;
//     a bare (un-⇧) click that never drags CLEARS the selection — the A2-deferred
//     click-to-clear, matching the SwiftUI tap gesture's `guard !shift; onClear()`.
//   • `mouseDragged` recomputes the hit set and redraws per tick.
//   • The rectangle is ONE flipped, hit-transparent overlay view whose single
//     `CALayer` is mutated inside a `CATransaction` (no view rebuilds). It is a
//     subview of the collection view, so its `frame` is content space top-left —
//     the SAME space the item views are placed in (their frames ARE the analytic
//     frames), so the rect aligns with cells with zero conversion and no reliance
//     on layer `isGeometryFlipped` (the flipped-coordinate trap §A-risks warns
//     about). It composites above the items and scrolls with the grid; it exists
//     only during an active drag, when no reload touches the subview tree.
//   • Edge auto-scroll reuses ``DisplayLinkPump`` — the SAME pt/sec × frame-dt ramp
//     as the SwiftUI marquee, so it stays smooth at any refresh rate. Native rubber
//     band stays off (`NSCollectionView.isSelectable = false`).
//
//  Hit-testing rides the ANALYTIC frames the coordinator vends (`layout.solvedFrames`
//  / `solvedColumns`), NEVER the pixel-snapped live cell frames (038 §3.4).
//

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class GridMarqueeController {
    private weak var collectionView: MasonryNSCollectionView?
    /// The display-synced auto-scroll pump (KEPT from A-side; A4 deletes the SwiftUI
    /// hosts but not this). Vends its `CADisplayLink` off the collection view.
    private let pump = DisplayLinkPump()

    // MARK: Coordinator-supplied inputs (analytic geometry + reducer seams)

    /// The item ids in feed order — hit indices map back through this.
    var itemIDs: () -> [UUID] = { [] }
    /// The full analytic frame array (offscreen included) — the virtualization trap
    /// means live cell frames can't drive offscreen hit-testing (038 §3.4).
    var frames: () -> [CGRect] = { [] }
    /// The round-robin column count the frames were solved for.
    var columns: () -> Int = { 1 }
    /// The selection as of now — the ⇧-additive base source at drag start.
    var currentSelectionIDs: () -> Set<UUID> = { [] }
    /// Apply the marquee hit set through the reducer (`.marquee(hits:base:)`).
    var onMarquee: (_ hits: Set<UUID>, _ base: Set<UUID>) -> Void = { _, _ in }
    /// Clear the selection (a bare background click — the A2-deferred click-to-clear).
    var onClear: () -> Void = {}

    // MARK: Live drag state (content space)

    private var start: CGPoint?
    private var current: CGPoint?
    /// The selection captured at drag start (empty for a plain marquee, the prior
    /// selection for a ⇧-additive one).
    private var base: Set<UUID> = []
    private var shiftAtStart = false
    /// Whether the pointer has crossed the drag threshold — below it a mouse-up is a
    /// CLICK (clear), at/above it the gesture is a marquee.
    private var dragged = false

    /// The single rectangle overlay view, created lazily on the first drag tick and
    /// removed on end. A subview (not a raw sublayer) so its frame is unambiguously
    /// content-space top-left, matching the item views.
    private var rectView: MarqueeRectView?

    /// The drag threshold, matching the SwiftUI `DragGesture(minimumDistance: 6)` so
    /// a small jitter still reads as a click-to-clear, not a marquee.
    private static let threshold: CGFloat = 6
    /// Edge zone + speed ramp (pt/sec), identical to `MarqueeCaptureLayer`.
    private static let edgeZone: CGFloat = 28
    private static let minSpeed: CGFloat = 180
    private static let maxSpeed: CGFloat = 1080

    init(collectionView: MasonryNSCollectionView) {
        self.collectionView = collectionView
        pump.hostView = collectionView
    }

    // MARK: Event entry points (called by the coordinator's background mouse handlers)

    func mouseDown(at point: CGPoint, shiftKey: Bool) {
        start = point
        current = point
        shiftAtStart = shiftKey
        base = shiftKey ? currentSelectionIDs() : []
        dragged = false
    }

    func mouseDragged(to point: CGPoint) {
        guard let start else { return }
        current = point
        if !dragged {
            let dx = point.x - start.x, dy = point.y - start.y
            if (dx * dx + dy * dy) >= Self.threshold * Self.threshold { dragged = true }
        }
        guard dragged else { return }
        updateHits()
        drawRect()
        updateAutoScroll()
    }

    func mouseUp() {
        // A bare (un-⇧) click on empty space clears; a ⇧-click never does (parity
        // with the SwiftUI `TapGesture`'s `guard !shift`). A real drag committed its
        // hits on the way and clears nothing.
        if !dragged, !shiftAtStart { onClear() }
        end()
    }

    /// Tear-down entry point (host dismantle) — stop the pump and drop the layer.
    func cancel() { end() }

    private func end() {
        stopAutoScroll()
        start = nil
        current = nil
        base = []
        dragged = false
        removeRect()
    }

    // MARK: Hits + rectangle

    private func updateHits() {
        guard let start, let current else { return }
        let rect = marqueeRect(from: start, to: current)
        onMarquee(
            marqueeHitIDs(rect: rect, frames: frames(), columns: columns(), itemIDs: itemIDs()),
            base)
    }

    /// Draw / move the ONE overlay view in content space, actions disabled so a
    /// per-tick frame change never implicitly animates. Created on first use as a
    /// frontmost subview so it sits above the item views.
    private func drawRect() {
        guard let start, let current, let collectionView else { return }
        let rect = marqueeRect(from: start, to: current)
        let view = rectView ?? makeRectView(in: collectionView)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = rect
        CATransaction.commit()
    }

    private func makeRectView(in collectionView: NSCollectionView) -> MarqueeRectView {
        let view = MarqueeRectView(frame: .zero)
        // Frontmost so it composites above the item views (which are subviews too).
        collectionView.addSubview(view, positioned: .above, relativeTo: nil)
        rectView = view
        return view
    }

    private func removeRect() {
        rectView?.removeFromSuperview()
        rectView = nil
    }

    // MARK: Edge auto-scroll (reuses DisplayLinkPump's velocity ramp)

    /// The visible viewport in CONTENT space — the flipped clip view's bounds
    /// (origin = scroll offset).
    private func visibleRect() -> CGRect? {
        collectionView?.enclosingScrollView?.contentView.bounds
    }

    /// The full content height — the (flipped) document view's own height, which the
    /// scroll view sizes to `collectionViewContentSize`.
    private func contentHeight() -> CGFloat {
        collectionView?.frame.height ?? 0
    }

    private func updateAutoScroll() {
        guard let current, let visible = visibleRect(), visible.height > 0 else { return }
        let pointerY = current.y - visible.minY
        let inZone = pointerY < Self.edgeZone || pointerY > visible.height - Self.edgeZone
        if inZone { startAutoScroll() } else { stopAutoScroll() }
    }

    private func startAutoScroll() {
        pump.onTick = { [weak self] dt in self?.tick(dt: dt) }
        pump.start()
    }

    private func stopAutoScroll() { pump.stop() }

    /// One auto-scroll step: velocity (pt/sec) from the pointer's penetration into
    /// the edge zone, integrated over the frame's real duration `dt` and clamped to
    /// the content bounds. The content scrolls under a stationary pointer, so the
    /// pointer's CONTENT-space y advances by the same delta — apply it to `current`
    /// and recompute hits (no `mouseDragged` fires without real mouse movement).
    private func tick(dt: CFTimeInterval) {
        guard let current, let scrollView = collectionView?.enclosingScrollView,
              let visible = visibleRect(), visible.height > 0 else {
            stopAutoScroll()
            return
        }
        let pointerY = current.y - visible.minY
        let velocity: CGFloat   // pt/sec, signed by scroll direction
        if pointerY < Self.edgeZone {
            velocity = -Self.scrollSpeed(penetration: Self.edgeZone - pointerY)
        } else if pointerY > visible.height - Self.edgeZone {
            velocity = Self.scrollSpeed(penetration: pointerY - (visible.height - Self.edgeZone))
        } else {
            stopAutoScroll()
            return
        }
        let maxOffset = max(0, contentHeight() - visible.height)
        let target = min(max(visible.minY + velocity * CGFloat(dt), 0), maxOffset)
        let delta = target - visible.minY
        guard abs(delta) > 0.01 else { return }   // pinned at a content bound
        self.current?.y += delta
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateHits()
        drawRect()
    }

    /// Velocity ramp (pt/sec): penetration 0 → `minSpeed`, full zone depth (or past
    /// the viewport edge entirely) → `maxSpeed`. Identical to `MarqueeCaptureLayer`.
    private static func scrollSpeed(penetration: CGFloat) -> CGFloat {
        let t = min(max(penetration / edgeZone, 0), 1)
        return minSpeed + t * (maxSpeed - minSpeed)
    }
}

/// The translucent marquee rectangle (036 §4 A3) — a flipped, hit-transparent
/// overlay so it never steals the drag's mouse events and its frame reads as
/// content-space top-left (matching the item views). Draws entirely via its layer;
/// the accent stroke + fill mirror the SwiftUI `MarqueeRectangleLayer`.
private final class MarqueeRectView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
