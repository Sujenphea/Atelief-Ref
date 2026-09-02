//
//  DecodeCacheTests.swift
//  AtelierBrowseTests
//
//  098 · finding 15 — "Thumbnail decodes are neither coalesced nor cancelled."
//
//  The decoder here is a fake that counts its calls and parks on a `Gate`. That is not a
//  convenience: coalescing is a claim about what happens while a decode is IN FLIGHT, and
//  a real `CGImageSourceCreateThumbnailAtIndex` over a small JPEG finishes so fast that
//  "two callers shared one decode" could only ever be observed by luck. Nothing here
//  sleeps and then looks at a counter.
//
//  The values are boxed `Int`s with an injected cost, so the byte budget is asserted in
//  numbers a test chooses rather than in whatever a bitmap happened to weigh — which is
//  the assertion 440 wanted and `NSCache` could not give, since its eviction rules are
//  not specified.
//

import Foundation
import Synchronization
import Testing

import AtelierCaptureTestSupport
@testable import AtelierBrowse

// MARK: - Harness

/// A value with a size — the stand-in for a decoded bitmap.
private final class Bitmap: Sendable {
    let key: String
    let bytes: Int
    init(key: String, bytes: Int) {
        self.key = key
        self.bytes = bytes
    }
}

/// A decoder a test drives: it counts, it can park, and it can refuse.
private final class Decoder: Sendable {
    private struct State {
        var calls: [String] = []
        var missing: Set<String> = []
        var sizes: [String: Int] = [:]
    }
    private let state = Mutex(State())
    /// Every decode parks here when `parks` is true.
    let gate = Gate()
    private let parks: Bool

    init(parks: Bool = false) { self.parks = parks }

    var calls: [String] { state.withLock { $0.calls } }
    var callCount: Int { state.withLock { $0.calls.count } }

    /// Make `key` decode to nothing — a thumbnail tier that has not been generated.
    func makeMissing(_ key: String) { state.withLock { _ = $0.missing.insert(key) } }
    /// Make `key` weigh `bytes`.
    func size(_ key: String, _ bytes: Int) { state.withLock { $0.sizes[key] = bytes } }

    func decode(_ key: String) async -> Bitmap? {
        state.withLock { $0.calls.append(key) }
        if parks { await gate.wait() }
        let (missing, bytes) = state.withLock { ($0.missing.contains(key), $0.sizes[key]) }
        guard !missing else { return nil }
        return Bitmap(key: key, bytes: bytes ?? 1)
    }
}

private func makeCache(
    _ decoder: Decoder,
    byteBudget: Int = DecodeBudget.bytes,
    countLimit: Int = DecodeBudget.count
) -> DecodeCache<String, Bitmap> {
    DecodeCache(
        byteBudget: byteBudget, countLimit: countLimit,
        cost: { $0.bytes },
        decode: { await decoder.decode($0) })
}

@Suite("DecodeCache (098 · 15)")
struct DecodeCacheTests {

    // MARK: - Hit, miss, and nothing

    @Test("a miss decodes; a second ask for the same key does not")
    func hitsAvoidASecondDecode() async {
        let decoder = Decoder()
        let cache = makeCache(decoder)

        let first = await cache.value(for: "a")
        let second = await cache.value(for: "a")

        #expect(first === second)
        #expect(decoder.calls == ["a"])
        let stats = await cache.stats()
        #expect(stats.decodes == 1)
        #expect(stats.hits == 1)
    }

    @Test("different keys are different decodes")
    func distinctKeys() async {
        let decoder = Decoder()
        let cache = makeCache(decoder)

        _ = await cache.value(for: "a")
        _ = await cache.value(for: "b")
        #expect(decoder.calls == ["a", "b"])
        #expect(await cache.count == 2)
    }

    @Test("a key that decodes to nothing is not cached, and is not an error")
    func missingIsNotCached() async {
        // A library whose thumbnails have not been generated yet has rows and no files —
        // a normal outcome. Caching the `nil` would mean a tile stayed blank after the
        // backfill wrote the file.
        let decoder = Decoder()
        decoder.makeMissing("gone")
        let cache = makeCache(decoder)

        #expect(await cache.value(for: "gone") == nil)
        #expect(await cache.count == 0)
        #expect(await cache.value(for: "gone") == nil)
        #expect(decoder.calls == ["gone", "gone"])
    }

