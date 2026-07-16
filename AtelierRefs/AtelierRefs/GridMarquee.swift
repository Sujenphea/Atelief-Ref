//
//  GridMarquee.swift
//  AtelierRefs
//
//  009 — the marquee's per-tick machinery, isolated from `CollectionView`. The
//  rubber-band updates 60–120×/sec while the mouse moves; when its state lived
//  as `@State` on the whole screen, every tick re-rendered the header, the drop
//  rail, and every visible cell's modifier chain (including an O(items) drag
//  payload per cell). Here only two tiny layers observe the per-tick state: the
//  capture layer under the grid (gesture + hit math) and the rectangle above it.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The live marquee drag: `start`/`current` in the grid's named CONTENT space,
/// plus the ⇧-captured base. A class held in plain `@State` by the parent —
/// deliberately NOT `@StateObject`, which would subscribe the whole
/// `CollectionView` to every tick and recreate exactly the churn this isolates.
final class GridMarqueeState: ObservableObject {
    @Published var start: CGPoint?
    @Published var current: CGPoint?
    /// The selection captured at drag start (empty for a plain marquee, the
    /// prior selection for a ⇧-additive one). No view draws it → not published.
    var base: Set<UUID> = []
    /// The visible viewport in CONTENT space (scroll offset + container size),
    /// fed by the parent's `onScrollGeometryChange`. The edge auto-scroll reads
    /// it to place the pointer relative to the viewport. Plain vars — no view
    /// draws them, so they must not publish (they change on every scroll tick).
    var visibleRect: CGRect = .zero
    var contentHeight: CGFloat = 0
}

/// The click/drag capture layer that sits UNDER the grid cells: a drag on empty
/// space is a marquee, a plain click clears the selection (⇧-click never does).
///
/// Scrolling mid-drag is EDGE AUTO-SCROLL (Finder's): while the drag is live
/// the ScrollView ignores trackpad pans (the drag gesture owns the event
/// stream), so when the pointer enters the viewport's top/bottom edge zone the
/// grid scrolls at a speed proportional to the penetration — unanimated, and
/// only at the edges. (The original per-tick animated `scrollTo` pinned a hit
/// cell to the viewport edge 60+×/sec regardless of pointer position — that was
/// the drag jag.)
///
/// The pump is a `CADisplayLink` (`DisplayLinkPump`), NOT a wall-clock `Timer`:
/// the old timer fired at a fixed 60Hz and advanced a fixed pt-per-tick delta, so
/// its jitter became velocity jitter and it drifted against a 120Hz ProMotion
/// vsync — the residual judder. The display link fires in lock-step with the
/// panel and reports each frame's real duration, so a pt/**sec** velocity × dt is
/// frame-accurate at any refresh rate.
struct MarqueeCaptureLayer: View {
    @ObservedObject var state: GridMarqueeState
    /// The item ids in feed order — hit indices map back through this.
    let itemIDs: [UUID]
    /// The masonry layout's frames (011-B1), index-aligned to `itemIDs`, computed
    /// (and memoized) by the parent. The virtualization trap: offscreen cells
    /// aren't laid out, so these COMPUTED frames — not live cell frames — drive
    /// hit-testing.
    let frames: [CGRect]
    /// The round-robin column count `C` the frames were laid out for (item
    /// `i` → column `i % C`); band-narrows the hit-test.
    let columns: Int
    let spaceName: String
    /// The selection as of the last parent render — the ⇧-additive base source.
    let selectionIDs: Set<UUID>
    let onMarquee: (_ hits: Set<UUID>, _ base: Set<UUID>) -> Void
    let onClear: () -> Void
    /// Scroll the grid to this content-space y offset (edge auto-scroll tick).
    let onAutoScroll: (_ offsetY: CGFloat) -> Void

    /// The display-synced auto-scroll pump. A class in plain `@State` (survives
    /// re-inits); vends its `CADisplayLink` from the host `NSView` installed by
    /// the background `DisplayLinkHost`.
    @State private var pump = DisplayLinkPump()

