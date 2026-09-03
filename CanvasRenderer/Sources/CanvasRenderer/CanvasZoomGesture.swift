import CoreGraphics

/// The accumulator behind one pinch (018 · C7 / [086](../../../.docs/086-canvas-pinch-smoothing-plan.md)).
///
/// A trackpad delivers `magnify` events faster than the display refreshes, and the
/// old path answered each one with a full ``CanvasEngine/sync()`` — cull, relayout,
/// re-tier, re-rasterize every glyph — whether or not a frame was ever going to be
/// drawn from it. This type is the seam that lets those events be *gathered* instead
/// of *served*: the host accumulates into it as they arrive and commits once per
/// vsync.
///
/// Pure and window-free, like ``CanvasTransform`` and ``CanvasSnapping``, so the
/// arithmetic that could be wrong is testable without an `NSEvent` — which a
/// `swift test` process has no way to make.
///
/// Zoom composes by MULTIPLICATION (`zoomed(by:)` is `scale × factor`), so a batch
/// of events collapses to the product of their factors and committing that product
/// once is exactly equivalent to committing each in turn. That equivalence is the
/// whole licence for the coalescing, and `CanvasPinchTests` pins it.
public struct CanvasZoomGesture: Equatable, Sendable {
    /// The screen point the zoom is anchored on — the world point under it stays
    /// visually fixed for the whole gesture.
    ///
    /// Captured once at `.began` and never updated, even though later events carry
    /// their own locations. A pinch's fingers drift, and re-anchoring per event would
    /// let the content slide under them: each event would hold a *different* world
    /// point still, which reads as the board wandering while you zoom.
    public let anchor: CGPoint

    /// The product of every factor accepted but not yet committed to the transform.
    /// `1` means nothing is outstanding.
    public private(set) var pendingFactor: CGFloat = 1

    /// The product of every factor already committed — introspection for the tests,
    /// and the value a band rule would read if the gesture ever grows one (086 ·
    /// Phase 2).
    public private(set) var committedFactor: CGFloat = 1

    public init(anchor: CGPoint) {
        self.anchor = anchor
    }

    /// The gesture's total magnification so far, committed and pending together.
    public var totalFactor: CGFloat { committedFactor * pendingFactor }

    /// Fold one event's factor in. Returns whether it was accepted.
    ///
    /// A factor must be finite and `> 0`. `NSEvent.magnification` is a delta added to
    /// 1, so a hardware glitch reporting ≤ −1 would yield a factor of zero or less:
    /// zero collapses the transform to `minScale` and negative mirrors the board.
    /// Both are silently discarded here rather than defended against downstream,
    /// because this is the one place every factor passes through.
    @discardableResult
    public mutating func accumulate(_ factor: CGFloat) -> Bool {
        guard factor.isFinite, factor > 0 else { return false }
        pendingFactor *= factor
        return true
    }

    /// Take the outstanding factor and clear it, moving it into ``committedFactor``.
    /// Returns `nil` when nothing is outstanding, so a caller can skip the work
    /// entirely — a vsync during a pause in the gesture must cost nothing.
    public mutating func takePending() -> CGFloat? {
        guard pendingFactor != 1 else { return nil }
        let factor = pendingFactor
        pendingFactor = 1
        committedFactor *= factor
        return factor
    }

    /// Whether this gesture has moved the camera at all — committed or pending.
    /// A pinch that begins and ends without motion (a two-finger rest) must leave no
    /// trace: no sync, no camera write, no notification.
    public var hasMoved: Bool { totalFactor != 1 }
}

/// What one scroll-wheel event means (099 · P12).
///
/// A wheel event is two different gestures wearing one `NSEvent`: bare, it pans;
/// with ⌘ held, it zooms about the cursor. Naming the decision as a value — rather
/// than branching inside `scrollWheel(with:)` — is what makes it testable at all: a
/// `swift test` process cannot synthesize an `NSEvent`, which is the same reason the
/// pinch's bracket lives on ``CanvasEngine`` rather than on the view (086).
public enum CanvasScrollIntent: Equatable, Sendable {
    /// Move the camera by a screen-space delta.
    case pan(CGSize)
    /// Multiply the camera's scale about the cursor.
    case zoom(CGFloat)
}

extension CanvasZoomGesture {

    /// Per-unit exponent for a PRECISE (trackpad) scroll delta.
    ///
    /// Precise deltas arrive in screen points and in the tens per event, so the
    /// exponent is small: a 100pt two-finger sweep lands on `e ≈ 2.72×`, which is
    /// about one full zoom step for a deliberate gesture.
    public static let preciseWheelExponent: CGFloat = 0.01

    /// Per-unit exponent for a LINE-BASED (mouse wheel) scroll delta.
    ///
    /// A notch reports 1 line on most mice and 3 on some, so this is chosen to keep
    /// BOTH usable: 1.05× and 1.16× respectively. Tuned against the line count rather
    /// than the notch because AppKit gives us the former and never the latter.
    public static let lineWheelExponent: CGFloat = 0.05

    /// The largest exponent a single event may contribute, either way.
    ///
    /// A wheel delta is hardware-reported and unbounded; without this a spurious
    /// 10,000-point event would produce `e^100`, which overflows to infinity and is
    /// then silently discarded by ``accumulate(_:)`` — a zoom that does nothing at
    /// all. Clamping instead means a huge event zooms a lot, which is at least the
    /// direction the user asked for. `1.6` is ~5× per event.
    public static let maxWheelExponent: CGFloat = 1.6

    /// The multiplicative factor one wheel event contributes.
    ///
    /// **Exponential, not linear**, and that is the load-bearing choice. Zoom composes
    /// by multiplication (``accumulate(_:)`` takes a product), so the only rule under
    /// which scrolling up by `d` and back down by `d` returns to the scale you started
    /// at is `f(-d) == 1 / f(d)` — which `exp` gives for free and `1 + kd` does not.
    /// A linear factor drifts smaller on every up-down pair, and the drift is
    /// invisible per event and obvious after a minute of use.
    ///
    /// Returns `1` (a no-op factor) for a non-finite delta, so a garbage event cannot
    /// reach the transform.
    public static func wheelZoomFactor(
        scrollDeltaY delta: CGFloat, precise: Bool
    ) -> CGFloat {
        guard delta.isFinite else { return 1 }
        let perUnit = precise ? preciseWheelExponent : lineWheelExponent
        let exponent = min(max(delta * perUnit, -maxWheelExponent), maxWheelExponent)
        return CGFloat(exp(Double(exponent)))
    }

    /// What a scroll event should do: pan when bare, zoom about the cursor with ⌘.
    ///
    /// ⌘ rather than a preference, because it is what every canvas tool on this
    /// platform uses and because the bare wheel must stay a pan — that is the gesture
    /// the board has always had, and re-binding it would be a regression wearing a
    /// feature's name.
    public static func scrollIntent(
        commandHeld: Bool, scrollDeltaX dx: CGFloat, scrollDeltaY dy: CGFloat,
        precise: Bool
    ) -> CanvasScrollIntent {
        guard commandHeld else { return .pan(CGSize(width: dx, height: dy)) }
        return .zoom(wheelZoomFactor(scrollDeltaY: dy, precise: precise))
    }
}
