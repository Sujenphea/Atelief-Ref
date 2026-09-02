//
//  ThumbnailPipeline.swift
//  AtelierRefs
//
//  036 §4 C1 — the bucketed, byte-budgeted, fully-decoded thumbnail pipeline.
//
//  Three properties distinguish it from the `ThumbnailCache` it replaced (an
//  `NSCache<NSString, NSImage>` in `SharedThumbnail.swift`, DELETED in C3 once
//  every call site had moved), each of them a root cause 036 §1.4 names:
//
//   1. **Bucketed.** A cell ~150 pt wide on a 2× display needs ~300 px, not the
//      512 px the on-disk tier stores. Decoding to a bucket means a smaller
//      texture, no resample at draw, and less cache pressure per item.
//   2. **Byte-budgeted.** `ThumbnailCache` is `countLimit = 512` with no cost, so
//      a 2000-item collection thrashes while the byte footprint is unbounded and
//      unknowable. Here the cost is the real decoded size and the limit is a
//      fraction of physical memory, with NO count limit.
//   3. **Fully decoded, off-main.** `NSImage(data:)` defers the pixel decode to
//      first *draw* — which happens on the main thread, mid-scroll, exactly when
//      a band crossing brings new cells on screen. 036 §5 names this as the prime
//      suspect for the residual jank at 200 items, and it measures out: over the
//      512 px on-disk tier file the grid actually loads, `NSImage(data:)` costs
//      0.11 ms to build and **1.07 ms at first draw**, while this pipeline pays
//      0.6–1.9 ms off-main and **0.12–0.30 ms at draw**. So ~0.9 ms per newly
//      visible cell moves off the main thread — call it 8–11 ms per band crossing
//      at 8–12 new cells. Real, and the right order of magnitude for the measured
//      44 ms worst frame, but NOT by itself obviously the whole of it; see the
//      change-log entry for what that implies for the 036 §5 prediction.
//
//      A caveat worth recording so nobody re-derives it: the eager-decode win
//      comes from `CGImageSourceCreateThumbnailAtIndex` returning an
//      already-rasterized bitmap, NOT from
//      `kCGImageSourceShouldCacheImmediately`. Measured with the flag on and off
//      across two buckets, create and first-draw times were identical to within
//      noise — for THIS decode path the flag is a no-op. It is still passed
//      (correct by intent, and load-bearing the moment anything switches to
//      `CGImageSourceCreateImageAtIndex`), but it is not the mechanism.
//
//  The decode itself is NOT reimplemented here — it is the same
//  ``ImageDecoding`` the ingestion package already uses for thumbnail
//  generation, perceptual hashing and color extraction. Only the caching,
//  coalescing and scheduling live here.
//
//  The API is `hash` + `url` + `bucket` and nothing else — no SwiftUI types — so
//  the SwiftUI cells (C3) and an `NSCollectionViewPrefetching` coordinator
//  (Workstream A) can both drive it unchanged.
//

import AtelierIngestion
import CoreGraphics
import Foundation
import OSLog

// MARK: - The bucket ladder (pure)

/// The pixel ladder thumbnails are decoded to, ascending.
///
/// Coarse on purpose: most density steps (⌘±) land in the same bucket and
/// re-decode nothing (036 §4 C2). 512 is the **tier ceiling** — the on-disk
/// thumbnail tier is 512 px, so asking for more cannot add detail, only waste.
nonisolated let thumbnailPixelBuckets: [Int] = [128, 192, 256, 384, 512]

