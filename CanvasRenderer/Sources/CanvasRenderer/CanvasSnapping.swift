//
//  CanvasSnapping.swift
//  CanvasRenderer
//
//  062 — snapping a resize to the boxes around it. Modelled on Nook's Easel: a
//  dragged edge that comes within a few points of another box's edge or centre
//  jumps to it exactly, and a guide line shows why.
//
//  The threshold is specified in SCREEN points and divided by the zoom by the
//  caller, so "a few points" means the same thing to the hand at every zoom — the
//  same world-vs-screen split the handles themselves use. Snapping at a fixed
//  WORLD distance would be unusably sticky zoomed out and imperceptible zoomed in.
//
//  Everything here is pure: candidates come in as plain rects, so none of it needs
//  a provider, a camera, or a view.
//

import CoreGraphics

/// A line the user is snapping to, in WORLD space. `isVertical` means a line of
/// constant *x* (it runs top-to-bottom), which is what a horizontal drag snaps to.
public struct SnapGuide: Equatable, Sendable {
    public let isVertical: Bool
    public let position: CGFloat

    public init(isVertical: Bool, position: CGFloat) {
        self.isVertical = isVertical
        self.position = position
    }
}

public enum CanvasSnapping {
    /// Snap radius in SCREEN points. Callers divide by the zoom to get world units.
    public static let thresholdScreen: CGFloat = 6

    /// The snap radius in WORLD units at `scale`. Guarded so a degenerate camera
    /// can't produce an infinite (snap-to-everything) threshold.
    public static func worldThreshold(
        scale: CGFloat, screenPoints: CGFloat = thresholdScreen
    ) -> CGFloat {
        screenPoints / max(scale, 0.01)
    }

    /// The coordinates a box may snap to on one axis: every candidate's leading
    /// edge, centre, and trailing edge. Centres are included so boxes can be lined
    /// up on their middles, not just their sides.
    static func targets(in rects: [CGRect], vertical: Bool) -> [CGFloat] {
        rects.flatMap { rect in
            vertical ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
        }
    }

    /// Pull the dragged point onto a nearby target, on whichever axes `handle`
    /// actually moves — a side handle must never snap on the axis it cannot change,
    /// or the box would drift sideways while you drag its bottom edge.
    ///
    /// The NEAREST target wins per axis, and the two axes resolve independently, so
    /// a corner can snap horizontally to one box and vertically to another.
    public static func snapPoint(
        _ world: CGPoint,
        handle: ResizeHandle,
        candidates: [CGRect],
        threshold: CGFloat
    ) -> (point: CGPoint, guides: [SnapGuide]) {
        let movesX = handle.movesLeft || handle.movesRight
        let movesY = handle.movesTop || handle.movesBottom
        var point = world
        var guides: [SnapGuide] = []

        if movesX, let hit = nearest(to: world.x, among: targets(in: candidates, vertical: true),
                                     threshold: threshold) {
            point.x = hit
            guides.append(SnapGuide(isVertical: true, position: hit))
        }
        if movesY, let hit = nearest(to: world.y, among: targets(in: candidates, vertical: false),
                                     threshold: threshold) {
            point.y = hit
            guides.append(SnapGuide(isVertical: false, position: hit))
        }
        return (point, guides)
    }

    /// The offset that snaps a MOVING bounding box onto nearby boxes.
    ///
    /// Richer than ``snapPoint(_:handle:candidates:threshold:)``, which aligns a
    /// single dragged corner: a move can align on any of the box's three lines per
    /// axis — leading edge, centre, trailing edge — against any of a candidate's
    /// three. That is what makes "line this up under that" and "centre it on that"
    /// both work from the same gesture.
    ///
    /// The smallest adjustment wins per axis, and the axes resolve independently, so
    /// a tile can align its left edge to one neighbour and its centre to another.
    /// Returns a **delta to add** to the drag's raw offset, not a position, so the
    /// caller stays in charge of how the offset was derived.
    public static func snapOffset(
        movingBox: CGRect,
        candidates: [CGRect],
        threshold: CGFloat
    ) -> (offset: CGSize, guides: [SnapGuide]) {
        var guides: [SnapGuide] = []
        var offset = CGSize.zero

        if let hit = bestAlignment(
            sources: [movingBox.minX, movingBox.midX, movingBox.maxX],
            targets: targets(in: candidates, vertical: true), threshold: threshold) {
            offset.width = hit.delta
            guides.append(SnapGuide(isVertical: true, position: hit.target))
        }
        if let hit = bestAlignment(
            sources: [movingBox.minY, movingBox.midY, movingBox.maxY],
            targets: targets(in: candidates, vertical: false), threshold: threshold) {
            offset.height = hit.delta
            guides.append(SnapGuide(isVertical: false, position: hit.target))
        }
        return (offset, guides)
    }

