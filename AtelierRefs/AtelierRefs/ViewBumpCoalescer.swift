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
//  calls `record` / `drain`. A `Set` means repeated opens of the same asset in
//  one window collapse to a single bump; distinct assets each get one.
//

import Foundation

/// Accumulates pending view bumps and hands them back as a batch to flush.
struct ViewBumpCoalescer {
    private var pending: Set<UUID> = []

    /// Whether there is anything to flush.
    var isEmpty: Bool { pending.isEmpty }

    /// Note that `assetID` was viewed. Idempotent within the current window —
    /// recording the same id twice before a drain still yields one bump.
    mutating func record(_ assetID: UUID) {
        pending.insert(assetID)
    }

    /// Take the accumulated ids and clear the buffer. Returns `[]` when empty.
    mutating func drain() -> [UUID] {
        defer { pending.removeAll(keepingCapacity: true) }
        return Array(pending)
    }
}
