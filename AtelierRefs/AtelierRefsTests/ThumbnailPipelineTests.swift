//
//  ThumbnailPipelineTests.swift
//  AtelierRefsTests
//
//  036 §6 — the pure bucket math, and the pipeline's scheduling contract driven
//  through an INJECTED decode closure so nothing here touches the filesystem or
//  ImageIO's real timings:
//
//   • `ThumbnailBucketTests` — the ladder snaps UP, is monotonic in both size and
//     scale, clamps at the 512 tier ceiling, and is STABLE across a density step
//     (the property 036 §4 C2 relies on to avoid re-decoding on ⌘±). Plus the
//     fallback order (larger-first) and the cache byte budget's clamp.
//   • `ThumbnailPipelineTests` — the four behaviors that are easy to get subtly
//     wrong and impossible to eyeball: N concurrent requests for one key decode
//     EXACTLY once; a miss falls back to the right neighbouring bucket; the byte
//     budget actually evicts (the thing `ThumbnailCache`'s countLimit never did);
//     and a cancelled prefetch that is still queued never decodes at all, while a
//     visible request bypasses the gate rather than waiting behind it.
//

import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Ladder

@Suite("Thumbnail buckets: the ladder")
struct ThumbnailBucketTests {

    @Test("the ladder is exactly {128, 192, 256, 384, 512}")
    func ladderMembers() {
        #expect(thumbnailPixelBuckets == [128, 192, 256, 384, 512])
    }

    @Test("a size snaps UP to the next bucket, never down")
    func snapsUp() {
        // Exact bucket boundaries stay put — 128 px needs the 128 bucket, not 192.
        #expect(thumbnailPixelBucket(pointLongSide: 128, scale: 1) == 128)
        #expect(thumbnailPixelBucket(pointLongSide: 256, scale: 1) == 256)
        // A hair over a boundary must go UP: rounding to nearest would leave the
        // bitmap smaller than the cell and visibly soft.
        #expect(thumbnailPixelBucket(pointLongSide: 128.5, scale: 1) == 192)
        #expect(thumbnailPixelBucket(pointLongSide: 193, scale: 1) == 256)
        // Well inside a bucket.
        #expect(thumbnailPixelBucket(pointLongSide: 100, scale: 1) == 128)
    }

    @Test("scale multiplies: a 150 pt cell needs 300 px on a 2x display")
    func scaleIsApplied() {
        #expect(thumbnailPixelBucket(pointLongSide: 150, scale: 1) == 192)
        #expect(thumbnailPixelBucket(pointLongSide: 150, scale: 2) == 384)
    }

    @Test("512 is the tier ceiling — nothing exceeds it")
    func ceiling() {
        #expect(thumbnailPixelBucket(pointLongSide: 512, scale: 1) == 512)
        #expect(thumbnailPixelBucket(pointLongSide: 513, scale: 1) == 512)
        #expect(thumbnailPixelBucket(pointLongSide: 400, scale: 2) == 512)
        #expect(thumbnailPixelBucket(pointLongSide: 4000, scale: 3) == 512)
    }

    @Test("degenerate inputs clamp instead of trapping")
    func degenerateInputs() {
        // A scale below 1 (or a garbage one) must not SHRINK the request.
        #expect(thumbnailPixelBucket(pointLongSide: 200, scale: 0) == 256)
        #expect(thumbnailPixelBucket(pointLongSide: 200, scale: -3) == 256)
        #expect(thumbnailPixelBucket(pointLongSide: 200, scale: .nan) == 256)
        // A zero/negative/NaN cell (pre-layout) yields the smallest bucket.
        #expect(thumbnailPixelBucket(pointLongSide: 0, scale: 2) == 128)
        #expect(thumbnailPixelBucket(pointLongSide: -50, scale: 2) == 128)
        #expect(thumbnailPixelBucket(pointLongSide: .nan, scale: 2) == 128)
    }

    @Test("monotonic in point size — growing a cell never shrinks its bucket")
    func monotonicInSize() {
        var previous = 0
        for tenths in 0...6000 {
            let bucket = thumbnailPixelBucket(pointLongSide: CGFloat(tenths) / 10, scale: 2)
            #expect(bucket >= previous)
            previous = bucket
        }
        #expect(previous == 512)
    }

    @Test("monotonic in scale")
    func monotonicInScale() {
        var previous = 0
        for hundredths in 100...400 {
            let bucket = thumbnailPixelBucket(
                pointLongSide: 150, scale: CGFloat(hundredths) / 100)
            #expect(bucket >= previous)
            previous = bucket
        }
    }

    @Test("a density step usually stays in-bucket, so it re-decodes nothing")
    func densityStepStability() {
        // 036 §4 C2's premise: the ladder is coarse enough that neighbouring
        // density steps share a bucket. A 2x grid stepping across 140…191 pt
        // stays on 384 the whole way.
        let buckets = stride(from: CGFloat(140), through: 191, by: 1).map {
            thumbnailPixelBucket(pointLongSide: $0, scale: 2)
        }
        #expect(Set(buckets) == [384])
        // And when a step DOES cross a boundary it moves exactly one rung, so the
        // cached neighbour is always the immediate fallback.
        #expect(thumbnailPixelBucket(pointLongSide: 191, scale: 2) == 384)
        #expect(thumbnailPixelBucket(pointLongSide: 200, scale: 2) == 512)
    }
}

