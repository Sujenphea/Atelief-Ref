//
//  ViewBumpCoalescer.swift
//  AtelierRefs
//
//  007 G4 — coalesces "this asset was viewed" signals so a burst of detail
//  opens becomes ONE `recordViews` write per asset. A view is the deliberate
//  "I looked at this" signal (an Item Detail open), NOT grid selection or a
//  canvas realization — so the caller records only at the detail-open seam.
//
//  Pure value type (no timers, no I/O): the model owns the debounce timer and
//  calls `record` / `drain`.
//
//  036 §3 B4 — `drain()` now returns PER-ID counts (`[UUID: Int]`) instead of a
//  bare `Set<UUID>`, so the caller can see how many opens landed on each asset in
//  the window. Note that core's `recordViews` still coalesces a batch to ONE
//  `view_count` increment per DISTINCT asset (`AppServices.swift:743`), so the
//  MODEL folds each drain to +1 per key when reproducing the DB delta locally —
//  the raw count is exposed but the persisted unit remains one-bump-per-asset.
//

import Foundation

/// Accumulates pending view bumps and hands them back as a batch to flush.
struct ViewBumpCoalescer {
    /// Per-asset open counts within the current window.
    private var pending: [UUID: Int] = [:]

    /// Whether there is anything to flush.
    var isEmpty: Bool { pending.isEmpty }

    /// Note that `assetID` was viewed. Recording the same id twice before a drain
    /// increments its count (was a set-collapse before B4).
    mutating func record(_ assetID: UUID) {
        pending[assetID, default: 0] += 1
    }

    /// Take the accumulated per-id counts and clear the buffer. Returns `[:]` when
    /// empty.
    mutating func drain() -> [UUID: Int] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
