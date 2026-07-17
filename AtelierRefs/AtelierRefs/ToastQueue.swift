//
//  ToastQueue.swift
//  AtelierRefs
//
//  011-B4 · 4A/11A — the pure, testable model behind capture-feedback toasts. A
//  remote browser capture lands off-screen with no in-app signal today; this
//  surfaces one "Saved N to <collection> — Jump" toast per BATCH (coalesced by
//  target, never one-per-item), with a typed Jump action that navigates to the
//  collection and selects what just arrived.
//
//  Everything time-dependent takes an injected `now`, so the queue is unit-tested
//  without a wall clock (the `ToastCenter` owner drives real time + a purge timer;
//  the view renders it). The stale-Jump guard (`resolveJump`) is pure too — a
//  toast can outlive its collection, and firing it must no-op, not crash.
//

import Foundation

/// A typed action a toast's button performs. Jump navigates to captured assets
/// (011-B4); Undo reverses a just-performed destructive verb (034 P1 — the unified
/// "action + Undo" surface).
enum ToastAction: Equatable {
    /// Navigate to a collection and select the given assets — the Saved—Jump verb.
    case jump(JumpTarget)
    /// Undo the destructive action this toast describes (delete / remove / move).
    /// `undoToken` is the model's undo-stack token AT POST TIME: the shell fires the
    /// undo only if it's still the top of the stack, so a toast that another action
    /// has since superseded no-ops instead of reversing the wrong thing.
    case undo(undoToken: Int)
}

/// Where a Jump goes: a collection and the assets to select once it loads.
struct JumpTarget: Equatable {
    let collectionID: UUID
    let assetIDs: [UUID]
    /// The button label shown on the toast.
    var buttonLabel: String = "Jump"
}

/// One transient toast. `coalesceKey` groups rapid re-posts (e.g. two captures
/// into the same folder) so they refresh one card instead of stacking duplicates.
struct Toast: Identifiable, Equatable {
    let id: UUID
    let message: String
    let action: ToastAction?
    /// When this toast auto-dismisses (enqueue time + TTL).
    let expiresAt: Date
    let coalesceKey: String
}

/// A pure toast queue (011-B4 · 11A): append-newest FIFO with coalescing by key,
/// a visible-count cap (oldest evicted), and time-based expiry — all driven by an
/// injected `now`.
struct ToastQueue: Equatable {
    private(set) var toasts: [Toast] = []

    /// The most toasts shown at once; past this the OLDEST is evicted.
    var maxVisible = 3
    /// How long a toast lives before auto-expiry.
    var ttl: TimeInterval = 6

    /// Enqueue (or coalesce) a toast at `now`. If a live toast shares
    /// `coalesceKey` it is refreshed IN PLACE — same slot + id, new
    /// message/action/expiry — so a rapid duplicate never stacks. Past
    /// ``maxVisible`` the oldest toast is evicted. `purgeExpired` runs first so a
    /// long-idle queue doesn't carry stale cards into the cap math. Returns the
    /// enqueued / refreshed toast id.
    @discardableResult
    mutating func enqueue(
        message: String, action: ToastAction? = nil, coalesceKey: String,
        now: Date, ttl: TimeInterval? = nil, id: UUID = UUID()
    ) -> UUID {
        purgeExpired(now: now)
        let expires = now.addingTimeInterval(ttl ?? self.ttl)
        if let index = toasts.firstIndex(where: { $0.coalesceKey == coalesceKey }) {
            let existing = toasts[index]
            toasts[index] = Toast(
                id: existing.id, message: message, action: action,
                expiresAt: expires, coalesceKey: coalesceKey)
            return existing.id
        }
        let toast = Toast(
            id: id, message: message, action: action,
            expiresAt: expires, coalesceKey: coalesceKey)
        toasts.append(toast)
        if toasts.count > maxVisible {
            toasts.removeFirst(toasts.count - maxVisible)
        }
        return toast.id
    }

    /// Drop every toast expired at or before `now`, preserving survivor order.
    mutating func purgeExpired(now: Date) {
        toasts.removeAll { $0.expiresAt <= now }
    }

    /// Remove a toast by id (manual dismiss, or after its action fires).
    mutating func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// The soonest expiry among live toasts (to schedule the next purge), or nil.
    var nextExpiry: Date? { toasts.map(\.expiresAt).min() }
}

/// Resolve a Jump against the collections that still exist: `nil` if the target
/// collection is gone (a toast that outlived its collection — fire it and nothing
/// happens, 11A). Asset ids pass through as-is; the post-load selection prunes to
/// the loaded items anyway, so no per-asset existence check is needed here.
func resolveJump(_ target: JumpTarget, existingCollectionIDs: Set<UUID>) -> JumpTarget? {
    existingCollectionIDs.contains(target.collectionID) ? target : nil
}
