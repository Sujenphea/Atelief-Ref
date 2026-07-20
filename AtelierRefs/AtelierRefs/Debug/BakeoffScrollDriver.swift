//
//  BakeoffScrollDriver.swift
//  AtelierRefs
//
//  037 — the scripted scroll that makes the three grid implementations
//  COMPARABLE.
//
//  The whole point of the bake-off is a like-for-like number, and a
//  hand-performed scroll cannot deliver one: trackpad momentum differs run to
//  run, so a "faster" implementation may simply have been scrolled more gently.
//  Any difference under 20% would be noise, which is precisely the range the
//  1–2 week decision (035 §5) turns on.
//
//  So the scroll is SCRIPTED: offset ramps 0 → travel over a fixed duration at
//  CONSTANT velocity, stepped once per display-link tick. Identical distance,
//  identical velocity, identical frame cadence for all three grids — the only
//  variable left is the implementation.
//
//  Constant velocity (not eased) on purpose: an ease-out spends its final
//  seconds nearly stationary, where every grid trivially hits 8ms, diluting the
//  averages with frames that discriminate nothing. A constant ramp keeps the
//  grid under uniform load for the whole run, so every sampled frame carries
//  signal.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - The target seam

/// What the driver needs from a grid in order to scroll it (037).
///
/// Deliberately the smallest possible surface — a content extent and a way to
/// set the offset — because it must be satisfiable by BOTH a SwiftUI
/// `ScrollView` (via `ScrollPosition.scrollTo(y:)`) and an AppKit
/// `NSScrollView` (via `NSClipView.scroll(to:)`). Anything richer would have
/// bound the protocol to one framework's scrolling model and defeated the
/// comparison.
///
/// `AnyObject` because the driver holds the target across an async run and must
/// see the live view's geometry, not a snapshot of a value type.
@MainActor
protocol BakeoffScrollTarget: AnyObject {
    /// The full scrollable content height in points — the masonry
    /// `contentHeight`, NOT the viewport.
    var contentHeight: CGFloat { get }
    /// The visible viewport height in points.
    ///
    /// Beyond the protocol sketch on purpose, and load-bearing: the maximum
    /// reachable offset is `contentHeight − viewportHeight`, not `contentHeight`.
    /// Ramping to the full content height would leave the last viewport-worth of
    /// the run pinned against the bottom stop with the grid STATIONARY, and
    /// stationary frames are ~free. A tall-viewport run would then look better
    /// than a short-viewport one purely from a longer idle tail. Ramping to the
    /// true travel keeps every frame a scrolling frame.
    var viewportHeight: CGFloat { get }
    /// Scroll so the content offset's y is `y`, UNANIMATED.
    ///
    /// Animation is the caller's enemy here: an animated scroll would let the
    /// framework interpolate on its own clock and the measured cadence would be
    /// the animator's, not the driver's.
    func setScrollOffset(_ y: CGFloat)
}

// MARK: - The driver

/// Runs one scripted scroll while a ``FrameTimeRecorder`` samples it (037).
///
/// Driver and recorder share ONE display link — the recorder's. The offset step
/// therefore happens in the same callback that closes each frame's measurement,
/// so a step can never land between two sampled frames and pair a scroll
/// distance with the wrong interval.
@MainActor
final class BakeoffScrollDriver {
    /// How long a run takes, in seconds. 10s at the default is long enough for a
    /// 2000-item grid to cross many band boundaries (035 §4 — the hitch is
    /// per-screenful, so a short run could miss them or catch an unrepresentative
    /// number) while staying short enough to iterate on.
    static let defaultDuration: TimeInterval = 10

    private(set) var isRunning = false