/// The bucket to decode a cell of `pointLongSide` points at `scale` backing
/// pixels per point, snapped **UP** so the bitmap is never upscaled at draw.
///
/// Rounds up rather than to-nearest because a bucket below the drawn size is
/// visibly soft, while one above merely costs a downscale the compositor does
/// for free. Clamped to the 512 tier ceiling.
nonisolated func thumbnailPixelBucket(pointLongSide: CGFloat, scale: CGFloat) -> Int {
    let safeScale = (scale.isFinite && scale > 1) ? scale : 1
    let safeSide = (pointLongSide.isFinite && pointLongSide > 0) ? pointLongSide : 0
    let pixels = safeSide * safeScale
    for bucket in thumbnailPixelBuckets where CGFloat(bucket) >= pixels { return bucket }
    return thumbnailPixelBuckets[thumbnailPixelBuckets.count - 1]
}

/// The order to consult OTHER buckets in when the requested one isn't cached,
/// so a cell can paint *something* on the very first frame rather than a hole.
///
/// **Larger buckets first, nearest of them first; only then smaller ones,
/// nearest first.** A larger bitmap downscales to the cell cleanly, so it is
/// preferred over any smaller one even when the smaller one is numerically
/// closer — a blurry upscale is the more visible artifact of the two.
nonisolated func thumbnailFallbackBuckets(for bucket: Int) -> [Int] {
    let larger = thumbnailPixelBuckets.filter { $0 > bucket }.sorted()
    let smaller = thumbnailPixelBuckets.filter { $0 < bucket }.sorted(by: >)
    return larger + smaller
}

/// The thumbnail cache's byte budget: a sixteenth of physical memory, clamped to
/// 128 MB…512 MB. Small enough to stay a good citizen on an 8 GB machine (512 MB
/// → floor 128 MB), capped so a 64 GB machine doesn't hoard 4 GB of thumbnails
/// it will never show.
nonisolated func thumbnailCacheCostLimit(physicalMemory: UInt64) -> Int {
    let floorBytes: UInt64 = 128 * 1024 * 1024
    let ceilingBytes: UInt64 = 512 * 1024 * 1024
    return Int(min(max(physicalMemory / 16, floorBytes), ceilingBytes))
}

/// Whether `cost` is a plausible `bytesPerRow * height` for a bitmap decoded to
/// `bucket` — i.e. whether the number is merely large or actually *corrupt*.
///
/// A bucket-sized bitmap costs at most `bucket² × 4` at 8 bits per component, or
/// `× 8` at 16, plus row alignment. The bound is **16×**, so it cannot fire on
/// any plausible pixel format and only trips on a nonsense value.
///
/// Separated out and pure because the branch that consumes it is unreachable
/// from a test — ``DecodedThumbnail`` computes `byteCost` in its own
/// initialiser, so a wrong one cannot be injected. This keeps the *rule* under
/// test even though the trigger is not.
nonisolated func thumbnailCostIsPlausible(cost: Int, bucket: Int) -> Bool {
    guard bucket > 0 else { return true }
    let (ceiling, overflowed) = bucket.multipliedReportingOverflow(by: bucket)
    guard !overflowed else { return true }
    let (bounded, boundOverflowed) = ceiling.multipliedReportingOverflow(by: 16)
    guard !boundOverflowed else { return true }
    return cost <= bounded
}

// MARK: - Keys

/// Identity of one decoded thumbnail: content hash at a pixel bucket.
nonisolated struct ThumbnailKey: Hashable, Sendable {
    let hash: String
    let bucket: Int

    /// The `NSCache` key — `"hash#bucket"` per 036 §4 C1.
    var cacheKey: String { "\(hash)#\(bucket)" }
}

/// One unit of work for the pipeline. `url` is the on-disk thumbnail tier file.
nonisolated struct ThumbnailRequest: Sendable {
    let hash: String
    let url: URL
    let bucket: Int

    init(hash: String, url: URL, bucket: Int) {
        self.hash = hash
        self.url = url
        self.bucket = bucket
    }

    var key: ThumbnailKey { ThumbnailKey(hash: hash, bucket: bucket) }
}

// MARK: - Where decoded bitmaps live (099 · P2b, P2c)

