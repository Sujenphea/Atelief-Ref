//
//  ToastQueueTests.swift
//  AtelierRefsTests
//
//  011-B4 · 11A/12A — the toast queue and its helpers, exhaustively (the view /
//  timer are manual): coalescing by key, append-newest ordering, injected-clock
//  expiry + removal order, the visible-count cap (oldest evicted), the stale-Jump
//  no-op, and the deterministic post-load Jump selection.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("ToastQueue")
struct ToastQueueTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test("enqueue appends newest at the end, in order")
    func ordering() {
        var q = ToastQueue()
        q.enqueue(message: "a", coalesceKey: "a", now: at(0))
        q.enqueue(message: "b", coalesceKey: "b", now: at(1))
        #expect(q.toasts.map(\.message) == ["a", "b"])
    }

    @Test("a same-key re-post coalesces in place, refreshing message + expiry")
    func coalesces() {
        var q = ToastQueue()
        q.ttl = 6
        let first = q.enqueue(message: "Saved 1", coalesceKey: "cap", now: at(0))
        let second = q.enqueue(message: "Saved 2", coalesceKey: "cap", now: at(1))
        // One card, same id, refreshed content + expiry (1 + 6 = 7).
        #expect(q.toasts.count == 1)
        #expect(first == second)
        #expect(q.toasts[0].message == "Saved 2")
        #expect(q.toasts[0].expiresAt == at(7))
    }

    @Test("different keys stack as separate toasts")
    func distinctKeysStack() {
        var q = ToastQueue()
        q.enqueue(message: "x", coalesceKey: "x", now: at(0))
        q.enqueue(message: "y", coalesceKey: "y", now: at(0))
        #expect(q.toasts.count == 2)
    }

    @Test("purgeExpired drops toasts at/after their expiry, keeping order")
    func expiry() {
        var q = ToastQueue()
        q.ttl = 5
        q.enqueue(message: "a", coalesceKey: "a", now: at(0))    // expires at 5
        q.enqueue(message: "b", coalesceKey: "b", now: at(3))    // expires at 8
        q.purgeExpired(now: at(5))                               // a expires exactly now
        #expect(q.toasts.map(\.message) == ["b"])
        q.purgeExpired(now: at(8))
        #expect(q.toasts.isEmpty)
    }

    @Test("enqueue purges expired first so the cap counts only live toasts")
    func enqueuePurgesFirst() {
        var q = ToastQueue()
        q.ttl = 2
        q.enqueue(message: "old", coalesceKey: "old", now: at(0))   // expires at 2
        q.enqueue(message: "new", coalesceKey: "new", now: at(5))   // purges "old" first
        #expect(q.toasts.map(\.message) == ["new"])
    }

    @Test("the visible cap evicts the oldest")
    func capEvictsOldest() {
        var q = ToastQueue()
        q.maxVisible = 2
        q.ttl = 100
        q.enqueue(message: "1", coalesceKey: "1", now: at(0))
        q.enqueue(message: "2", coalesceKey: "2", now: at(1))
        q.enqueue(message: "3", coalesceKey: "3", now: at(2))
        #expect(q.toasts.map(\.message) == ["2", "3"])   // "1" evicted
    }

    @Test("dismiss removes a specific toast by id")
    func dismiss() {
        var q = ToastQueue()
        let a = q.enqueue(message: "a", coalesceKey: "a", now: at(0))
        q.enqueue(message: "b", coalesceKey: "b", now: at(0))
        q.dismiss(a)
        #expect(q.toasts.map(\.message) == ["b"])
    }

    @Test("nextExpiry is the soonest live expiry")
    func nextExpiry() {
        var q = ToastQueue()
        q.ttl = 10
        q.enqueue(message: "a", coalesceKey: "a", now: at(0))   // 10
        q.enqueue(message: "b", coalesceKey: "b", now: at(2))   // 12
        #expect(q.nextExpiry == at(10))
    }
}

@Suite("Jump resolution + selection")
struct JumpTests {

    private func detail(assetID: UUID) -> CollectionItemDetail {
        let sourceID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: .image, blobHash: "h", mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 1,
            downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
        let item = CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date())
        return CollectionItemDetail(item: item, asset: asset, source: source)
    }

    @Test("resolveJump passes a live target and drops a stale one")
    func resolveJumpStale() {
        let live = UUID(), gone = UUID()
        let existing: Set<UUID> = [live]
        #expect(resolveJump(JumpTarget(collectionID: live, assetIDs: []), existingCollectionIDs: existing) != nil)
        #expect(resolveJump(JumpTarget(collectionID: gone, assetIDs: []), existingCollectionIDs: existing) == nil)
    }

    @Test("jumpSelection selects matching items, lead on the first in feed order")
    func selectsMatching() {
        let a = UUID(), b = UUID(), c = UUID()
        let items = [detail(assetID: a), detail(assetID: b), detail(assetID: c)]
        let sel = jumpSelection(in: items, assetIDs: [c, a])   // set order irrelevant
        #expect(sel.ids == Set([items[0].item.id, items[2].item.id]))
        #expect(sel.lead == items[0].item.id)     // a is first in feed order
        #expect(sel.anchor == items[0].item.id)
    }

    @Test("a Jump whose assets all vanished yields an empty (idle) selection")
    func allMissingIsIdle() {
        let items = [detail(assetID: UUID())]
        let sel = jumpSelection(in: items, assetIDs: [UUID(), UUID()])
        #expect(sel.isEmpty)
    }
}
