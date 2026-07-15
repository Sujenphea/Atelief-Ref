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
/// stream), so when the pointer enters the viewport's top/bottom edge zone a
/// timer scrolls at a speed proportional to the penetration — unanimated, and
/// only at the edges. (The original per-tick animated `scrollTo` pinned a hit
/// cell to the viewport edge 60+×/sec regardless of pointer position — that
/// was the drag jag.)
struct MarqueeCaptureLayer: View {
    @ObservedObject var state: GridMarqueeState
    /// Grid geometry for the pure frame math (the virtualization trap: offscreen
    /// cells aren't laid out, so live frames can't drive hit-testing).
    let width: CGFloat
    let itemIDs: [UUID]
    let minItemWidth: CGFloat
    let spacing: CGFloat
    let topInset: CGFloat
    let spaceName: String
    /// The selection as of the last parent render — the ⇧-additive base source.
    let selectionIDs: Set<UUID>
    let onMarquee: (_ hits: Set<UUID>, _ base: Set<UUID>) -> Void
    let onClear: () -> Void
    /// Scroll the grid to this content-space y offset (edge auto-scroll tick).
    let onAutoScroll: (_ offsetY: CGFloat) -> Void

    @State private var autoScrollTimer: Timer?

    /// The edge zone height and the speed ramp across it (pt per 60Hz tick:
    /// ≈180 pt/s brushing the zone → ≈1080 pt/s pinned at the very edge).
    private static let edgeZone: CGFloat = 28
    private static let minSpeed: CGFloat = 3
    private static let maxSpeed: CGFloat = 18

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
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
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { tickAutoScroll() }
        }
        // `.common`, not the default mode: the default-mode runloop can starve
        // timers while a mouse drag is being tracked — the exact moment this
        // timer must fire.
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// One auto-scroll step: speed from the pointer's penetration into the edge
    /// zone, clamped to the content bounds. The scroll moves the content under a
    /// stationary pointer, so the pointer's CONTENT-space position advances by
    /// the same delta — apply it to `current` and recompute hits, since no
    /// `DragGesture.onChanged` fires without actual mouse movement.
    private func tickAutoScroll() {
        guard let current = state.current, state.visibleRect.height > 0 else {
            stopAutoScroll()
            return
        }
        let visible = state.visibleRect
        let pointerY = current.y - visible.minY
        let speed: CGFloat
        if pointerY < Self.edgeZone {
            speed = -Self.scrollSpeed(penetration: Self.edgeZone - pointerY)
        } else if pointerY > visible.height - Self.edgeZone {
            speed = Self.scrollSpeed(penetration: pointerY - (visible.height - Self.edgeZone))
        } else {
            stopAutoScroll()
            return
        }
        let maxOffset = max(0, state.contentHeight - visible.height)
        let target = min(max(visible.minY + speed, 0), maxOffset)
        let delta = target - visible.minY
        guard abs(delta) > 0.5 else { return }   // pinned at a content bound
        state.current?.y += delta
        // Advance the tracked viewport optimistically so the next tick doesn't
        // re-step from a stale offset before the scroll-geometry callback lands.
        state.visibleRect.origin.y = target
        onAutoScroll(target)
        updateHits()
    }

    /// Speed ramp: penetration 0 → `minSpeed`, full zone depth (or past the
    /// viewport edge entirely) → `maxSpeed`.
    private static func scrollSpeed(penetration: CGFloat) -> CGFloat {
        let t = min(max(penetration / edgeZone, 0), 1)
        return minSpeed + t * (maxSpeed - minSpeed)
    }

    /// Recompute the hit set from the current box and hand it up. Frames come
    /// from pure math — today's uniform-grid source, swapped for 011-U2's
    /// `JustifiedLayout` frames when justified rows land.
    private func updateHits() {
        guard let start = state.start, let current = state.current else { return }
        let columns = gridColumnCount(
            availableWidth: width, minItemWidth: minItemWidth, spacing: spacing)
        let side = uniformCellSide(availableWidth: width, columns: columns, spacing: spacing)
        let frames = uniformGridFrames(
            count: itemIDs.count, columns: columns,
            cellSize: CGSize(width: side, height: side),
            spacing: spacing, topInset: topInset)
        let rect = marqueeRect(from: start, to: current)
        let hits = marqueeIndices(in: rect, frames: frames)
        onMarquee(Set(hits.map { itemIDs[$0] }), state.base)
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