/// The cache seam for decoded bitmaps: a keyed, budgeted box of `CGImage`s.
///
/// **Two caches stand on this, not one.** ``ThumbnailPipeline`` (small bitmaps,
/// many of them, a byte budget only) and ``DetailImageCache`` (full-res bitmaps,
/// few of them, a byte AND count budget) hold exactly the same thing under
/// exactly the same key shape — `"hash#bucket"` — and had exactly the same bug.
/// The name is the pipeline's because the pipeline got here first (P2b); the
/// contract is not thumbnail-specific and P2c deliberately widened this protocol
/// rather than writing a second one that says the same three sentences.
///
/// **Why this is a protocol and not just the `NSCache` it used to be.** An
/// `NSCache` is the right thing for the app — it hands memory back to the system
/// on its own schedule, which is exactly what a thumbnail cache should do — and
/// it is precisely the wrong thing to assert against, because that schedule is
/// not ours. `NSCache`'s own documentation says so: it "incorporates various
/// auto-eviction policies", and a caller "should not rely on a cache to store"
/// anything. Residency is a hope, not a guarantee.
///
/// `ThumbnailPipelineTests` and `ThumbnailWindowPrefetcherTests` were built on
/// that hope. Roughly one gate run in four they lost it: **fifteen tests across
/// the two suites failing together**, every one of them reducing to the same
/// sentence — `cachedExact(hash:bucket:) → nil` for a key whose decode had
/// provably run and whose `insert` had provably happened. Under a 64× budget,
/// with eight one-megabyte entries inserted, `residentUnderRoomyBudget → 0`. The
/// cache had simply been emptied between the store and the read.
///
/// Nothing about the pipeline was wrong, and nothing about `NSCache` was wrong
/// either. The tests were asserting a guarantee that does not exist. So the
/// guarantee is named here instead, and the tests are given a store that makes
/// it (`PinnedThumbnailStore`, in the test target) while the app keeps the one
/// that does not.
///
/// **The contract, which every conforming store owes and which the pipeline's
/// `store(_:for:)` is written against:**
///
///  1. `costLimit` is a byte budget. `0` means unbounded.
///  1b. `countLimit` is an entry-count budget. `0` means unbounded. Only
///     ``DetailImageCache`` sets one (five full-res bitmaps); the thumbnail
///     pipeline deliberately does not — 036 §1.4 measured a count limit
///     thrashing where a byte limit did not.
///  2. An entry whose cost exceeds the *whole* byte budget is **refused
///     outright**, not admitted-then-evicted. This is `NSCache`'s real behaviour
///     and it is the reason ``ThumbnailPipeline/store(_:for:)`` clamps; see the
///     measurement recorded there and in `.change-log/284`.
///  3. Anything else may be evicted whenever the store likes. A store is
///     permitted to keep everything; none is required to.
///
/// Implementations must be thread-safe and must never call back into their
/// caller: ``ThumbnailPipeline/prefetch(_:)`` and its `pump` read the store
/// while holding the pipeline's lock.
nonisolated protocol ThumbnailStore: AnyObject, Sendable {
    /// The byte budget. `0` means no limit.
    var costLimit: Int { get }
    /// The entry-count budget. `0` means no limit.
    var countLimit: Int { get }
    /// The bitmap stored under `key`, if the store still has it.
    func image(forKey key: String) -> CGImage?
    /// Offer `image` to the store at `cost` bytes. May be refused (rule 2) or
    /// evicted later (rule 3) — neither is an error.
    func insert(_ image: CGImage, forKey key: String, cost: Int)
}