@Suite("Thumbnail buckets: fallback order and byte budget")
struct ThumbnailFallbackTests {

    @Test("fallbacks prefer LARGER buckets, nearest first, before any smaller one")
    func fallbackOrder() {
        // 192 is numerically closer to 256 than 384 is, but it would have to be
        // upscaled — a blurry stand-in. The clean downscale wins.
        #expect(thumbnailFallbackBuckets(for: 256) == [384, 512, 192, 128])
    }

    @Test("fallbacks at the ends of the ladder")
    func fallbackAtEnds() {
        #expect(thumbnailFallbackBuckets(for: 128) == [192, 256, 384, 512])
        #expect(thumbnailFallbackBuckets(for: 512) == [384, 256, 192, 128])
    }

    @Test("every fallback list is a permutation of the other buckets")
    func fallbacksAreComplete() {
        for bucket in thumbnailPixelBuckets {
            let fallbacks = thumbnailFallbackBuckets(for: bucket)
            #expect(fallbacks.count == thumbnailPixelBuckets.count - 1)
            #expect(!fallbacks.contains(bucket))
            #expect(Set(fallbacks) == Set(thumbnailPixelBuckets).subtracting([bucket]))
        }
    }

    @Test("the cache budget is a sixteenth of RAM, clamped to 128…512 MB")
    func costLimitClamp() {
        let mb = 1024 * 1024
        // 4 GB machine: 256 MB, inside the range.
        #expect(thumbnailCacheCostLimit(physicalMemory: 4 * 1024 * UInt64(mb)) == 256 * mb)
        // 1 GB: 64 MB → clamped UP to the 128 MB floor.
        #expect(thumbnailCacheCostLimit(physicalMemory: 1024 * UInt64(mb)) == 128 * mb)
        // 64 GB: 4 GB → clamped DOWN to the 512 MB ceiling.
        #expect(thumbnailCacheCostLimit(physicalMemory: 64 * 1024 * UInt64(mb)) == 512 * mb)
        // Exactly on the ceiling boundary (8 GB → 512 MB).
        #expect(thumbnailCacheCostLimit(physicalMemory: 8 * 1024 * UInt64(mb)) == 512 * mb)
        #expect(thumbnailCacheCostLimit(physicalMemory: 0) == 128 * mb)
    }

    @Test("a real decoded cost is plausible at every bucket, at 8 and 16 bpc")
    func realCostsArePlausible() {
        for bucket in thumbnailPixelBuckets {
            // 8-bit RGBA, the production format.
            #expect(thumbnailCostIsPlausible(cost: bucket * bucket * 4, bucket: bucket))
            // 16 bits per component — still well inside the bound, so widening
            // the decode format can never trip the guard on its own.
            #expect(thumbnailCostIsPlausible(cost: bucket * bucket * 8, bucket: bucket))
            // Generous row alignment on top of that.
            #expect(thumbnailCostIsPlausible(cost: bucket * bucket * 8 + bucket * 64,
                                             bucket: bucket))
        }
    }

    @Test("a corrupt cost is caught")
    func corruptCostIsImplausible() {
        #expect(!thumbnailCostIsPlausible(cost: 256 * 256 * 17, bucket: 256))
        #expect(!thumbnailCostIsPlausible(cost: 512 * 1024 * 1024, bucket: 128))
        #expect(!thumbnailCostIsPlausible(cost: Int.max, bucket: 512))
    }

    @Test("the bound never traps and never false-positives on degenerate input")
    func plausibilityIsTotal() {
        // A zero/negative bucket carries no information, so nothing is claimed.
        #expect(thumbnailCostIsPlausible(cost: Int.max, bucket: 0))
        #expect(thumbnailCostIsPlausible(cost: Int.max, bucket: -1))
        // A bucket large enough to overflow the bound must not trap — the guard
        // exists to report a bug, never to become one.
        #expect(thumbnailCostIsPlausible(cost: Int.max, bucket: Int.max))
        #expect(thumbnailCostIsPlausible(cost: 0, bucket: 512))
    }
}

// MARK: - Pipeline test support

/// A square RGBA bitmap of `side` px. `side` doubles as an identity marker: the
/// injected decoder builds the image at the bucket it was asked for, so a test
/// can read `image.width` and see WHICH bucket a cache hit came from.
/// `nonisolated` — a pure CGImage factory, called from the probe's off-main decode.
private nonisolated func makeImage(side: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
}

