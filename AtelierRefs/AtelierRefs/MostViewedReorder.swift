//
//  MostViewedReorder.swift
//  AtelierRefs
//
//  036 §3 B4 — closing the item-detail overlay used to trigger a FULL
//  `loadContents` reload to apply the Most-Viewed re-sort, which blew the grid
//  away (root cause 3). This is the local, pure replacement: it reproduces core's
//  Most-Viewed order *exactly* so the just-viewed item rises in place, without a
//  round-trip to the database and without re-materializing the whole grid.
//
//  BYTE-IDENTITY IS THE WHOLE POINT. If this order ever diverged from what a real
//  `loadContents` produces, the difference would stay invisible until the next
//  genuine reload snapped items into different places. Core's ORDER BY is
//  `asset.view_count DESC, asset.created_at DESC, asset.id DESC`
//  (`Enums.swift:75`, `AppServices.swift:1152`), so this comparator is that tuple,
//  field for field:
//   • `view_count` is a plain `Int` — `>` is `DESC`.
//   • `created_at` is stored as GRDB's default `YYYY-MM-DD HH:MM:SS.SSS` UTC text
//     (`AtelierRecord.swift:33`), whose lexical order IS chronological order and
//     is millisecond-quantized. The local `Asset.createdAt: Date` was decoded from
//     that very text, so comparing the `Date`s with `>` reproduces the SQL text
//     `DESC` exactly (equal text ⇒ equal `Date`; a distinct text ⇒ a `Date`
//     ordered the same way).
//   • `id` is stored as a LOWERCASED `uuidString` TEXT (`AtelierRecord.swift:36`,
//     `RecordConvention.uuidEncoding = .lowercaseString`). SQLite's default BINARY
//     collation compares those ASCII bytes; for lowercase hex + hyphens that
//     equals Swift `String` order, so `id.uuidString.lowercased()` compared with
//     `>` reproduces `asset.id DESC`.
//  `MostViewedReorderTests` pins this against core's REAL SQL sort (seed → view →
//  compare), not a hand-copy that could silently drift.
//

import AtelierCore
import Foundation

/// The outcome of a local Most-Viewed reorder (036 §3 B4).
nonisolated enum MostViewedReorderResult: Equatable {
    /// The bumps did not change the display order — the caller MUST skip the
    /// `items` publish. This is the common case (viewing items already at the top
    /// changes nothing) and skipping it is what keeps closing the overlay free of
    /// grid churn.
    case unchanged
    /// The new order, with the per-id view bumps baked into each asset's
    /// `viewCount`, ready to replace `items` in ONE publish.
    case reordered([CollectionItemDetail])
}

/// Reproduce core's Most-Viewed reload LOCALLY (036 §3 B4).
///
/// `bumps` are per-asset view-count deltas accumulated since the last genuine
/// reload (each is exactly how much core's `view_count` was incremented for that
/// asset). They are applied to a COPY of each item, which is then STABLE-sorted by
/// core's exact tiebreak. When the resulting membership order equals the input,
/// returns `.unchanged` so the caller skips the publish — even if some counts
/// changed but no item actually moved.
nonisolated func mostViewedReorder(
    items: [CollectionItemDetail],
    bumps: [UUID: Int]
) -> MostViewedReorderResult {
    // Bake the accumulated deltas into a copy (asset is a `let` on the detail, so
    // rebuild the detail with a mutated asset value).
    let bumped: [CollectionItemDetail] = items.map { detail in
        guard let delta = bumps[detail.asset.id], delta != 0 else { return detail }
        var asset = detail.asset
        asset.viewCount += delta
        return CollectionItemDetail(item: detail.item, asset: asset, source: detail.source)
    }

    // Stable sort: Swift's `sorted(by:)` is NOT stable, so the ORIGINAL index is
    // the final ascending tiebreak — making the comparator a strict total order,
    // which yields a deterministic, stable result (elements equal on all three
    // real keys keep their prior relative order).
    let sorted = bumped
        .enumerated()
        .sorted { lhs, rhs in
            mostViewedPrecedes(
                lhs.element.asset, rhs.element.asset,
                lhsIndex: lhs.offset, rhsIndex: rhs.offset)
        }
        .map(\.element)

    // Skip the publish when the membership order is identical (the common case).
    // Counts baked into the copies are discarded here — order is all the grid
    // renders — so an unchanged order returns `.unchanged` regardless of bumps.
    if zip(sorted, items).allSatisfy({ $0.item.id == $1.item.id }) {
        return .unchanged
    }
    return .reordered(sorted)
}

/// Core's Most-Viewed comparator — `view_count DESC, created_at DESC, id DESC`
/// (`AppServices.swift:1152`) — with the original index as a FINAL ascending
/// tiebreak for a stable `sorted(by:)`. Returns whether `a` precedes `b`.
///
/// Exposed (not `private`) so tests can hit each tier directly with constructed
/// ties, independent of the array plumbing.
nonisolated func mostViewedPrecedes(
    _ a: Asset, _ b: Asset, lhsIndex: Int, rhsIndex: Int
) -> Bool {
    if a.viewCount != b.viewCount { return a.viewCount > b.viewCount }   // view_count DESC
    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }   // created_at DESC
    let aKey = a.id.uuidString.lowercased()
    let bKey = b.id.uuidString.lowercased()
    if aKey != bKey { return aKey > bKey }                              // id DESC
    return lhsIndex < rhsIndex                                          // stability
}