    /// The smallest in-range adjustment across every source×target pair, with the
    /// target it lands on (for the guide line).
    private static func bestAlignment(
        sources: [CGFloat], targets: [CGFloat], threshold: CGFloat
    ) -> (delta: CGFloat, target: CGFloat)? {
        var best: (delta: CGFloat, target: CGFloat)?
        for source in sources {
            for target in targets {
                let delta = target - source
                guard abs(delta) <= threshold else { continue }
                if best == nil || abs(delta) < abs(best!.delta) { best = (delta, target) }
            }
        }
        return best
    }

    /// Snap an ASPECT-LOCKED resize. The point can't simply be moved — that would
    /// break the ratio — so instead the frame is scaled UNIFORMLY about its anchor
    /// by whatever factor lands a moving edge on a target. The single best (nearest)
    /// snap across both axes wins, because applying two would need two different
    /// scales and there is only one.
    ///
    /// Returns `frame` untouched when nothing is near enough, or when the snap would
    /// drive the box below `minSize` — a snap must never be a way to violate the
    /// minimum.
    public static func snapAspectFrame(
        _ frame: CGRect,
        handle: ResizeHandle,
        candidates: [CGRect],
        threshold: CGFloat,
        minSize: CGFloat = ResizeGeometry.minWorldSize
    ) -> (frame: CGRect, guides: [SnapGuide]) {
        guard frame.width > 0, frame.height > 0 else { return (frame, []) }

        // The edge that stays put, and the one the user is dragging, per axis.
        let anchorX = handle.movesLeft ? frame.maxX : (handle.movesRight ? frame.minX : frame.midX)
        let anchorY = handle.movesTop ? frame.maxY : (handle.movesBottom ? frame.minY : frame.midY)
        let movingX: CGFloat? = handle.movesLeft ? frame.minX : (handle.movesRight ? frame.maxX : nil)
        let movingY: CGFloat? = handle.movesTop ? frame.minY : (handle.movesBottom ? frame.maxY : nil)

        var best: (scale: CGFloat, distance: CGFloat, guide: SnapGuide)?
        func consider(_ scale: CGFloat, _ distance: CGFloat, _ guide: SnapGuide) {
            guard scale > 0 else { return }
            if best == nil || distance < best!.distance { best = (scale, distance, guide) }
        }
        if let moving = movingX {
            for target in targets(in: candidates, vertical: true)
            where abs(target - moving) <= threshold {
                consider(abs(target - anchorX) / frame.width, abs(target - moving),
                         SnapGuide(isVertical: true, position: target))
            }
        }
        if let moving = movingY {
            for target in targets(in: candidates, vertical: false)
            where abs(target - moving) <= threshold {
                consider(abs(target - anchorY) / frame.height, abs(target - moving),
                         SnapGuide(isVertical: false, position: target))
            }
        }

        guard let best else { return (frame, []) }
        let w = frame.width * best.scale, h = frame.height * best.scale
        guard w >= minSize, h >= minSize else { return (frame, []) }
        return (
            CGRect(
                x: handle.movesLeft ? anchorX - w : (handle.movesRight ? anchorX : frame.midX - w / 2),
                y: handle.movesTop ? anchorY - h : (handle.movesBottom ? anchorY : frame.midY - h / 2),
                width: w, height: h),
            [best.guide])
    }

    /// The nearest target within `threshold`, or `nil`.
    private static func nearest(
        to value: CGFloat, among targets: [CGFloat], threshold: CGFloat
    ) -> CGFloat? {
        var best: CGFloat?
        var bestDistance = CGFloat.infinity
        for target in targets {
            let distance = abs(target - value)
            if distance <= threshold, distance < bestDistance {
                bestDistance = distance
                best = target
            }
        }
        return best
    }
}