/// Stands in for ImageIO: records every decode by hash, and can BLOCK chosen
/// hashes until ``release()`` so a test can hold the concurrency gate open and
/// observe queueing, promotion and cancellation deterministically instead of by
/// timing.
///
/// Two properties of that block are load-bearing, and both are here because the
/// original `DispatchSemaphore(value: 0)` version hung the entire test runner
/// indefinitely instead of failing in seconds (`.change-log/330`):
///
///  • **It is a LATCH, not a counting semaphore.** ``release()`` opens the gate
///    for good, so a decode that starts after it does not block. A counting
///    semaphore released once leaves any *second* decode of a blocked hash
///    waiting forever — and `Task.detached` runs on the cooperative pool, which
///    is only `activeProcessorCount` threads wide, so each such waiter
///    permanently retires a thread from the pool. `outstandingIsTheLatestWindow`
///    leaked one on EVERY run that way.
///  • **The wait is BOUNDED.** On timeout it sets ``timedOutWaitingForRelease``
///    and proceeds, so the test reaches its assertions and fails rather than
///    stalling the suite. An unbounded wait in a test body is what turns a
///    seven-second failure into a silent nineteen-minute hang.
///
// `nonisolated` to match its `@unchecked Sendable`: `decode` is handed to the
// pipeline as a `@Sendable` closure and runs off the main actor.
nonisolated private final class DecodeProbe: @unchecked Sendable {
    /// How long a blocked decode waits for ``release()`` before giving up. Long
    /// enough that a merely slow machine never trips it, short enough that the
    /// suite still finishes.
    static let releaseTimeout: TimeInterval = 10

    /// Doubles as the mutex for everything below — `NSCondition` is an
    /// `NSLocking`, and it drops the lock while waiting, so a blocked decode
    /// never keeps another one from recording its call.
    private let condition = NSCondition()
    private var calls: [String] = []
    private var blocked: Set<String> = []
    private var sawMainThread = false
    private var released = false
    private var timedOut = false

    init(blocking: Set<String> = []) { blocked = blocking }

    /// The hash is carried in the URL's last path component.
    func decode(url: URL, bucket: Int) -> DecodedThumbnail? {
        let hash = url.lastPathComponent
        let onMain = Thread.isMainThread
        condition.lock()
        calls.append(hash)
        if onMain { sawMainThread = true }
        if blocked.contains(hash) {
            let deadline = Date().addingTimeInterval(Self.releaseTimeout)
            while !released {
                if !condition.wait(until: deadline) {
                    timedOut = true
                    break
                }
            }
        }
        condition.unlock()
        return DecodedThumbnail(image: makeImage(side: bucket))
    }

    /// True if ANY decode ran on the main thread — the property that must never
    /// hold, whatever else changes about scheduling.
    var everRanOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return sawMainThread
    }

    /// True if any blocked decode gave up waiting. Assert on it: it means the
    /// test's premise did not hold, and without the bound it would have hung.
    var timedOutWaitingForRelease: Bool {
        condition.lock()
        defer { condition.unlock() }
        return timedOut
    }

    func callCount(_ hash: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return calls.filter { $0 == hash }.count
    }

    var totalCalls: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls.count
    }

    /// Open the latch: every blocked decode proceeds, now and in future.
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private func url(_ hash: String) -> URL { URL(fileURLWithPath: "/tmp/atelier-test/\(hash)") }

private func request(_ hash: String, bucket: Int = 256) -> ThumbnailRequest {
    ThumbnailRequest(hash: hash, url: url(hash), bucket: bucket)
}

/// A pipeline over a ``PinnedThumbnailStore`` — the only cache these two suites
/// may read a residency assertion out of (099 · P2b).
///
/// Every test below eventually says "this key is cached" or "this key is not",
/// and against the production `NSCache` that is a bet, not an assertion: it
/// evicts on a schedule of its own and one gate run in four it took the whole
/// cache with it, failing fifteen tests across both suites at once. See
/// ``PinnedThumbnailStore`` for the failure text and why the pipeline itself was
/// never at fault. The app still uses `NSCache`; only these suites do not.
///
/// `totalCostLimit: 0` — unbounded — is the default here on purpose. The
/// scheduling tests are about coalescing, promotion and cancellation, and a byte
/// budget none of them asked for is one more reason a lookup could miss. The two
/// tests that ARE about the budget pass their own.
private func pinnedPipeline(
    decode: @escaping ThumbnailPipeline.Decode,
    totalCostLimit: Int = 0,
    maxConcurrentPrefetches: Int = 4
) -> ThumbnailPipeline {
    ThumbnailPipeline(
        decode: decode,
        cache: PinnedThumbnailStore(costLimit: totalCostLimit),
        maxConcurrentPrefetches: maxConcurrentPrefetches)
}

// MARK: - Pipeline

/// The time limit is not decoration. Every test below drives real concurrency
/// through a pipeline that hands work to detached tasks, so a scheduling bug
/// shows up as *nothing happening* — and an unbounded await inside a test body
/// stalls the whole runner with `xcodebuild` sitting at 0% CPU and no output. The
/// probe bounds its own waits; this is the outer bound that holds whatever else
/// is added here later.
@Suite("ThumbnailPipeline: coalescing, fallback, eviction, prefetch",
       .timeLimit(.minutes(1)))
struct ThumbnailPipelineTests {