/// The production store: an `NSCache`, cost-bounded, and by default with **no
/// count limit**.
///
/// Cost, NOT count, for thumbnails: `ThumbnailCache`'s `countLimit = 512` is what
/// thrashes at target scale (036 §1.4), so the pipeline leaves `countLimit` at
/// its `0` default on purpose and ``countLimit`` is exposed so a test can say
/// that out loud without asserting on residency.
///
/// ``DetailImageCache`` is the one caller that asks for a count budget, and it
/// has the opposite problem: five full-res bitmaps, each big enough that the byte
/// budget alone would let a handful of panoramas fill it (036 §3 B2).
nonisolated final class NSCacheThumbnailStore: ThumbnailStore, @unchecked Sendable {
    /// `NSCache` needs a class value. `Box` also lets a real byte cost be charged
    /// instead of a meaningless count limit. `nonisolated` because it is built on
    /// the DECODE thread (the target defaults to main-actor isolation).
    private nonisolated final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    let costLimit: Int

    /// - Parameter countLimit: `0` (the default, and what the thumbnail pipeline
    ///   takes) means no count limit at all. ``DetailImageCache`` passes five.
    init(costLimit: Int, countLimit: Int = 0) {
        self.costLimit = costLimit
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
    }

    /// `NSCache`'s count limit, read back for the configuration tests. `0` is
    /// "no limit", which is the whole point of this cache for thumbnails.
    var countLimit: Int { cache.countLimit }

    func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, forKey key: String, cost: Int) {
        cache.setObject(Box(image), forKey: key as NSString, cost: cost)
    }
}

// MARK: - The pipeline

