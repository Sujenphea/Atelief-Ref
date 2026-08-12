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
//  Now that the grid renders through `NSCollectionView`, the menu itself is the
//  AppKit-native `menu(for:)` on the collection view (036 §4 A3); these functions
//  are the pure decisions it reuses — WHICH cell the cursor is over, and WHAT that
//  cell's action scope is — kept SwiftUI-free so they stay unit-tested without a
//  running view. The C4 SwiftUI container menu, its `GridContextMenuState`, and
//  the `GridContextHighlightLayer` it drove were retired with the SwiftUI grid
//  (189); only these pure helpers remain.
//

import CoreGraphics
import Foundation

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

/// One row the out-flow group contributes to a cell menu (011 · A2/A3).
///
/// A description, not a widget: `MasonryGridCoordinator` turns these into
/// `NSMenuItem`s. That split is this file's whole reason for existing — the
/// decisions about WHICH rows a menu shows stay AppKit-free so they can be tested
/// without a running view, exactly as ``gridActionTargets`` is.
enum OutFlowMenuRow: Equatable {
    /// The separator that opens the group. Only ever emitted when at least one verb
    /// follows it — a menu that binds neither hook must not grow a stray divider.
    case separator
    /// The system `Share ▸` submenu.
    case share
    /// `Export Assets…`, with the `(N)` count suffix a multi-target verb carries.
    case exportAssets(title: String)
}

/// The out-flow rows for a cell menu: `Share ▸` and `Export Assets…`, each present
/// only when the surface binds it AND has something to offer.
///
/// They come as a group behind their own separator because they are the one part of
/// this menu that sends refs OUT of the app rather than moving them around inside
/// it — and they precede the destructive verbs, so a click reaching for Share cannot
/// land near Delete.
///
/// - Parameters:
///   - canShare: the surface binds sharing AND the targets yielded a shareable
///     payload (a resolver that comes back empty yields no item — see
///     `AssetShare.menuItem`).
///   - canExport: the surface binds the originals export.
///   - targetCount: how many assets the verbs would act on, for the count suffix.
func outFlowMenuRows(
    canShare: Bool, canExport: Bool, targetCount: Int
) -> [OutFlowMenuRow] {
    guard canShare || canExport else { return [] }
    var rows: [OutFlowMenuRow] = [.separator]
    if canShare { rows.append(.share) }
    if canExport {
        rows.append(.exportAssets(
            title: "Export Assets\(targetCount > 1 ? " (\(targetCount))" : "")…"))
    }
    return rows
}

/// The asset ids a batch action acts on for a right-click on a cell (Finder
/// scope, 009 · 7A): the WHOLE selection when the cell is part of it, else just
/// that one cell — **the selection is left untouched either way**.
///
/// Lifted out of `IngestionModel.actionTargets(forCellItemID:)` (which now calls
/// it) so the rule the container menu depends on is pure and directly tested.
///
/// `cellAssetIDs` is what the CELL stands for — normally its one asset, but a
/// collapsed carousel tile (307) stands for every member of its post, so this is a
/// list rather than a single id. Empty when the cell has vanished from the feed,
/// which yields no targets and therefore no menu. The scope RULE is unchanged; only
/// what "one cell" can mean has widened.
func gridActionTargets(
    isSelected: Bool, selectedAssetIDs: [UUID], cellAssetIDs: [UUID]
) -> [UUID] {
    if isSelected { return selectedAssetIDs }
    return cellAssetIDs
}