    @Test("N concurrent requests for one key decode EXACTLY once")
    func concurrentRequestsCoalesce() async {
        // "a" blocks, so all 32 requests pile onto the same in-flight task rather
        // than trickling in after it finished — this is the real coalescing case,
        // not a cache-hit race that would pass vacuously.
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode)

        // Release once all 32 have ATTACHED — one `startedDecoding` plus 31
        // `joined`. Counted, not waited out: the 80 ms this replaces was a bet
        // that 32 task-group members reach `join` before the decode is unblocked,
        // and it is exactly the bet a loaded machine loses (099 · 11A).
        let attached = EventRecorder(pipeline.events.stream())
        async let unblock: Void = {
            await attached.wait(forAtLeast: 32) { event in
                switch event {
                case .startedDecoding, .joined: true
                default: false
                }
            }
            probe.release()
        }()

        let images = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await pipeline.image(hash: "a", url: url("a"), bucket: 256) != nil
                }
            }
            var results: [Bool] = []
            for await ok in group { results.append(ok) }
            return results
        }
        await unblock

        #expect(images.count == 32)
        #expect(images.allSatisfy { $0 })
        #expect(probe.callCount("a") == 1)
        #expect(!probe.timedOutWaitingForRelease)
    }

    @Test("N concurrent requests still decode once when the decode is FAST")
    func concurrentRequestsCoalesceWithAFastDecode() async {
        // The companion to `concurrentRequestsCoalesce`, and the one that catches
        // the bug that test could only ever HANG on.
        //
        // Blocking the decode holds the task in flight while all 32 callers pile
        // on, so every one of them takes `join`'s in-flight branch. That is the
        // easy half. The hard half is a decode that FINISHES while later callers
        // are still on their way in: `image` reads the cache outside the lock, and
        // `finish` clears `inFlight` only AFTER `store` has run, so a caller that
        // missed the cache and was then served the lock after `finish` sees no
        // in-flight task, no reason not to start one — and re-decodes a key whose
        // bitmap is already cached. Nothing is lost, but "decode ONCE" is not what
        // happens, and in the blocking test above that second decode is what waits
        // forever on a gate that is only ever opened once.
        //
        // Measured against the pre-fix pipeline: ~110 extra decodes per 300
        // iterations at 32 callers, and it reproduces with as few as 2.
        for i in 0..<40 {
            let probe = DecodeProbe()
            let pipeline = pinnedPipeline(decode: probe.decode)
            let hash = "h\(i)"

            let images = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<32 {
                    group.addTask {
                        await pipeline.image(hash: hash, url: url(hash), bucket: 256) != nil
                    }
                }
                var results: [Bool] = []
                for await ok in group { results.append(ok) }
                return results
            }

            #expect(images.allSatisfy { $0 })
            #expect(probe.callCount(hash) == 1, "iteration \(i) decoded \(probe.callCount(hash))×")
        }
    }

    @Test("no decode EVER runs on the main thread — visible or prefetch")
    @MainActor
    func decodeNeverRunsOnMain() async {
        // Called FROM the main actor, which is the only way the render path ever
        // calls it: if `image` were not hopping off, the decode would inherit
        // this isolation and land a bitmap decode mid-scroll on the main thread —
        // 036 §5's named suspect. `Task.detached` is what prevents that, and this
        // is the regression guard on it.
        dispatchPrecondition(condition: .onQueue(.main))
        let probe = DecodeProbe()
        let pipeline = pinnedPipeline(decode: probe.decode)

        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 256)
        pipeline.prefetch([request("b"), request("c")])
        await pipeline.waitForPendingWork()

        #expect(probe.totalCalls == 3)
        #expect(!probe.everRanOnMainThread)
    }

    @Test("a second request after completion is served from cache, not re-decoded")
    func cachedRequestDoesNotDecodeAgain() async {
        let probe = DecodeProbe()
        let pipeline = pinnedPipeline(decode: probe.decode)

        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 256)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 256)
        pipeline.prefetch([request("a")])
        await pipeline.waitForPendingWork()

        #expect(probe.callCount("a") == 1)
        #expect(pipeline.cachedExact(hash: "a", bucket: 256) != nil)
    }

    @Test("an exact hit beats any fallback")
    func exactHitWins() async {
        let probe = DecodeProbe()
        let pipeline = pinnedPipeline(decode: probe.decode)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 256)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 512)

        let entry = pipeline.cachedEntry(hash: "a", bucket: 256)
        #expect(entry?.bucket == 256)
        #expect(entry?.image.width == 256)
    }

    @Test("a miss falls back to the nearest LARGER cached bucket")
    func fallsBackToLargerBucket() async {
        let probe = DecodeProbe()
        let pipeline = pinnedPipeline(decode: probe.decode)
        // Cache one smaller (192) and one larger (384) than the 256 requested.
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 192)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 384)

        let entry = pipeline.cachedEntry(hash: "a", bucket: 256)
        #expect(entry?.bucket == 384)
        #expect(entry?.image.width == 384)
        #expect(pipeline.cachedExact(hash: "a", bucket: 256) == nil)
    }

    @Test("with only smaller buckets cached, the nearest smaller one is used")
    func fallsBackToSmallerWhenNoLargerExists() async {
        let probe = DecodeProbe()
        let pipeline = pinnedPipeline(decode: probe.decode)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 128)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 192)

        let entry = pipeline.cachedEntry(hash: "a", bucket: 384)
        #expect(entry?.bucket == 192)
        #expect(pipeline.cached(hash: "a", bucket: 384)?.width == 192)
    }

    @Test("fallback never crosses hashes")
    func fallbackIsPerHash() async {
        let probe = DecodeProbe()
        let pipeline = pinnedPipeline(decode: probe.decode)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 384)
        #expect(pipeline.cachedEntry(hash: "b", bucket: 256) == nil)
    }

    @Test("the byte budget evicts; a large budget does not")
    func costBasedEviction() async {
        // Each decode is a 512x512 RGBA bitmap ≈ 1 MB of real cost.
        let side = 512
        let cost = makeImage(side: side).bytesPerRow * side
        #expect(cost > 1_000_000)

        // Budget for ~2 entries, insert 8.
        let tightProbe = DecodeProbe()
        let tight = pinnedPipeline(decode: tightProbe.decode, totalCostLimit: cost * 2)
        for i in 0..<8 {
            _ = await tight.image(hash: "k\(i)", url: url("k\(i)"), bucket: side)
        }
        let residentUnderTightBudget = (0..<8).filter {
            tight.cachedExact(hash: "k\($0)", bucket: side) != nil
        }.count
        #expect(residentUnderTightBudget < 8)

        // The control: same inserts, ample budget → nothing is evicted, so the
        // eviction above is attributable to the cost limit and not to the images
        // being dropped for some unrelated reason.
        let roomyProbe = DecodeProbe()
        let roomy = pinnedPipeline(decode: roomyProbe.decode, totalCostLimit: cost * 64)
        for i in 0..<8 {
            _ = await roomy.image(hash: "k\(i)", url: url("k\(i)"), bucket: side)
        }
        let residentUnderRoomyBudget = (0..<8).filter {
            roomy.cachedExact(hash: "k\($0)", bucket: side) != nil
        }.count
        #expect(residentUnderRoomyBudget == 8)
    }

    @Test("an entry costing more than the WHOLE budget is still cached, not dropped")
    func oversizedEntryIsClampedNotDropped() async {
        // `NSCache` refuses an object whose cost exceeds `totalCostLimit` outright
        // and says nothing, so an over-charged entry does not evict one thing — it
        // makes the cache hold NOTHING, permanently. Charging at most the budget
        // is what keeps that failure from being silent and total.
        let side = 512
        let probe = DecodeProbe()
        let oneEntry = makeImage(side: side).bytesPerRow * side
        let pipeline = pinnedPipeline(decode: probe.decode, totalCostLimit: oneEntry / 2)

        _ = await pipeline.image(hash: "a", url: url("a"), bucket: side)

        // Without the clamp this is nil: the insert is refused on arrival and the
        // cache holds nothing at all. Nothing further is asserted — which entry
        // survives once several oversized ones compete is `NSCache`'s discretion,
        // and pinning it here would be asserting a guarantee it does not make.
        #expect(pipeline.cachedExact(hash: "a", bucket: side) != nil)
    }

    @Test("a visible request joining an in-flight prefetch makes it uncancellable")
    func visibleJoinPromotesOutOfPrefetch() async {
        // The hazard: a hash crosses from the prefetch ring into the visible
        // window. `image` JOINS the running prefetch task rather than starting a
        // new one, so if that task stays in the cancellable-prefetch set, the
        // next `cancelPrefetch` for it cancels the work an on-screen cell is
        // awaiting — and the cell paints nothing.
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 1)

        // ONE subscription, two waits — which is why this records rather than
        // iterating: the promotion can arrive while the first assertion is
        // running, and a fresh stream would have missed it (099 · 11A).
        let recorder = EventRecorder(pipeline.events.stream())
        pipeline.prefetch([request("a")])
        // The decode has genuinely STARTED, so the visible request takes `join`'s
        // in-flight branch and not its queued one. This was a bounded loop over
        // the decode probe's call count, reimplemented inline here because the
        // pipeline had nothing to say about itself; it says it now.
        await recorder.wait(forAtLeast: 1) {
            if case .startedDecoding = $0 { true } else { false }
        }
        #expect(pipeline.cancellablePrefetchKeys.count == 1)

        async let visible = pipeline.image(hash: "a", url: url("a"), bucket: 256)

        // The promotion happens as `image` joins. Awaiting the event rather than
        // polling the set means this test proves the transition, not a state that
        // could also have been reached by the task simply ending.
        await recorder.wait(forAtLeast: 1) { if case .promoted = $0 { true } else { false } }
        #expect(pipeline.cancellablePrefetchKeys.isEmpty,
                "the joined task is still cancellable as a prefetch")

        // Now prove the consequence: cancelling the hash must not blank the cell.
        pipeline.cancelPrefetch(hashes: ["a"])
        probe.release()
        #expect(await visible != nil)
        #expect(!probe.timedOutWaitingForRelease)
    }

    @Test("a cancelled prefetch that is still queued never decodes")
    func cancelledPrefetchNeverDecodes() async {
        // Gate of 1: "a" starts and blocks, so "b" and "c" are stuck in the queue
        // where cancellation can still reach them. No timing assumptions.
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 1)

        pipeline.prefetch([request("a"), request("b"), request("c")])
        pipeline.cancelPrefetch(hashes: ["b", "c"])
        probe.release()
        await pipeline.waitForPendingWork()

        #expect(probe.callCount("a") == 1)
        #expect(probe.callCount("b") == 0)
        #expect(probe.callCount("c") == 0)
        #expect(pipeline.cachedExact(hash: "b", bucket: 256) == nil)
        #expect(pipeline.cachedExact(hash: "c", bucket: 256) == nil)
        #expect(pipeline.cachedExact(hash: "a", bucket: 256) != nil)
        #expect(!probe.timedOutWaitingForRelease)
    }

    @Test("cancelling one hash leaves the rest of the queue intact")
    func cancelIsSelective() async {
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 1)

        pipeline.prefetch([request("a"), request("b"), request("c")])
        pipeline.cancelPrefetch(hashes: ["b"])
        probe.release()
        await pipeline.waitForPendingWork()

        #expect(probe.callCount("b") == 0)
        #expect(probe.callCount("c") == 1)
        #expect(pipeline.cachedExact(hash: "c", bucket: 256) != nil)
        #expect(!probe.timedOutWaitingForRelease)
    }

    @Test("a visible request bypasses the prefetch gate and promotes the queued work")
    func visibleRequestBypassesGate() async {
        // "a" occupies the only prefetch slot and blocks. "b" is queued behind it.
        // A visible request for "b" must NOT wait for "a" to finish — it is pulled
        // out of the queue and run now. If the gate applied to visible loads this
        // test would deadlock until the timeout.
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 1)

        pipeline.prefetch([request("a"), request("b")])
        let image = await pipeline.image(hash: "b", url: url("b"), bucket: 256)

        #expect(image != nil)
        #expect(probe.callCount("b") == 1)
        // "a" is still blocked mid-decode, proving "b" did not wait for the slot.
        #expect(pipeline.cachedExact(hash: "a", bucket: 256) == nil)

        probe.release()
        await pipeline.waitForPendingWork()
        // The promoted key decoded exactly once — it was not decoded a second
        // time when the gate later freed up.
        #expect(probe.callCount("b") == 1)
        #expect(probe.totalCalls == 2)
        #expect(!probe.timedOutWaitingForRelease)
    }
}

