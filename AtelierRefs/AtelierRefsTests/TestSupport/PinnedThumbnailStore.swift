//
//  PinnedThumbnailStore.swift
//  AtelierRefsTests
//
//  099 · P2b — the store the thumbnail suites are allowed to assert against,
//  and since P2c the detail-image suites too (see `DetailImageCache.pinned`
//  at the foot of this file).
//
//  `ThumbnailPipelineTests` and `ThumbnailWindowPrefetcherTests` used to run
//  against the production `NSCache`, and roughly one gate run in four the two
//  suites failed together — fifteen tests, ~42 issues, everything else in the
//  target green. Every one of those failures reduced to the same sentence:
//
//      Expectation failed: (pipeline.cachedExact(hash: "a", bucket: 256) → nil) != nil
//      Expectation failed: (residentUnderRoomyBudget → 0) == 8
//      Expectation failed: (probe.callCount("a") → 3) == 1
//
//  — a key whose decode had provably run, whose `store(_:for:)` had provably
//  charged a plausible cost against an ample budget, reading back as a miss.
//  Eight one-megabyte entries under a sixty-four-megabyte budget, and **zero**
//  resident. The cache had been emptied between the write and the read.
//
//  Nothing was wrong with the pipeline and nothing was wrong with `NSCache`.
//  `NSCache` states its own terms: it "incorporates various auto-eviction
//  policies", and a caller "should not rely on a cache to store" anything. The
//  suites were asserting a guarantee that does not exist, and they got away with
//  it whenever the machine was quiet. That is not a race inside any one test —
//  it is fifteen tests sharing one wrong premise, which is why they always fell
//  over together and why the two with no concurrency in them at all
//  (`exactHitWins`, `fallsBackToLargerBucket`) were in the failing set.
//
//  So the premise moves here. This store honours the whole ``ThumbnailStore``
//  contract — including rule 2, the outright refusal of an entry costing more
//  than the entire budget, which is the `NSCache` behaviour
//  ``ThumbnailPipeline/store(_:for:)``'s clamp exists to survive — and adds the
//  one thing `NSCache` will not promise: **it keeps what it is given until the
//  budget says otherwise, and never on a schedule of its own.** Eviction happens
//  only inside `insert`, only when the budget is exceeded, and only
//  oldest-first, so a test can say what should be resident and be right.
//
//  The app is untouched: ``ThumbnailPipeline`` still defaults to
//  ``NSCacheThumbnailStore``, and giving memory back under pressure is exactly
//  what a thumbnail cache should do in a shipping app. What changed is that the
//  tests no longer bet on it not happening.
//
//  **P2c.** ``DetailImageCache`` had the identical bet in ten assertions across
//  eight tests, and was named in 469 as the follow-up. Not one of them had ever
//  been seen to fail — their insert-then-read windows are microseconds of
//  straight-line code where the thumbnail suites' were seconds across task hops,
//  which narrows the window rather than closing it. It takes the same seam now,
//  so this store grew the one thing that cache has and the pipeline does not: a
//  count budget
//  (contract rule 1b). Nothing about the detail cache's production shape moved
//  either — same `NSCache`, same 384 MB, same five entries.
//

import CoreGraphics
import Foundation

@testable import AtelierRefs

/// A ``ThumbnailStore`` that evicts only when a budget makes it, and never of
/// its own accord.
///
/// `costLimit == 0` and `countLimit == 0` both mean unbounded, which is what the
/// scheduling tests want: they are about coalescing, promotion and cancellation,
/// and a budget they did not ask for is one more thing that could explain a miss.
///
/// Thread-safe by its own lock, and it never calls back into its caller — the
/// pipeline reads its store while holding its own lock (`prefetch`, `pump`), so
/// re-entrancy here would be a deadlock there.
nonisolated final class PinnedThumbnailStore: ThumbnailStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (image: CGImage, cost: Int)] = [:]
    /// Insertion order, oldest first — the eviction order when a budget bites.
    private var order: [String] = []
    private var charged = 0

    let costLimit: Int
    let countLimit: Int

    /// - Parameter countLimit: contract rule 1b. `0` is unbounded, which is what
    ///   the thumbnail suites take; ``DetailImageCache``'s tests pass five, or
    ///   whatever number the case under test is about.
    init(costLimit: Int = 0, countLimit: Int = 0) {
        self.costLimit = costLimit
        self.countLimit = countLimit
    }

    func image(forKey key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.image
    }

    func insert(_ image: CGImage, forKey key: String, cost: Int) {
        let charge = max(0, cost)
        lock.lock()
        defer { lock.unlock() }
        // Contract rule 2: an entry that cannot fit in the whole budget is
        // refused, not admitted-and-then-evicted. `NSCache` does this silently
        // and it is the failure mode `store(_:for:)`'s clamp is written against,
        // so a store that quietly accepted it would make that clamp untestable.
        if costLimit > 0, charge > costLimit { return }
        if let previous = entries.removeValue(forKey: key) {
            charged -= previous.cost
            order.removeAll { $0 == key }
        }
        entries[key] = (image, charge)
        order.append(key)
        charged += charge
        while overBudget, !order.isEmpty {
            let oldest = order.removeFirst()
            if let dropped = entries.removeValue(forKey: oldest) { charged -= dropped.cost }
        }
    }

    /// Whether either budget is currently exceeded. `lock` must be held.
    ///
    /// Both budgets evict from the same oldest-first order, so a store carrying
    /// both (``DetailImageCache``'s shape) behaves the way its two `NSCache`
    /// limits do: whichever bites first is the one that governs.
    private var overBudget: Bool {
        (costLimit > 0 && charged > costLimit) || (countLimit > 0 && entries.count > countLimit)
    }

    /// How many entries are resident. Test support.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

// MARK: - The detail cache over a pinned store (099 · P2c)

extension DetailImageCache {
    /// A ``DetailImageCache`` whose bitmaps live in a ``PinnedThumbnailStore`` —
    /// the only detail cache a test may read a residency assertion out of.
    ///
    /// Unbounded on both axes by default, for the reason `pinnedPipeline` is:
    /// `DetailImageLoaderTests` and `DetailSessionTests` are about coalescing,
    /// promotion, cancellation and which buckets were asked for, and a budget
    /// none of them set is one more reason a lookup could miss. The two tests
    /// that ARE about the budgets pass their own.
    static func pinned(totalCostLimit: Int = 0, countLimit: Int = 0) -> DetailImageCache {
        DetailImageCache(store: PinnedThumbnailStore(
            costLimit: totalCostLimit, countLimit: countLimit))
    }
}