    /// The edge zone height and the speed ramp across it, in pt per SECOND
    /// (≈180 pt/s brushing the zone → ≈1080 pt/s pinned at the very edge). Per-sec,
    /// not per-tick, so the display link scales it by each frame's real duration.
    private static let edgeZone: CGFloat = 28
    private static let minSpeed: CGFloat = 180
    private static let maxSpeed: CGFloat = 1080

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            // Hosts the display link's NSView (behind, hit-transparent).
            .background(DisplayLinkHost(pump: pump))
            // ONE exclusive chain, not two racing modifiers: the marquee wins,
            // and the plain-click clear only fires when no drag happened. A
            // separate `.onTapGesture` could fire on press and wipe the
            // selection before the marquee captured its ⇧-additive base.
            .gesture(
                marqueeGesture.exclusively(before: TapGesture().onEnded {
                    guard !NSEvent.modifierFlags.contains(.shift) else { return }
                    onClear()
                }))
            .onDisappear { stopAutoScroll() }
    }

    /// The marquee drag: a small movement threshold (so a click still clears via
    /// the tap gesture) begins the box; each change recomputes the hit set; ⇧ at
    /// drag start makes it additive.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(spaceName))
            .onChanged { value in
                if state.start == nil {
                    state.start = value.startLocation
                    state.base = NSEvent.modifierFlags.contains(.shift) ? selectionIDs : []
                }
                state.current = value.location
                updateHits()
                updateAutoScroll()
            }
            .onEnded { _ in
                stopAutoScroll()
                state.start = nil
                state.current = nil
                state.base = []
            }
    }

    // MARK: - Edge auto-scroll

    /// Arm or disarm the auto-scroll timer from the pointer's viewport position.
    private func updateAutoScroll() {
        guard let current = state.current, state.visibleRect.height > 0 else { return }
        let pointerY = current.y - state.visibleRect.minY
        let inZone = pointerY < Self.edgeZone
            || pointerY > state.visibleRect.height - Self.edgeZone
        if inZone {
            startAutoScrollIfNeeded()
        } else {
            stopAutoScroll()
        }
    }

    private func startAutoScrollIfNeeded() {
        // Refresh the tick closure each time (re-renders recreate this view
        // struct); everything it reaches — `state`, `onAutoScroll` — is a stable
        // reference, so a slightly stale copy between mouse moves stays correct.
        pump.onTick = { dt in tickAutoScroll(dt: dt) }
        pump.start()
    }

    private func stopAutoScroll() {
        pump.stop()
    }

    /// One auto-scroll step: velocity (pt/sec) from the pointer's penetration into
    /// the edge zone, integrated over the frame's real duration `dt` and clamped
    /// to the content bounds. The scroll moves the content under a stationary
    /// pointer, so the pointer's CONTENT-space position advances by the same delta
    /// — apply it to `current` and recompute hits, since no `DragGesture.onChanged`
    /// fires without actual mouse movement.
    private func tickAutoScroll(dt: CFTimeInterval) {
        guard let current = state.current, state.visibleRect.height > 0 else {
            stopAutoScroll()
            return
        }
        let visible = state.visibleRect
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
        let maxOffset = max(0, state.contentHeight - visible.height)
        let target = min(max(visible.minY + velocity * CGFloat(dt), 0), maxOffset)
        let delta = target - visible.minY
        guard abs(delta) > 0.01 else { return }   // pinned at a content bound
        state.current?.y += delta
        // Advance the tracked viewport optimistically so the next tick doesn't
        // re-step from a stale offset before the scroll-geometry callback lands.
        state.visibleRect.origin.y = target
        onAutoScroll(target)
        updateHits()
    }

    /// Velocity ramp (pt/sec): penetration 0 → `minSpeed`, full zone depth (or
    /// past the viewport edge entirely) → `maxSpeed`.
    private static func scrollSpeed(penetration: CGFloat) -> CGFloat {
        let t = min(max(penetration / edgeZone, 0), 1)
        return minSpeed + t * (maxSpeed - minSpeed)
    }

    /// Recompute the hit set from the current box and hand it up. Frames are the
    /// parent's memoized `MasonryLayout` output (011-B1); the band-narrowed
    /// `masonryMarqueeIndices` is O(cols + hits), not the O(N) frame-array scan.
    private func updateHits() {
        guard let start = state.start, let current = state.current else { return }
        let rect = marqueeRect(from: start, to: current)
        let hits = masonryMarqueeIndices(in: rect, frames: frames, columns: columns)
        // A stale-frame guard: during a resize the parent's frames can lag the
        // itemIDs by one render — never index past the shorter of the two.
        let count = min(itemIDs.count, frames.count)
        onMarquee(Set(hits.compactMap { $0 < count ? itemIDs[$0] : nil }), state.base)
    }
}

/// A display-synced scroll pump. On macOS a `CADisplayLink` must be vended by an
/// `NSView`/`NSWindow`/`NSScreen` (unlike iOS's free-standing initializer), so it
/// is installed with a host view (see ``DisplayLinkHost``). Each fire reports the
/// frame's real duration (`targetTimestamp − timestamp`) so callers step by
/// pt/sec × dt — smooth at any refresh rate, unlike a fixed-delta wall-clock timer.
@MainActor
final class DisplayLinkPump {
    /// The view whose display the link syncs to — set by ``DisplayLinkHost``.
    weak var hostView: NSView?
    /// Called on each vsync with the frame duration in seconds. `@MainActor` so the
    /// captured SwiftUI closure can touch view state directly.
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

/// Installs a hit-transparent `NSView` behind the capture layer purely so
/// ``DisplayLinkPump`` has a view to vend its `CADisplayLink` from. Draws nothing
/// and never intercepts events.
struct DisplayLinkHost: NSViewRepresentable {
    let pump: DisplayLinkPump

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        pump.hostView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        pump.hostView = nsView
    }

    /// An `NSView` that never claims a hit — so the marquee gesture on the
    /// SwiftUI layer above is never shadowed by this host.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The translucent marquee box, drawn ABOVE the grid in the same content space.
struct MarqueeRectangleLayer: View {
    @ObservedObject var state: GridMarqueeState

    var body: some View {
        if let start = state.start, let current = state.current {
            let rect = marqueeRect(from: start, to: current)
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}