// MARK: - Window-driven prefetching (036 §4 C3)

@Suite("ThumbnailWindowPrefetcher: start the new set, cancel what fell out",
       .timeLimit(.minutes(1)))
struct ThumbnailWindowPrefetcherTests {

    /// Note what is asserted and what deliberately is NOT. `ThumbnailPipeline`
    /// checks `Task.isCancelled` ONCE, before entering the decode closure, so
    /// cancellation reliably prevents work that hasn't started and is a no-op
    /// against work already inside ImageIO. Whether the blocked "a" had entered
    /// its decode when the cancel landed is a genuine race, so this asserts the
    /// deterministic half: the QUEUED entry never runs, and the new window does.
    @Test("a hash that left the window never starts if it was still queued")
    func cancelsWhatFellOut() async {
        // "a" blocks the only prefetch slot; "b" is queued behind it. The next
        // window contains neither.
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 1)
        let prefetcher = ThumbnailWindowPrefetcher()

        prefetcher.update(requests: [request("a"), request("b")], pipeline: pipeline)
        prefetcher.update(requests: [request("c")], pipeline: pipeline)
        probe.release()
        await pipeline.waitForPendingWork()

        #expect(probe.callCount("b") == 0)          // dropped from the queue
        #expect(pipeline.cachedExact(hash: "b", bucket: 256) == nil)
        #expect(pipeline.cachedExact(hash: "c", bucket: 256) != nil)  // the new set ran
        #expect(!probe.timedOutWaitingForRelease)
    }

    /// The load-bearing rule. A hash crossing from the prefetch ring INTO the
    /// visible window disappears from `requests` (rendered cells are excluded
    /// from the ring), but a visible load joins that same in-flight task — so
    /// cancelling it here would blank a cell that is on screen.
    @Test("a hash promoted into the rendered window is NOT cancelled")
    func keepSetIsNotCancelled() async {
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 2)
        let prefetcher = ThumbnailWindowPrefetcher()

        prefetcher.update(requests: [request("a")], pipeline: pipeline)
        // Next band: "a" is now RENDERED, so it is absent from the ring but present
        // in `keep`.
        prefetcher.update(requests: [request("b")], keep: ["a"], pipeline: pipeline)
        probe.release()
        await pipeline.waitForPendingWork()

        #expect(pipeline.cachedExact(hash: "a", bucket: 256) != nil)
        #expect(pipeline.cachedExact(hash: "b", bucket: 256) != nil)
        #expect(!probe.timedOutWaitingForRelease)
    }

    @Test("a hash still in the new window is not cancelled and is not re-decoded")
    func stableHashSurvives() async {
        let probe = DecodeProbe()
        let pipeline = pinnedPipeline(decode: probe.decode)
        let prefetcher = ThumbnailWindowPrefetcher()

        prefetcher.update(requests: [request("a"), request("b")], pipeline: pipeline)
        await pipeline.waitForPendingWork()
        prefetcher.update(requests: [request("b"), request("c")], pipeline: pipeline)
        await pipeline.waitForPendingWork()

        #expect(probe.callCount("b") == 1)          // cached; not decoded twice
        #expect(pipeline.cachedExact(hash: "b", bucket: 256) != nil)
    }

    @Test("cancelAll drops everything outstanding and is idempotent")
    func cancelAllClears() async {
        let probe = DecodeProbe(blocking: ["a"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 1)
        let prefetcher = ThumbnailWindowPrefetcher()

        prefetcher.update(requests: [request("a"), request("b")], pipeline: pipeline)
        prefetcher.cancelAll(pipeline: pipeline)
        prefetcher.cancelAll(pipeline: pipeline)    // no-op, not a crash
        #expect(prefetcher.outstandingHashes.isEmpty)

        probe.release()
        await pipeline.waitForPendingWork()
        // Only the queued entry is deterministically stopped — see the note on
        // `cancelsWhatFellOut` for why "a" is not asserted on.
        #expect(probe.callCount("b") == 0)
        #expect(pipeline.cachedExact(hash: "b", bucket: 256) == nil)
        #expect(!probe.timedOutWaitingForRelease)
    }

    @Test("the outstanding set tracks the latest window, not the union of all of them")
    func outstandingIsTheLatestWindow() async {
        let probe = DecodeProbe(blocking: ["a", "b", "c"])
        let pipeline = pinnedPipeline(decode: probe.decode, maxConcurrentPrefetches: 1)
        let prefetcher = ThumbnailWindowPrefetcher()

        prefetcher.update(requests: [request("a"), request("b")], pipeline: pipeline)
        #expect(prefetcher.outstandingHashes == ["a", "b"])
        prefetcher.update(requests: [request("c")], pipeline: pipeline)
        #expect(prefetcher.outstandingHashes == ["c"])

        // Drain before returning. Leaving blocked decodes running past the end of
        // a test is not tidy-up pedantry: `Task.detached` bodies occupy the
        // cooperative pool, which is only `activeProcessorCount` threads wide, and
        // "a" finishing here is what lets the gate start the still-blocked "c".
        probe.release()
        await pipeline.waitForPendingWork()
        #expect(!probe.timedOutWaitingForRelease)
    }
}

