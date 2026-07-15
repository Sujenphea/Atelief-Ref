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
}

/// The click/drag capture layer that sits UNDER the grid cells: a drag on empty
/// space is a marquee, a plain click clears the selection (⇧-click never does).
///
/// No scroll-follow: the coordinates live in the scroll CONTENT space, so
/// two-finger scrolling mid-drag reveals more grid and the box extends
/// naturally on the next pointer move. The old per-tick animated `scrollTo`
/// pinned a hit cell to the viewport edge 60+×/sec — fighting the user's own
/// scroll was the jag. (Pointer-at-edge auto-scroll is a possible follow-up.)
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
            }
            .onEnded { _ in
                state.start = nil
                state.current = nil
                state.base = []
            }
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