/// Process-wide decoded-thumbnail cache with coalesced loads and gated prefetch.
///
/// Thread-safe by construction: the ``ThumbnailStore`` is thread-safe on its own,
/// and the bookkeeping (in-flight map, prefetch queue) is guarded by one lock
/// held only for pointer-shuffling — never across a decode or an `await`.
nonisolated final class ThumbnailPipeline: @unchecked Sendable {
    /// The decode seam. Synchronous by design — it runs inside a detached task,
    /// and injecting it is what lets ``ThumbnailPipelineTests`` exercise
    /// coalescing, eviction and cancellation without touching the filesystem.
    typealias Decode = @Sendable (URL, Int) -> DecodedThumbnail?

    static let shared = ThumbnailPipeline()

    private let cache: ThumbnailStore
    private let decode: Decode
    private let maxConcurrentPrefetches: Int

    private let lock = NSLock()
    /// Guarded by `lock`. One task per key ⇒ N concurrent requests for the same
    /// thumbnail decode ONCE and all await the same task.
    private var inFlight: [ThumbnailKey: Task<Void, Never>] = [:]
    /// Guarded by `lock`. Which of `inFlight` are prefetches — only these are
    /// cancellable by ``cancelPrefetch(hashes:)`` and only these occupy the gate.
    private var inFlightPrefetches: Set<ThumbnailKey> = []
    /// Guarded by `lock`. FIFO of prefetches waiting on the concurrency gate.
    private var queued: [ThumbnailRequest] = []
    private var queuedKeys: Set<ThumbnailKey> = []
    private var activePrefetches = 0

    /// - Parameters:
    ///   - decode: injected for tests; defaults to the shared ImageIO decoder.
    ///   - cache: where decoded bitmaps live. Defaults to the production
    ///     ``NSCacheThumbnailStore``; a test passes a store that honours the
    ///     ``ThumbnailStore`` contract *and* keeps what it is given, because
    ///     `NSCache` does not promise the second half (099 · P2b).
    ///   - maxConcurrentPrefetches: the 036 §4 C1 gate — background prefetching
    ///     must never starve the decode lanes a visible cell needs.
    init(
        decode: @escaping Decode = ThumbnailPipeline.imageIODecode,
        cache: ThumbnailStore,
        maxConcurrentPrefetches: Int = 4
    ) {
        self.decode = decode
        self.cache = cache
        self.maxConcurrentPrefetches = max(1, maxConcurrentPrefetches)
    }

    /// The production shape: an `NSCache` at `totalCostLimit` bytes.
    ///
    /// Kept as its own initialiser so every app call site — and
    /// ``ThumbnailPipeline/shared`` — reads exactly as it did before the store
    /// became a seam.
    convenience init(
        decode: @escaping Decode = ThumbnailPipeline.imageIODecode,
        totalCostLimit: Int = thumbnailCacheCostLimit(
            physicalMemory: ProcessInfo.processInfo.physicalMemory),
        maxConcurrentPrefetches: Int = 4
    ) {
        self.init(
            decode: decode,
            cache: NSCacheThumbnailStore(costLimit: totalCostLimit),
            maxConcurrentPrefetches: maxConcurrentPrefetches)
    }

    /// The production decoder: one ImageIO decode to the bucket, EXIF-transformed,
    /// **pixels forced now** on this background thread.
    static let imageIODecode: Decode = { url, bucket in
        try? ImageDecoding.decodedThumbnail(
            from: url, maxPixelSize: bucket, cacheImmediately: true)
    }

    // MARK: Synchronous reads

    /// A cache hit at exactly `bucket`, or nil. Thread-safe; cheap enough for the
    /// render path.
    func cachedExact(hash: String, bucket: Int) -> CGImage? {
        cache.image(forKey: ThumbnailKey(hash: hash, bucket: bucket).cacheKey)
    }

    /// The best cached bitmap for `hash` at `bucket`: the exact bucket if
    /// present, else the best fallback per ``thumbnailFallbackBuckets(for:)``.
    ///
    /// Returns the bucket it actually found so the caller can tell an exact hit
    /// from a stand-in and decide whether to request the exact one (C2/C3).
    func cachedEntry(hash: String, bucket: Int) -> (image: CGImage, bucket: Int)? {
        if let exact = cachedExact(hash: hash, bucket: bucket) { return (exact, bucket) }
        for candidate in thumbnailFallbackBuckets(for: bucket) {
            if let hit = cachedExact(hash: hash, bucket: candidate) { return (hit, candidate) }
        }
        return nil
    }

    /// Bucket-tolerant synchronous hit — the instant-paint path (036 §4 C1).
    func cached(hash: String, bucket: Int) -> CGImage? {
        cachedEntry(hash: hash, bucket: bucket)?.image
    }

    // MARK: Visible loads

    /// Decode (or join an in-flight decode of) the thumbnail for a VISIBLE cell.
    ///
    /// Runs at `.userInitiated`. If a prefetch for the same key is still queued
    /// behind the gate it is pulled out and started now; if one is already
    /// running, this awaits it (and Swift's priority escalation raises that
    /// task's priority for the duration) — either way the decode happens once.
    @discardableResult
    func image(hash: String, url: URL, bucket: Int) async -> CGImage? {
        let request = ThumbnailRequest(hash: hash, url: url, bucket: bucket)
        if let hit = cachedExact(hash: hash, bucket: bucket) { return hit }
        // `join` returns nil when the bitmap landed in the cache between that read
        // and the lock — there is then nothing to await.
        if let task = join(request, visible: true) { await task.value }
        return cachedExact(hash: hash, bucket: bucket)
    }

    // MARK: Prefetch

    /// Queue background decodes at `.utility` behind the max-concurrent gate.
    /// Already-cached, in-flight and already-queued keys are skipped.
    func prefetch(_ requests: [ThumbnailRequest]) {
        lock.lock()
        for request in requests {
            let key = request.key
            guard cachedExact(hash: key.hash, bucket: key.bucket) == nil,
                  inFlight[key] == nil,
                  !queuedKeys.contains(key) else { continue }
            queued.append(request)
            queuedKeys.insert(key)
        }
        lock.unlock()
        pump()
    }

    /// Drop queued prefetches for `hashes` (any bucket) and cancel in-flight
    /// ones. Visible loads are never cancelled — scrolling past a cell that is
    /// still on screen must not blank it.
    func cancelPrefetch(hashes: [String]) {
        let targets = Set(hashes)
        guard !targets.isEmpty else { return }
        lock.lock()
        queued.removeAll { request in
            guard targets.contains(request.hash) else { return false }
            queuedKeys.remove(request.key)
            return true
        }
        let doomed = inFlightPrefetches.filter { targets.contains($0.hash) }
        let tasks = doomed.compactMap { inFlight[$0] }
        lock.unlock()
        for task in tasks { task.cancel() }
        pump()
    }

    // MARK: Internals

    /// Join the existing task for `request.key`, or start a new one — or neither,
    /// if the bitmap is already cached, in which case this returns nil and there
    /// is nothing to await. Caller must NOT hold `lock`.
    private func join(_ request: ThumbnailRequest, visible: Bool) -> Task<Void, Never>? {
        lock.lock()
        if let existing = inFlight[request.key] {
            // Promotion, in-flight edition. A visible caller is now awaiting this
            // task, so it must stop being cancellable: `inFlightPrefetches` is
            // exactly the set `cancelPrefetch(hashes:)` cancels, and cancelling
            // it here would blank a cell that is ON SCREEN — `image` would await
            // a task that skipped its decode and then read back a miss.
            // `activePrefetches` is deliberately NOT adjusted: the task really
            // does still occupy a decode slot, and `finish` decrements it from
            // the `isPrefetch` captured at creation. The `remove` there becomes
            // a no-op, which is correct.
            let promoted = visible && inFlightPrefetches.remove(request.key) != nil
            lock.unlock()
            // Emitted OUTSIDE the lock — `yield` runs a consumer's buffering, and
            // holding this lock across code that is not ours is how the pipeline
            // would acquire a deadlock it does not have today (099 · 11A).
            if promoted { events.emit(.promoted(request.key)) }
            events.emit(.joined(request.key))
            return existing
        }
        // Re-check the cache UNDER the lock, exactly as `pump` does before it
        // starts anything. `image` read the cache on its way in, unlocked, and the
        // in-flight task clears `inFlight` only AFTER `store` has run — so a caller
        // served the lock in that gap sees no task, an empty decision, and starts a
        // SECOND decode of a key whose bitmap is already resident. Nothing is lost
        // when that happens, but "N concurrent requests decode ONCE" is not what
        // the pipeline then does: measured at 32 concurrent callers over a fast
        // decode, roughly one redundant decode every three attempts, and it
        // reproduces with as few as two callers. In production that is a whole
        // extra ImageIO decode per racing cell, on the scroll path, for nothing.
        if cachedExact(hash: request.key.hash, bucket: request.key.bucket) != nil {
            lock.unlock()
            return nil
        }
        if visible, queuedKeys.remove(request.key) != nil {
            // Promotion: it was waiting on the utility gate; it is visible now,
            // so it runs immediately at .userInitiated instead.
            queued.removeAll { $0.key == request.key }
        }
        let task = startLocked(request, visible: visible)
        lock.unlock()
        return task
    }

    /// Start the decode task and record it. **`lock` must be held.**
    private func startLocked(_ request: ThumbnailRequest, visible: Bool) -> Task<Void, Never> {
        let isPrefetch = !visible
        if isPrefetch {
            activePrefetches += 1
            inFlightPrefetches.insert(request.key)
        }
        let decode = self.decode
        let task = Task.detached(priority: visible ? .userInitiated : .utility) { [weak self] in
            if !Task.isCancelled, let decoded = decode(request.url, request.bucket) {
                self?.store(decoded, for: request.key)
            }
            self?.finish(request.key, wasPrefetch: isPrefetch)
        }
        inFlight[request.key] = task
        // `lock` IS held here (this method's contract), so the emit is deliberate
        // and safe only because `EventSignal` never calls back into the pipeline:
        // it takes its own lock, copies continuations, releases, and yields. The
        // alternative — returning the event to two callers to emit after their
        // own unlock — buys nothing and loses the ordering.
        events.emit(.startedDecoding(request.key))
        return task
    }

    /// Charge the real decoded size — but never more than the entire budget.
    ///
    /// A ``ThumbnailStore`` refuses an object whose cost exceeds `costLimit`
    /// outright rather than evicting to make room, and it does so SILENTLY —
    /// contract rule 2, which is `NSCache`'s real behaviour and which every store
    /// therefore owes. Charging one oversized cost does not cost you one entry,
    /// it costs you the cache: every insert is refused, every read misses, every
    /// cell re-decodes, forever, with nothing logged. Measured: at a 64 MB limit,
    /// 8 inserts at 1 MB leave 8 resident; the same 8 at limit+1 leave **zero**.
    ///
    /// Clamping keeps the bitmap a cell is actually waiting on resident. It will
    /// evict the rest of the cache to do so, which is the right trade for a
    /// thumbnail that has already been decoded and is about to be drawn — and it
    /// is what the byte budget is for. Today production cannot reach this (the
    /// ladder caps at 512 px ≈ 1 MB against a ≥128 MB budget), so this is a guard
    /// against a wrong cost, not a large one.
    private func store(_ decoded: DecodedThumbnail, for key: ThumbnailKey) {
        let cost = max(0, decoded.byteCost)
        let budget = cache.costLimit               // 0 means "no limit"
        assertCostIsPlausible(cost, for: key)
        if budget > 0, cost > budget {
            // Legitimate on a deliberately tiny budget (the tests do exactly
            // this), so it is not an error — but it does mean this cache can
            // hold one entry at a time, which is worth being able to see.
            AppLog.thumbnails.notice(
                "thumbnail cost \(cost) exceeds the whole budget \(budget); clamping")
        }
        cache.insert(
            decoded.image, forKey: key.cacheKey,
            cost: budget > 0 ? min(cost, budget) : cost)
    }

    /// Catch a `byteCost` that is *wrong* rather than merely large.
    ///
    /// This exists because the clamp in ``store(_:for:)`` is deliberately
    /// forgiving, and forgiving means SILENT: a bogus cost would degrade the
    /// cache to holding one entry at a time and show up only as scroll jank,
    /// weeks later, with nothing to point at. The check is against the bucket
    /// rather than the budget, so it identifies the actual pathology
    /// independently of how the cache happens to be configured.
    ///
    /// The bound itself lives in ``thumbnailCostIsPlausible(cost:bucket:)`` so it
    /// can be unit tested; see `.change-log/284` for the failure it watches for.
    private func assertCostIsPlausible(_ cost: Int, for key: ThumbnailKey) {
        guard !thumbnailCostIsPlausible(cost: cost, bucket: key.bucket) else { return }
        AppLog.thumbnails.error(
            """
            implausible thumbnail byteCost \(cost) at bucket \(key.bucket) — the \
            cost is corrupt, not just large; the cache will hold one entry at a \
            time until this is fixed
            """)
        assertionFailure(
            "thumbnail byteCost \(cost) implausible at bucket \(key.bucket)")
    }

    private func finish(_ key: ThumbnailKey, wasPrefetch: Bool) {
        lock.lock()
        inFlight[key] = nil
        if wasPrefetch {
            inFlightPrefetches.remove(key)
            activePrefetches = max(0, activePrefetches - 1)
        }
        lock.unlock()
        events.emit(.finished(key))
        pump()
    }

    /// Start queued prefetches up to the gate. Caller must NOT hold `lock`.
    private func pump() {
        while true {
            lock.lock()
            guard activePrefetches < maxConcurrentPrefetches, !queued.isEmpty else {
                lock.unlock()
                return
            }
            let next = queued.removeFirst()
            queuedKeys.remove(next.key)
            guard cachedExact(hash: next.hash, bucket: next.bucket) == nil,
                  inFlight[next.key] == nil else {
                lock.unlock()
                continue
            }
            _ = startLocked(next, visible: false)
            lock.unlock()
        }
    }

    /// The in-flight keys still cancellable as prefetches. Test support — this is
    /// the set a visible `join` must remove itself from.
    var cancellablePrefetchKeys: Set<ThumbnailKey> {
        lock.lock()
        defer { lock.unlock() }
        return inFlightPrefetches
    }

    /// Await everything currently in flight. Test/diagnostic support — the render
    /// path never waits on the pipeline as a whole, only on its own key.
    func waitForPendingWork() async {
        while true {
            let (tasks, stillQueued) = pendingSnapshot()
            if tasks.isEmpty && !stillQueued { return }
            for task in tasks { await task.value }
            if tasks.isEmpty { await Task.yield() }
        }
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func pendingSnapshot() -> (tasks: [Task<Void, Never>], queued: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (Array(inFlight.values), !queued.isEmpty)
    }

    // MARK: - Lifecycle signal (099 · 11A)

    /// What happened to one key. The mirror of ``DetailImageLoader/Event``; see
    /// ``EventSignal`` for why it exists and what it costs unlistened-to.
    ///
    /// `startedDecoding` is the one the tests could not previously see at all.
    /// "The prefetch decode has genuinely begun" was the premise of
    /// `visibleJoinPromotesOutOfPrefetch`, and it was established by polling the
    /// decode probe's own call count — a bounded loop reimplemented inline,
    /// twice, because the pipeline had nothing to say about itself.
    enum Event: Sendable, Equatable {
        /// A decode task was created for this key (a visible start, or a prefetch
        /// admitted through the gate).
        case startedDecoding(ThumbnailKey)
        /// A request attached to a task already running for this key.
        case joined(ThumbnailKey)
        /// A visible request took a prefetch out of the cancellable set.
        case promoted(ThumbnailKey)
        /// The decode task ended (stored, or cancelled before it stored).
        case finished(ThumbnailKey)
    }

    /// The lifecycle broadcast.
    let events = EventSignal<Event>()
}

// MARK: - Window-driven prefetching

/// Bridges a scrolling window's "what's coming up" to ``ThumbnailPipeline``'s
/// prefetch gate (036 §4 C3): each ``update(requests:keep:)`` starts the new
/// working set and cancels whatever fell out of it.
///
/// A plain class, not an observable one, deliberately — the grid holds it in
/// `@State` and mutates it from a band change, and publishing that mutation
/// would re-render the grid on exactly the frame that is already doing the most
/// work. It owns only the outstanding-hash bookkeeping the pipeline itself has
/// no reason to keep.
nonisolated final class ThumbnailWindowPrefetcher {
    private var outstanding: Set<String> = []

    /// Prefetch `requests` and cancel any previously requested hash that is
    /// neither in `requests` nor in `keep`.
    ///
    /// `keep` is the RENDERED set, and passing it is load-bearing: a hash that
    /// crossed from the prefetch ring into the visible window is gone from
    /// `requests`, but its in-flight task is the same one the now-visible cell
    /// is awaiting (``ThumbnailPipeline/image(hash:url:bucket:)`` joins rather
    /// than re-decodes). Cancelling it would blank a cell on screen.
    func update(
        requests: [ThumbnailRequest], keep: Set<String> = [],
        pipeline: ThumbnailPipeline = .shared
    ) {
        let next = Set(requests.map(\.hash))
        let dropped = outstanding.subtracting(next).subtracting(keep)
        outstanding = next
        if !dropped.isEmpty { pipeline.cancelPrefetch(hashes: Array(dropped)) }
        pipeline.prefetch(requests)
    }

    /// Cancel everything outstanding — the grid leaving the screen, or switching
    /// to a collection whose items share none of these hashes.
    func cancelAll(pipeline: ThumbnailPipeline = .shared) {
        guard !outstanding.isEmpty else { return }
        let dropped = Array(outstanding)
        outstanding = []
        pipeline.cancelPrefetch(hashes: dropped)
    }

    /// The hashes currently believed to be prefetching. Test support.
    var outstandingHashes: Set<String> { outstanding }
}