// MARK: - The store seam (099 · P2b)

/// The contract the two suites above now stand on.
///
/// `PinnedThumbnailStore` is what makes their residency assertions assertions
/// rather than bets, so the properties they lean on are checked here rather than
/// assumed: it refuses what the budget cannot hold, it evicts only when the
/// budget makes it, and it never drops anything otherwise.
@Suite("PinnedThumbnailStore: the contract the thumbnail suites assert against")
struct PinnedThumbnailStoreTests {

    @Test("an unbounded store keeps everything it is given")
    func unboundedKeepsEverything() {
        // The default the scheduling tests use. Whatever else is true of a run,
        // a key that was inserted is a key that reads back — which is precisely
        // what `NSCache` would not promise and why this type exists.
        let store = PinnedThumbnailStore()
        #expect(store.costLimit == 0)
        for i in 0..<64 {
            store.insert(makeImage(side: 128), forKey: "k\(i)", cost: 1_000_000)
        }
        #expect(store.count == 64)
        #expect((0..<64).allSatisfy { store.image(forKey: "k\($0)") != nil })
    }

    @Test("the byte budget evicts oldest-first, and only when it must")
    func budgetEvictsOldestFirst() {
        // Room for exactly three. The three most recent survive; the rest go in
        // the order they arrived.
        let store = PinnedThumbnailStore(costLimit: 300)
        for i in 0..<5 { store.insert(makeImage(side: 128), forKey: "k\(i)", cost: 100) }
        #expect(store.count == 3)
        #expect(store.image(forKey: "k0") == nil)
        #expect(store.image(forKey: "k1") == nil)
        #expect(store.image(forKey: "k2") != nil)
        #expect(store.image(forKey: "k4") != nil)
        // Nothing is evicted while the budget is not exceeded.
        let roomy = PinnedThumbnailStore(costLimit: 10_000)
        for i in 0..<5 { roomy.insert(makeImage(side: 128), forKey: "k\(i)", cost: 100) }
        #expect(roomy.count == 5)
    }