    /// Scroll `target` from offset 0 to its full travel over `duration`, with
    /// `recorder` sampling every frame, and return the run's statistics.
    ///
    /// Returns ``FrameTimeStats/empty`` immediately if the target has no travel
    /// (an empty or short collection) — a run over nothing produces a flattering
    /// all-idle number that must never be mistaken for a result.
    @discardableResult
    func run(
        target: BakeoffScrollTarget,
        recorder: FrameTimeRecorder,
        duration: TimeInterval = BakeoffScrollDriver.defaultDuration
    ) async -> FrameTimeStats {
        guard !isRunning else { return .empty }
        let travel = max(0, target.contentHeight - target.viewportHeight)
        guard travel > 0, duration > 0 else { return .empty }

        isRunning = true
        defer { isRunning = false }

        // Start from a known offset so every run covers the SAME span. A run
        // begun wherever the user left the grid would scroll a different
        // distance and be incomparable.
        target.setScrollOffset(0)

        var elapsed: TimeInterval = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Resumed exactly once, from the tick that crosses `duration`.
            var didFinish = false
            recorder.onFrame = { [weak target] dt in
                guard !didFinish, let target else { return }
                // Integrate the frame's REAL duration rather than counting ticks:
                // on a 120Hz panel a tick is 8.3ms and on 60Hz it is 16.7ms, so a
                // fixed per-tick delta would scroll a ProMotion display twice as
                // far in the same wall-clock time and the two machines' runs
                // would not be comparable.
                elapsed += dt
                let progress = min(elapsed / duration, 1)
                target.setScrollOffset(travel * CGFloat(progress))
                if progress >= 1 {
                    didFinish = true
                    continuation.resume()
                }
            }
            recorder.start()
        }

        recorder.onFrame = nil
        return recorder.stop()
    }
}

// MARK: - A ready-made SwiftUI conformance

/// A ``BakeoffScrollTarget`` backed by SwiftUI's `ScrollPosition` (037) —
/// supplied here so BOTH SwiftUI bake-off entries drive scroll IDENTICALLY
/// instead of each inventing its own mechanism (which would reintroduce exactly
/// the variability the scripted scroll exists to remove).
///
/// This works, and is not speculative: the shipping grid already scrolls itself
/// programmatically through `ScrollPosition.scrollTo(y:)` for the marquee's edge
/// auto-scroll (`CollectionView.swift` → `onAutoScroll: { gridScroll.scrollTo(y: $0) }`),
/// which produces real, geometry-reported scrolling at up to 1080 pt/s. The
/// bake-off drives the same call.
///
/// Why closures rather than a stored `Binding`: `ScrollPosition` lives in the
/// grid view's `@State` and can only be mutated from that view. The view
/// REFRESHES these closures on each body pass — the same discipline
/// `MarqueeCaptureLayer` uses for `pump.onTick`. Everything they capture is a
/// stable reference, so a closure one render stale stays correct.
@MainActor
final class SwiftUIScrollPositionTarget: BakeoffScrollTarget {
    /// Refreshed by the grid view from its layout each body pass.
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// Set by the grid view to `{ scrollPosition.scrollTo(y: $0) }`.
    var scrollTo: (@MainActor (CGFloat) -> Void)?

    func setScrollOffset(_ y: CGFloat) { scrollTo?(y) }
}

/// A ``BakeoffScrollTarget`` backed by an AppKit `NSScrollView` (037) —
/// supplied so the AppKit entry needs no scrolling code of its own and is
/// driven on exactly the same contract as the SwiftUI ones.
///
/// Scrolls the CLIP VIEW directly (`scroll(to:)` + `reflectScrolledClipView`)
/// rather than `NSView.scroll(_:)`: the clip-view call is the unanimated one,
/// and the explicit reflect keeps the scroller and any bounds observers in sync
/// — without it the grid moves but `boundsDidChange` observers (which a
/// recycling implementation may depend on for its visible-rect updates) can miss
/// the step, quietly measuring a grid that never restocked its cells.
@MainActor
final class NSScrollViewBakeoffTarget: BakeoffScrollTarget {
    private let scrollView: NSScrollView

    init(scrollView: NSScrollView) { self.scrollView = scrollView }

    var contentHeight: CGFloat { scrollView.documentView?.frame.height ?? 0 }
    var viewportHeight: CGFloat { scrollView.contentView.bounds.height }

    func setScrollOffset(_ y: CGFloat) {
        // `documentVisibleRect.origin.x` preserved so a horizontal position (the
        // masonry grid has none, but a future variant might) is not reset.
        let x = scrollView.contentView.bounds.origin.x
        scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
