//
//  GridMarquee.swift
//  AtelierRefs
//
//  009 — the display-synced scroll pump (`DisplayLinkPump`) that the grid's
//  marquee edge auto-scroll steps from. The SwiftUI marquee machinery that once
//  lived here — `GridMarqueeState`, the `MarqueeCaptureLayer` gesture surface,
//  the `MarqueeRectangleLayer` overlay, and the `DisplayLinkHost` that vended the
//  link for them — was retired with the SwiftUI grid (189). The AppKit
//  `GridMarqueeController` now owns the marquee and sets `pump.hostView` to the
//  collection view directly, so only the pump itself remains here.
//

import AppKit
import QuartzCore

/// A display-synced scroll pump. On macOS a `CADisplayLink` must be vended by an
/// `NSView`/`NSWindow`/`NSScreen` (unlike iOS's free-standing initializer), so the
/// owner sets `hostView` to a live view. Each fire reports the frame's real
/// duration (`targetTimestamp − timestamp`) so callers step by pt/sec × dt —
/// smooth at any refresh rate, unlike a fixed-delta wall-clock timer.
@MainActor
final class DisplayLinkPump {
    /// The view whose display the link syncs to — set by the owner
    /// (`GridMarqueeController` points it at the collection view).
    weak var hostView: NSView?
    /// Called on each vsync with the frame duration in seconds. `@MainActor` so the
    /// captured closure can touch view state directly.
    var onTick: (@MainActor (CFTimeInterval) -> Void)?

    private var link: CADisplayLink?

    /// Start the link if not already running and a host view is available. `.common`
    /// runloop mode so it isn't starved while the drag gesture tracks the mouse.
    func start() {
        guard link == nil, let hostView else { return }
        let link = hostView.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc nonisolated private func step(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        // The link fires on the main runloop; hop back into isolation to call out.
        MainActor.assumeIsolated { onTick?(dt) }
    }
}
