//
//  GridDensity.swift
//  AtelierRefs
//
//  011-B2 · 5A′/16A — the collection grid's density control. Density is a
//  COLUMN-COUNT notch (round-robin masonry has a fixed C; more columns = smaller
//  cells), stepped by ⌘+/⌘− and a toolbar control. It is a pure *view* preference
//  (unlike 007's `sort_mode`, which changes data semantics and lives in the
//  library), so it persists in `UserDefaults` and is GLOBAL — one muscle memory
//  across every collection, not per-collection.
//
//  The rendered count is additionally floored so cells never exceed the 512px
//  cached thumbnail tier (16A): `minColumns(forWidth) = ceil(width / 512)`. That
//  keeps a density change a pure re-layout + re-scale of already-cached
//  thumbnails — no new tier, no library backfill, no extra memory.
//

import Combine
import CoreGraphics
import Foundation

/// A pure, testable grid-density value: the user's chosen column count plus the
/// width-aware clamping that keeps cells inside the 512px tier (16A) and under a
/// thin-cell cap. Width-parameterized, but every method is pure.
struct GridDensity: Equatable {
    /// The user's chosen column-count notch. The RENDERED count also respects the
    /// width-derived floor — read it through ``columns(forWidth:)``, never raw.
    var columns: Int

    /// The notch used when nothing is stored or a stored value is out of range.
    static let `default` = GridDensity(columns: 4)
    /// The absolute upper bound on columns (a thin-cell guard) — density can't
    /// step past it regardless of width.
    static let maxColumns = 12
    /// The cached thumbnail tier: cells never render wider than this, so the
    /// minimum column count for a width is `ceil(width / 512)` (16A).
    static let maxCellWidth: CGFloat = 512

    /// The minimum columns that keep every cell within the 512px tier at `width`
    /// (16A). At least 1 (a single column is valid on a very narrow window).
    static func minColumns(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width / maxCellWidth).rounded(.up)))
    }

    /// Clamp a raw column count into `[minColumns(forWidth), maxColumns]` for
    /// `width` (the floor wins if it exceeds the cap — a very wide window can
    /// force more columns than the thin-cell cap would otherwise allow).
    static func clamp(_ count: Int, forWidth width: CGFloat) -> Int {
        let low = minColumns(forWidth: width)
        let high = max(low, maxColumns)
        return min(high, max(low, count))
    }

    /// The column count to render at `width`: the stored notch, floored to the
    /// 512 cap and capped at ``maxColumns`` (always ≥ 1).
    func columns(forWidth width: CGFloat) -> Int {
        Self.clamp(columns, forWidth: width)
    }

    /// ⌘+ (zoom in) — bigger cells, so one FEWER column. Stops at the width floor
    /// (can't zoom past the 512 cap). Steps from the *rendered* count so it feels
    /// right even when the stored notch was clamped by width.
    func zoomedIn(forWidth width: CGFloat) -> GridDensity {
        GridDensity(columns: Self.clamp(columns(forWidth: width) - 1, forWidth: width))
    }

    /// ⌘− (zoom out) — smaller cells, so one MORE column. Stops at ``maxColumns``.
    func zoomedOut(forWidth width: CGFloat) -> GridDensity {
        GridDensity(columns: Self.clamp(columns(forWidth: width) + 1, forWidth: width))
    }
}

/// Owns the persisted, global grid-view preferences (today just density). Uses
/// the ad-hoc `UserDefaults.standard` pattern the app already uses for view state
/// (mirrors `NavModel`'s last-collection key) — no `@AppStorage` convention
/// exists yet, and density needs a clamped-load anyway (12A).
@MainActor
final class GridViewPreferences: ObservableObject {
    /// The live density notch; every change persists the raw column count.
    @Published var density: GridDensity {
        didSet { defaults.set(density.columns, forKey: Self.densityKey) }
    }

    /// Collapse each multi-image post (an Instagram carousel, a multi-photo tweet)
    /// to a single tile (307). On by default: a saved-posts feed is mostly carousels,
    /// and showing every member turns four near-identical images into four slots that
    /// could have shown four different posts. Off restores the flat, one-tile-per-image
    /// grid.
    @Published var groupCarousels: Bool {
        didSet { defaults.set(groupCarousels, forKey: Self.groupCarouselsKey) }
    }

    private static let densityKey = "AtelierGridDensityColumns"
    private static let groupCarouselsKey = "AtelierGridGroupCarousels"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` can't tell "absent" from "stored false", and the default
        // here is ON — so probe for the key's presence explicitly rather than
        // relying on the zero value.
        groupCarousels = defaults.object(forKey: Self.groupCarouselsKey) == nil
            ? true
            : defaults.bool(forKey: Self.groupCarouselsKey)
        // An absent key reads as `0`; a corrupt / out-of-absolute-range stored
        // value falls back to the default notch (12A). The width-derived floor is
        // applied later at render time by `GridDensity.columns(forWidth:)`.
        let stored = defaults.integer(forKey: Self.densityKey)
        density = (1...GridDensity.maxColumns).contains(stored)
            ? GridDensity(columns: stored)
            : .default
    }

    /// ⌘+ — bigger cells (fewer columns) at the current viewport `width`.
    func zoomIn(forWidth width: CGFloat) {
        let next = density.zoomedIn(forWidth: width)
        if next != density { density = next }
    }

    /// ⌘− — smaller cells (more columns) at the current viewport `width`.
    func zoomOut(forWidth width: CGFloat) {
        let next = density.zoomedOut(forWidth: width)
        if next != density { density = next }
    }
}
