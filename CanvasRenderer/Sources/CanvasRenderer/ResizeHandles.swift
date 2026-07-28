//
//  ResizeHandles.swift
//  CanvasRenderer
//
//  062 — the eight grab points on a selected box, and the arithmetic that turns a
//  handle drag into a new frame. Pure and domain-free: hit-testing happens in
//  SCREEN space (a grab zone must stay the same physical size at every zoom) while
//  the resulting frame is computed in WORLD space (the geometry that gets
//  persisted). Keeping those two spaces explicit is the same split 060 settled for
//  text — the bug it prevents is a handle that becomes impossible to grab when you
//  zoom out, or a box that resizes at the wrong rate when you zoom in.
//

import CoreGraphics

/// One of the eight grab points on a selected box. Corners move two edges, sides
/// move one.
public enum ResizeHandle: String, Sendable, Equatable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    /// A corner moves one horizontal AND one vertical edge.
    public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

/// Handle placement, hit-testing, and resize arithmetic. All static + pure.
public enum ResizeGeometry {
    /// Drawn size of a handle dot, in SCREEN points.
    public static let handleSize: CGFloat = 8

    /// The grab zone around a handle, in SCREEN points — deliberately much larger
    /// than the dot so a handle is easy to catch without pixel-hunting.
    public static let handleHitSize: CGFloat = 22

    /// The grab zone for the box currently being EDITED, in screen points.
    ///
    /// Smaller than ``handleHitSize`` because the two gestures want opposite things
    /// from the same pixels. Resizing a box while editing it is deliberate (062), so
    /// the handles cannot simply be switched off — but a text box is short, and a 22pt
    /// zone reaching 11pt in from every edge would leave a 16pt box with almost no
    /// interior for the caret. 10pt keeps every handle catchable while leaving the
    /// middle of the box to the text.
    public static let editingHitSize: CGFloat = 10

    /// Smallest world edge a resize may produce. Also the floor that keeps a text
    /// box's wrap width from collapsing toward zero.
    public static let minWorldSize: CGFloat = 24

    /// The centre point of each handle on a screen-space box, in a stable order.
    public static func handleCentres(in frame: CGRect) -> [(handle: ResizeHandle, centre: CGPoint)] {
        [
            (.topLeft, CGPoint(x: frame.minX, y: frame.minY)),
            (.top, CGPoint(x: frame.midX, y: frame.minY)),
            (.topRight, CGPoint(x: frame.maxX, y: frame.minY)),
            (.right, CGPoint(x: frame.maxX, y: frame.midY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.maxY)),
            (.bottom, CGPoint(x: frame.midX, y: frame.maxY)),
            (.bottomLeft, CGPoint(x: frame.minX, y: frame.maxY)),
            (.left, CGPoint(x: frame.minX, y: frame.midY)),
        ]
    }

    /// The handle under `point`, or `nil` when the point misses every grab zone.
    /// Both are in SCREEN space, so the zone stays a constant physical size at any
    /// zoom.
    ///
    /// **Corners win.** They are tested first, over a square zone, so the ambiguous
    /// region where a corner's zone overlaps an edge's band resolves to the corner —
    /// the handle that does strictly more, and the one a user aiming at a corner
    /// meant. Each edge band then excludes the corner zones outright, so the two
    /// never disagree.
    public static func handle(
        atScreenPoint point: CGPoint,
        in frame: CGRect,
        hitSize: CGFloat = handleHitSize
    ) -> ResizeHandle? {
        let half = max(0, hitSize) / 2
        for (handle, centre) in handleCentres(in: frame) where handle.isCorner {
            if abs(point.x - centre.x) <= half, abs(point.y - centre.y) <= half { return handle }
        }
        // Edge bands, with the corner zones carved out. On a box narrower/shorter
        // than one grab zone these ranges invert and no edge can hit — corners only,
        // which is the sane outcome for a box smaller than its own handles.
        let xLo = frame.minX + half, xHi = frame.maxX - half
        let yLo = frame.minY + half, yHi = frame.maxY - half
        if abs(point.x - frame.minX) <= half, point.y >= yLo, point.y <= yHi { return .left }
        if abs(point.x - frame.maxX) <= half, point.y >= yLo, point.y <= yHi { return .right }
        if abs(point.y - frame.minY) <= half, point.x >= xLo, point.x <= xHi { return .top }
        if abs(point.y - frame.maxY) <= half, point.x >= xLo, point.x <= xHi { return .bottom }
        return nil
    }