    @Test("the count budget evicts oldest-first, and only when it must")
    func countBudgetEvictsOldestFirst() {
        // Contract rule 1b, added in P2c because `DetailImageCache` carries a
        // count limit of five where the pipeline carries none. Same oldest-first
        // order as the byte budget: whichever budget bites first governs.
        let store = PinnedThumbnailStore(countLimit: 3)
        for i in 0..<5 { store.insert(makeImage(side: 128), forKey: "k\(i)", cost: 1) }
        #expect(store.countLimit == 3)
        #expect(store.count == 3)
        #expect(store.image(forKey: "k0") == nil)
        #expect(store.image(forKey: "k1") == nil)
        #expect(store.image(forKey: "k4") != nil)
        // A roomy count evicts nothing, and `0` is unbounded — the default the
        // scheduling suites take.
        let roomy = PinnedThumbnailStore(countLimit: 100)
        for i in 0..<5 { roomy.insert(makeImage(side: 128), forKey: "k\(i)", cost: 1) }
        #expect(roomy.count == 5)
        #expect(PinnedThumbnailStore().countLimit == 0)
    }

    @Test("an entry costing more than the WHOLE budget is refused outright")
    func oversizedIsRefused() {
        // Contract rule 2, and the exact `NSCache` behaviour
        // `ThumbnailPipeline.store(_:for:)`'s clamp is written against: too big
        // means refused on arrival, not admitted and then evicted. A store that
        // quietly accepted it would make that clamp untestable.
        let store = PinnedThumbnailStore(costLimit: 100)
        store.insert(makeImage(side: 128), forKey: "big", cost: 101)
        #expect(store.image(forKey: "big") == nil)
        // Exactly the budget fits — which is what the clamp charges.
        store.insert(makeImage(side: 128), forKey: "exact", cost: 100)
        #expect(store.image(forKey: "exact") != nil)
    }

