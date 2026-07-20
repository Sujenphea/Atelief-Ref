//
//  GridContextMenu.swift
//  AtelierRefs
//
//  036 §4 C4 — the container-level lazy context menu for the collection grid.
//
//  Before this, EVERY windowed cell carried its own `.contextMenu`, so a band
//  crossing built ~100 complete menu trees (two submenus each looping every
//  move/copy destination, plus buttons and a divider) for a right-click that can
//  land on at most one of them. 035 §4 measured 122 ms / 20 s of scroll at the
//  user's 4 collections; the cost is LINEAR in folder count and paid twice per
//  cell, so a 40-folder library pays ~10×. 038 §3.3 measured stripping the
//  per-cell wrappers (this one included) as the largest SwiftUI-side effect in
//  the bake-off: frames over 2P went 314 → 8 at 2000 items.
//
//  The replacement is ONE `.contextMenu` on the grid's content container, whose
//  target cell is resolved by hit-testing the cursor against the ANALYTIC
//  ``MasonryLayout`` frames — a zero-size-rect ``masonryMarqueeIndices`` query,
//  the same call the marquee already runs per drag tick. 038 §6 is why it must
//  be the analytic frames and never live cell frames: masonry heights are
//  `columnWidth / aspect` and therefore fractional, so rendered frames drift
//  sub-pixel from the analytic ones. The analytic frames are the single source
//  of truth for geometry in this grid.
//
//  Kept SwiftUI-free above the state/layer types so the two decisions the menu
//  makes — WHICH cell the cursor is over, and WHAT that cell's action scope is —
//  are unit-tested without a running view.
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Pure resolution

/// The cursor's position in the grid's CONTENT space, from a position captured
/// in VIEWPORT space plus the live scroll offset (036 §4 C4).
///
/// The hover seam (`.onContinuousHover`) reports a content-space point, but that
/// point goes stale the moment the grid scrolls: a wheel/trackpad scroll moves
/// the content under a stationary pointer WITHOUT producing a mouse-moved event,
/// so nothing re-fires the hover and the stored content point now names a
/// different cell. Storing the viewport-relative point instead makes the capture
/// scroll-invariant, and this re-adds the offset at read time from the live
/// (non-published) scroll geometry the marquee already tracks.
///
/// `nil` in → `nil` out: no pointer over the grid at all (see
/// ``masonryContextTargetIndex(at:frames:columns:)``'s callers for the
/// keyboard-invocation fallback that case drives).
func gridCursorContentPoint(viewport: CGPoint?, contentOffset: CGPoint) -> CGPoint? {
    guard let viewport else { return nil }
    return CGPoint(x: viewport.x + contentOffset.x, y: viewport.y + contentOffset.y)
}

/// The item index the context menu should act on for a cursor at `point`, or
/// `nil` when the cursor is over empty space (or absent).
///
/// A zero-size rect through ``masonryMarqueeIndices`` — which documents exactly
/// this case: a degenerate marquee falls back to edge-INCLUSIVE overlap, so a
/// click selects the frame it lands inside and never a neighbour. Reusing that
/// query rather than a bespoke scan means the menu can never disagree with the
/// marquee about which cell a point belongs to.
///
/// Masonry frames are separated by the grid spacing and so never overlap; the
/// only way a point hits twice is landing exactly on the shared edge of two
/// touching frames (spacing 0). The tie-break is the LAST (highest) index, which
/// is the one drawn on top by the window's `ForEach` — so the menu targets what
/// the user sees.
func masonryContextTargetIndex(at point: CGPoint?, frames: [CGRect], columns: Int) -> Int? {
    guard let point else { return nil }
    let hits = masonryMarqueeIndices(
        in: CGRect(origin: point, size: .zero), frames: frames, columns: columns)
    return hits.last
}

/// The asset ids a batch action acts on for a right-click on a cell (Finder
/// scope, 009 · 7A): the WHOLE selection when the cell is part of it, else just
/// that one cell — **the selection is left untouched either way**.
///
/// Lifted out of `IngestionModel.actionTargets(forCellItemID:)` (which now calls
/// it) so the rule the container menu depends on is pure and directly tested.
/// `cellAssetID` is `nil` when the cell has vanished from the feed, which yields
/// no targets and therefore no menu.
func gridActionTargets(
    isSelected: Bool, selectedAssetIDs: [UUID], cellAssetID: UUID?
) -> [UUID] {
    if isSelected { return selectedAssetIDs }
    guard let cellAssetID else { return [] }
    return [cellAssetID]
}

// MARK: - Per-tick state

/// The container context menu's cursor + highlight state (036 §4 C4).
///
/// A class held by the parent in plain `@State` — deliberately NOT
/// `@StateObject` — for the same reason as ``GridMarqueeState``: `cursorViewport`
/// is written on EVERY mouse-moved event, and subscribing `CollectionView` to
/// that would re-render the whole screen per pointer pixel, which is precisely
/// the churn C4 exists to remove. So:
///
/// - `cursorViewport` is a PLAIN var — never published, read only on demand when
///   a menu is being built or opened.
/// - `highlightFrame` IS published, because something must draw it; only the
///   tiny ``GridContextHighlightLayer`` observes this object, so the publish
///   costs one layer redraw and not a grid rebuild. It changes at most twice per
///   right-click.
final class GridContextMenuState: ObservableObject {
    /// The pointer's last known position in VIEWPORT space (scroll-invariant —
    /// see ``gridCursorContentPoint(viewport:contentOffset:)``). `nil` means the
    /// pointer is not over the grid.
    var cursorViewport: CGPoint?
    /// The analytic frame of the cell the open menu is acting on, in content
    /// space, or `nil` when no menu is open.
    @Published var highlightFrame: CGRect?
}

/// The "this is the cell the menu will act on" outline, drawn ABOVE the grid in
/// the same content space as the marquee rectangle (036 §4 C4).
///
/// A per-cell `.contextMenu` got this highlight for free from AppKit; one
/// container-level menu does not, and without it the user has no idea which item
/// "Delete (1)" means. Deliberately the SAME shape and stroke as
/// `CollectionCell.cursorRing` (radius 8, 2 pt accent) so the grid has one
/// visual vocabulary for "targeted", drawn at full opacity to read as stronger
/// than the idle keyboard cursor it may sit on top of.
struct GridContextHighlightLayer: View {
    @ObservedObject var state: GridContextMenuState

    var body: some View {
        if let frame = state.highlightFrame {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }
}