    // MARK: - Coalescing

    @Test("two callers for one key share ONE decode")
    func twoCallersOneDecode() async {
        let decoder = Decoder(parks: true)
        let cache = makeCache(decoder)

        // The grid tile and the switcher row resolve to the same 512-tier path by
        // construction, and the detail screen re-asks for a tier the grid may still be
        // decoding. This is what used to be two decodes of one file.
        async let first = cache.value(for: "shared")
        async let second = cache.value(for: "shared")
        #expect(await waitUntil { decoder.callCount == 1 })
        decoder.gate.open()

        let (a, b) = await (first, second)
        #expect(a === b)
        #expect(decoder.callCount == 1)
        let stats = await cache.stats()
        #expect(stats.decodes == 1)
        #expect(stats.coalesced == 1)
    }

    @Test("ten callers for one key share one decode, and all ten get the value")
    func manyCallersOneDecode() async {
        let decoder = Decoder(parks: true)
        let cache = makeCache(decoder)

        let joined = Task {
            await withTaskGroup(of: Bitmap?.self) { group in
                for _ in 0 ..< 10 { group.addTask { await cache.value(for: "one") } }
                var results: [Bitmap?] = []
                for await value in group { results.append(value) }
                return results
            }
        }
        #expect(await waitUntil { decoder.callCount == 1 })
        decoder.gate.open()

        let results = await joined.value
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 != nil })
        #expect(Set(results.map { ObjectIdentifier($0!) }).count == 1)
        #expect(decoder.callCount == 1)
        #expect(await cache.stats().coalesced == 9)
    }

    @Test("a decode that has finished stops coalescing — the next ask is a hit")
    func inFlightIsCleared() async {
        let decoder = Decoder()
        let cache = makeCache(decoder)

        _ = await cache.value(for: "a")
        _ = await cache.value(for: "a")
        let stats = await cache.stats()
        // Not "coalesced": the entry is in the store, so the second ask never reached the
        // in-flight table. A stale entry there would keep handing out one object forever.
        #expect(stats.coalesced == 0)
        #expect(stats.hits == 1)
    }

    @Test("two keys in flight at once are two decodes, not a queue")
    func concurrentKeysDoNotSerialize() async {
        let decoder = Decoder(parks: true)
        let cache = makeCache(decoder)

        async let first = cache.value(for: "a")
        async let second = cache.value(for: "b")
        // Both decodes must be STARTED before either is released — the actor must not be
        // holding one decode while another waits to begin, which is what a lock around
        // the decode itself would have done.
        #expect(await waitUntil { decoder.callCount == 2 })
        decoder.gate.open()
        _ = await (first, second)
        #expect(Set(decoder.calls) == ["a", "b"])
    }

    // MARK: - Cancellation

    @Test("a caller cancelled before its decode starts does not start one")
    func cancelledBeforeTheDecode() async {
        let decoder = Decoder()
        let cache = makeCache(decoder)

        let task = Task { await cache.value(for: "a") }
        task.cancel()
        let value = await task.value

        // A tile that has already scrolled off should not begin work. The check is inside
        // the cache rather than at the call site because the call site is a SwiftUI
        // `.task` and by then the decode has been dispatched.
        #expect(value == nil)
        #expect(decoder.callCount == 0)
    }

    @Test("a caller cancelled DURING its decode leaves nothing in the cache")
    func cancelledBeforeTheInsert() async {
        let decoder = Decoder(parks: true)
        let cache = makeCache(decoder)

        let task = Task { await cache.value(for: "a") }
        #expect(await waitUntil { decoder.callCount == 1 })
        task.cancel()
        decoder.gate.open()
        let value = await task.value

        // The second cancellation check, and this is the one with teeth: inserting a
        // bitmap nobody is waiting for evicts one that IS on screen. The decode itself is
        // not cancelled — it is shared, and another caller may still be on it.
        #expect(value == nil)
        #expect(await cache.count == 0)
        #expect(await cache.stats().abandoned == 1)
    }

    @Test("a cancelled caller does not rob the other caller sharing its decode")
    func cancellationDoesNotPoisonASharedDecode() async {
        let decoder = Decoder(parks: true)
        let cache = makeCache(decoder)

        let doomed = Task { await cache.value(for: "shared") }
        #expect(await waitUntil { decoder.callCount == 1 })
        let survivor = Task { await cache.value(for: "shared") }
        #expect(await waitUntil { await cache.stats().coalesced == 1 })

        doomed.cancel()
        decoder.gate.open()

        #expect(await doomed.value == nil)
        let value = await survivor.value
        #expect(value != nil)
        // The survivor inserts, so a third caller is a hit rather than a third decode.
        #expect(await cache.count == 1)
        _ = await cache.value(for: "shared")
        #expect(decoder.callCount == 1)
    }

    // MARK: - The budgets

    @Test("the byte budget evicts, and it is the byte budget rather than the count")
    func byteBudgetEvicts() async {
        let decoder = Decoder()
        decoder.size("a", 40)
        decoder.size("b", 40)
        decoder.size("c", 40)
        let cache = makeCache(decoder, byteBudget: 100, countLimit: 240)

        _ = await cache.value(for: "a")
        _ = await cache.value(for: "b")
        #expect(await cache.count == 2)
        #expect(await cache.bytes == 80)

        _ = await cache.value(for: "c")
        // 120 > 100, so the least-recently-used goes. Two remain and they weigh 80.
        #expect(await cache.count == 2)
        #expect(await cache.bytes == 80)
        #expect(await cache.stats().evictions == 1)
    }

    @Test("the count limit evicts even when nothing weighs anything")
    func countLimitEvicts() async {
        let decoder = Decoder()
        for key in ["a", "b", "c", "d"] { decoder.size(key, 1) }
        let cache = makeCache(decoder, byteBudget: 1_000_000, countLimit: 2)

        for key in ["a", "b", "c", "d"] { _ = await cache.value(for: key) }
        #expect(await cache.count == 2)
        #expect(await cache.stats().evictions == 2)
    }

    @Test("the victim is the least recently USED, not the least recently added")
    func evictionIsLRUByUse() async {
        let decoder = Decoder()
        for key in ["a", "b", "c"] { decoder.size(key, 10) }
        let cache = makeCache(decoder, byteBudget: 1_000_000, countLimit: 2)

        _ = await cache.value(for: "a")
        _ = await cache.value(for: "b")
        // Touch "a", so "b" becomes the oldest by USE — which is the whole point of the
        // policy on a scroll that goes back up.
        _ = await cache.value(for: "a")
        _ = await cache.value(for: "c")

        #expect(await cache.count == 2)
        // "a" is still resident: asking for it is a hit and starts no decode.
        _ = await cache.value(for: "a")
        #expect(decoder.calls == ["a", "b", "c"])
        // "b" is gone: asking for it decodes again.
        _ = await cache.value(for: "b")
        #expect(decoder.calls == ["a", "b", "c", "b"])
    }

    @Test("re-inserting a key does not double-charge the budget")
    func reinsertReplacesTheCharge() async {
        let decoder = Decoder()
        decoder.size("a", 30)
        let cache = makeCache(decoder, byteBudget: 100, countLimit: 240)

        _ = await cache.value(for: "a")
        #expect(await cache.bytes == 30)
        // The eviction-then-re-decode path, which is how a key gets inserted twice.
        await cache.purge()
        _ = await cache.value(for: "a")
        #expect(await cache.bytes == 30)
        #expect(await cache.count == 1)
    }

    @Test("one value larger than the whole budget stays, alone")
    func oversizedValueDoesNotSpin() async {
        let decoder = Decoder()
        decoder.size("huge", 1_000)
        decoder.size("small", 10)
        let cache = makeCache(decoder, byteBudget: 100, countLimit: 240)

        let value = await cache.value(for: "huge")
        // It is over budget and it is the only thing there. Evicting it would leave the
        // caller holding a reference to something the cache had already thrown away, and
        // an eviction loop with nothing left to drop is how a `while` becomes a hang.
        #expect(value != nil)
        #expect(await cache.count == 1)

        _ = await cache.value(for: "small")
        // The next insert is what clears it.
        #expect(await cache.count == 1)
        #expect(await cache.bytes == 10)
    }

    @Test("a value that weighs nothing is charged nothing rather than corrupting the sum")
    func zeroAndNegativeCosts() async {
        let decoder = Decoder()
        decoder.size("a", 0)
        decoder.size("b", 0)
        let cache = DecodeCache<String, Bitmap>(
            byteBudget: 100, countLimit: 240,
            // A cost function that can go negative — a bitmap with no backing, in the app.
            // Left unclamped it would make the total shrink on insert and never evict.
            cost: { _ in -50 },
            decode: { await decoder.decode($0) })

        _ = await cache.value(for: "a")
        _ = await cache.value(for: "b")
        #expect(await cache.bytes == 0)
        #expect(await cache.count == 2)
    }

    @Test("purge releases everything and leaves the cache usable")
    func purge() async {
        let decoder = Decoder()
        let cache = makeCache(decoder)
        _ = await cache.value(for: "a")
        _ = await cache.value(for: "b")
        #expect(await cache.count == 2)

        // What the app calls on a memory warning — the one thing `NSCache` did for free.
        await cache.purge()
        #expect(await cache.count == 0)
        #expect(await cache.bytes == 0)

        _ = await cache.value(for: "a")
        #expect(await cache.count == 1)
        #expect(decoder.calls == ["a", "b", "a"])
    }

    @Test("the shipped budgets are the ones 440 argued for")
    func defaultBudgets() {
        // Carried over rather than re-derived. If either moves, the argument at
        // `DecodeBudget` has to move with it.
        #expect(DecodeBudget.bytes == 96 * 1024 * 1024)
        #expect(DecodeBudget.count == 240)
    }

    // MARK: - The decode size

    @Test("a cell's width becomes the next 128 bucket up")
    func maxPixelRoundsUp() {
        // A 191pt column on a 3× phone is 573 pixels → 640. Rounded UP rather than to
        // nearest, because a decode smaller than the cell is a visibly soft tile and a
        // decode slightly larger is not visible at all.
        #expect(DecodeSize.maxPixel(width: 191, scale: 3) == 640)
        #expect(DecodeSize.maxPixel(width: 128, scale: 1) == 128)
        #expect(DecodeSize.maxPixel(width: 129, scale: 1) == 256)
        #expect(DecodeSize.maxPixel(width: 390, scale: 3) == 1_280)
    }

    @Test("nearby widths share one bucket, which is the point of bucketing at all")
    func nearbyWidthsShareABucket() {
        // A rotation or a layout that nudges a column by a point must not throw the
        // decode away and start again — every distinct answer here is a distinct cache key
        // for the same file.
        let bucket = DecodeSize.maxPixel(width: 190, scale: 3)
        for width in stride(from: 172.0, through: 213.0, by: 1) {
            #expect(DecodeSize.maxPixel(width: width, scale: 3) == bucket, "width \(width)")
        }
    }

    @Test("a degenerate width answers one bucket instead of trapping")
    func maxPixelEdgeCases() {
        // `GeometryReader` reports zero on its first pass, and `Int(Double.nan)` is a TRAP
        // rather than a wrong answer. The app's version of this was an unguarded
        // `Int((width * scale).rounded(.up))` on the render path.
        #expect(DecodeSize.maxPixel(width: 0, scale: 3) == DecodeSize.bucket)
        #expect(DecodeSize.maxPixel(width: -10, scale: 3) == DecodeSize.bucket)
        #expect(DecodeSize.maxPixel(width: 100, scale: 0) == DecodeSize.bucket)
        #expect(DecodeSize.maxPixel(width: .nan, scale: 3) == DecodeSize.bucket)
        #expect(DecodeSize.maxPixel(width: .infinity, scale: 3) == DecodeSize.bucket)
        #expect(DecodeSize.maxPixel(width: 1e18, scale: 3) == DecodeSize.bucket)
    }

    @Test("the answer is always a positive multiple of the bucket")
    func maxPixelIsAlwaysABucket() {
        for width in stride(from: 0.0, through: 1_200.0, by: 7) {
            for scale in [1.0, 2.0, 3.0] {
                let pixels = DecodeSize.maxPixel(width: width, scale: scale)
                #expect(pixels % DecodeSize.bucket == 0)
                #expect(pixels >= DecodeSize.bucket)
                #expect(Double(pixels) >= width * scale)
            }
        }
    }

    // MARK: - Rig

    /// Poll until `condition` holds. The cache's in-flight state is reached through an
    /// actor, so there is nothing to await before a decode has been started.
    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await condition()
    }
}