    @Test("re-inserting a key replaces it without double-charging the budget")
    func reinsertReplaces() {
        // Two decodes of one key can race (a visible load and a prefetch that
        // both got past the cache check), so the same key really is written
        // twice; charging it twice would evict a bystander for no reason.
        let store = PinnedThumbnailStore(costLimit: 200)
        store.insert(makeImage(side: 128), forKey: "a", cost: 100)
        store.insert(makeImage(side: 192), forKey: "a", cost: 100)
        store.insert(makeImage(side: 128), forKey: "b", cost: 100)
        #expect(store.count == 2)
        #expect(store.image(forKey: "a")?.width == 192)
        #expect(store.image(forKey: "b") != nil)
    }
}

/// The production store, checked for the things about it that are decisions
/// rather than defaults — **without** asserting that it holds anything.
///
/// Residency is the one claim `NSCache` will not honour, and asserting it here
/// is what made fifteen tests flake. What is left is still worth pinning: the
/// budget is the number that was asked for, the pipeline gets no count limit,
/// and a caller that asks for one (``DetailImageCache``) gets exactly it.
@Suite("NSCacheThumbnailStore: cost, NOT count")
struct NSCacheThumbnailStoreTests {

    @Test("the byte budget is the one it was constructed with")
    func costLimitIsHonoured() {
        let store = NSCacheThumbnailStore(costLimit: 64 * 1024 * 1024)
        #expect(store.costLimit == 64 * 1024 * 1024)
    }

    @Test("no count limit is set — the countLimit=512 thrash must not come back")
    func noCountLimit() {
        // 036 §1.4: the `ThumbnailCache` this replaced was `countLimit = 512`
        // with no cost, which is what thrashes a 2000-item collection while the
        // byte footprint stays unknowable. `0` is `NSCache` for "no limit", and
        // it is the DEFAULT, so the pipeline gets it by not asking.
        #expect(NSCacheThumbnailStore(costLimit: 1 << 20).countLimit == 0)
        let pipelineStore = NSCacheThumbnailStore(costLimit: thumbnailCacheCostLimit(
            physicalMemory: 16 << 30))
        #expect(pipelineStore.countLimit == 0)
    }

    @Test("a count limit is set only when one is asked for (099 · P2c)")
    func countLimitWhenAsked() {
        // `DetailImageCache` is the one caller that asks. It is the same store
        // class, so the parameter has to actually reach the `NSCache` — otherwise
        // the detail cache would silently ship unbounded by count.
        let store = NSCacheThumbnailStore(costLimit: 1 << 20, countLimit: 5)
        #expect(store.countLimit == 5)
        #expect(store.costLimit == 1 << 20)
    }

    @Test("a pipeline built the production way gets an NSCache-backed store")
    func productionPipelineUsesNSCache() async {
        // The convenience initialiser is what `ThumbnailPipeline.shared` and
        // every app call site take, so it is worth one test that it still
        // reaches a real cache and a real decode rather than a test double.
        let probe = DecodeProbe()
        let pipeline = ThumbnailPipeline(decode: probe.decode, totalCostLimit: 8 << 20)
        _ = await pipeline.image(hash: "a", url: url("a"), bucket: 256)
        // Not `cachedExact != nil` — that is the assertion this whole phase is
        // about not making against an `NSCache`. The decode having run is the
        // part that is actually guaranteed.
        #expect(probe.callCount("a") == 1)
    }
}