    /// The new WORLD frame produced by dragging `handle` of `frame` to `world`.
    ///
    /// Only the edges the handle owns move; the opposite edges are anchored, which
    /// is what makes a resize feel like it pivots about the corner you are not
    /// holding. Each moving edge is clamped so it can never cross (or come within
    /// `minSize` of) its anchor, so a fast drag past the far side yields a
    /// `minSize` box rather than a negative one.
    ///
    /// With `keepRatio` the box is locked to `aspect` (width ÷ height): a corner
    /// scales about the opposite corner, and a side handle takes its length from the
    /// cursor while the perpendicular dimension follows the ratio, centred — so the
    /// box grows symmetrically rather than lurching to one side.
    public static func resizedFrame(
        _ frame: CGRect,
        handle: ResizeHandle,
        toWorldPoint world: CGPoint,
        keepRatio: Bool = false,
        aspect: CGFloat = 1,
        minSize: CGFloat = minWorldSize
    ) -> CGRect {
        let minSize = max(0, minSize)
        let aspect = max(aspect, 0.0001)

        if keepRatio {
            if handle.isCorner {
                // Anchor at the opposite corner and grow toward the cursor.
                let anchor = CGPoint(
                    x: handle.movesLeft ? frame.maxX : frame.minX,
                    y: handle.movesTop ? frame.maxY : frame.minY)
                return aspectRect(anchor: anchor, to: world, aspect: aspect, minSize: minSize)
            }
            if handle.movesLeft || handle.movesRight {
                // Width from the cursor, opposite edge fixed, centred vertically.
                let fixedX = handle.movesLeft ? frame.maxX : frame.minX
                var w = max(abs(world.x - fixedX), minSize)
                var h = w / aspect
                if h < minSize { h = minSize; w = h * aspect }
                return CGRect(
                    x: handle.movesLeft ? fixedX - w : fixedX,
                    y: frame.midY - h / 2, width: w, height: h)
            }
            // Height from the cursor, opposite edge fixed, centred horizontally.
            let fixedY = handle.movesTop ? frame.maxY : frame.minY
            var h = max(abs(world.y - fixedY), minSize)
            var w = h * aspect
            if w < minSize { w = minSize; h = w / aspect }
            return CGRect(
                x: frame.midX - w / 2,
                y: handle.movesTop ? fixedY - h : fixedY, width: w, height: h)
        }

        var minX = frame.minX, maxX = frame.maxX
        var minY = frame.minY, maxY = frame.maxY
        if handle.movesLeft { minX = min(world.x, maxX - minSize) }
        if handle.movesRight { maxX = max(world.x, minX + minSize) }
        if handle.movesTop { minY = min(world.y, maxY - minSize) }
        if handle.movesBottom { maxY = max(world.y, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A rect anchored at `anchor`, sized toward `b` but locked to `aspect`
    /// (width ÷ height) and ENCLOSING the cursor offset — the larger of the two
    /// candidate dimensions wins, so the box always reaches the pointer on at least
    /// one axis rather than lagging behind it. The minimum is applied on whichever
    /// axis hits it first and then propagated through the ratio, so clamping can
    /// never distort the box.
    static func aspectRect(
        anchor: CGPoint, to b: CGPoint, aspect: CGFloat, minSize: CGFloat
    ) -> CGRect {
        let aspect = max(aspect, 0.0001)
        let dx = b.x - anchor.x, dy = b.y - anchor.y
        var w = abs(dx), h = abs(dy)
        if w / max(h, 0.0001) > aspect { h = w / aspect } else { w = h * aspect }
        if w < minSize { w = minSize; h = w / aspect }
        if h < minSize { h = minSize; w = h * aspect }
        return CGRect(
            x: dx < 0 ? anchor.x - w : anchor.x,
            y: dy < 0 ? anchor.y - h : anchor.y,
            width: w, height: h)
    }
}
