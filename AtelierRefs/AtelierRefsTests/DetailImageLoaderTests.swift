//
//  DetailImageLoaderTests.swift
//  AtelierRefsTests
//
//  036 §3 B2 — the full-res detail-image loader. Everything here is exercised
//  headlessly through an INJECTED decode closure (the `ThumbnailPipelineTests`
//  pattern), so nothing touches ImageIO or the filesystem:
//
//   • `DetailNeighborsTests` — the pure {prev, current, next} helper: ends,
//     single item, no-wrap, and a deleted current.
//   • `DetailBucketTests` — the pure bucket ladder: `nil`/degenerate → native,
//     snap-UP, past the top tier → native, and the `"hash#native"` key.
//   • `DetailImageLoaderTests` — coalescing (N concurrent → one decode), the
//     promoted-preload-is-not-re-decoded contract, and the load-bearing
//     `retainOnly` invariants: it cancels a preload OUTSIDE the window but NEVER a
//     preload the visible load promoted to current.
//   • `DetailImageCacheTests` — the count-AND-cost LRU actually evicts on both
//     axes, with a roomy-budget control so eviction is attributable to the limit.
//
//  The probe's decode re-checks `Task.isCancelled` after unblocking, so a cancelled
//  in-flight decode is OBSERVABLE (returns nil → not cached) — which is what makes
//  the `retainOnly` cancel/keep assertions deterministic rather than racy.
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

private func detail(id: UUID = UUID()) -> CollectionItemDetail {
    let sourceID = UUID(), assetID = UUID()
    let source = Source(id: sourceID, platform: .web, capturedAt: Date())
    let asset = Asset(
        id: assetID, kind: .image, blobHash: UUID().uuidString, mimeType: "image/png",
        width: 100, height: 100, duration: nil, fileSize: 100,
        downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
    let item = CollectionItem(id: id, collectionID: UUID(), assetID: assetID, addedAt: Date())
    return CollectionItemDetail(item: item, asset: asset, source: source)
}

private func makeImage(side: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
}

private func url(_ hash: String) -> URL { URL(fileURLWithPath: "/tmp/atelier-detail-test/\(hash)") }

/// Stands in for ImageIO. Records decodes by hash and can BLOCK chosen hashes on a
/// semaphore; a blocked decode re-checks `Task.isCancelled` after release, so a
/// cancelled in-flight decode deterministically yields `nil` (nothing cached).
private final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private let blocked: Set<String>
    private let gate = DispatchSemaphore(value: 0)

    init(blocking: Set<String> = []) { blocked = blocking }

    func decode(url: URL, bucket: Int) -> DecodedThumbnail? {
        let hash = url.lastPathComponent
        lock.lock()
        calls.append(hash)
        let shouldBlock = blocked.contains(hash)
        lock.unlock()
        if shouldBlock {
            gate.wait()
            if Task.isCancelled { return nil }
        }
        // Side doubles as an identity marker; native maps to a fixed test side so
        // the byte cost is stable.
        return DecodedThumbnail(image: makeImage(side: bucket == detailNativeBucket ? 512 : bucket))
    }

    func callCount(_ hash: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0 == hash }.count
    }
    var totalCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }
    func release() { gate.signal() }
}

// MARK: - Neighbours

@Suite("detailNeighbors: {prev, current, next}, no wrap")
struct DetailNeighborsTests {

    @Test("a middle item has both neighbours")
    func middle() {
        let items = [detail(), detail(), detail(), detail()]
        let n = detailNeighbors(items: items, currentID: items[2].item.id)
        #expect(n.current == items[2])
        #expect(n.previous == items[1])
        #expect(n.next == items[3])
    }

    @Test("the first item has no previous (no wrap)")
    func firstHasNoPrevious() {
        let items = [detail(), detail(), detail()]
        let n = detailNeighbors(items: items, currentID: items[0].item.id)
        #expect(n.previous == nil)
        #expect(n.next == items[1])
    }

    @Test("the last item has no next (no wrap)")
    func lastHasNoNext() {
        let items = [detail(), detail(), detail()]
        let n = detailNeighbors(items: items, currentID: items[2].item.id)
        #expect(n.previous == items[1])
        #expect(n.next == nil)
    }

    @Test("a single item is its own current with no neighbours")
    func singleItem() {
        let items = [detail()]
        let n = detailNeighbors(items: items, currentID: items[0].item.id)
        #expect(n.current == items[0])
        #expect(n.previous == nil)
        #expect(n.next == nil)
    }

    @Test("a deleted / unknown current yields an empty triple")
    func unknownCurrent() {
        let items = [detail(), detail()]
        #expect(detailNeighbors(items: items, currentID: UUID()) == DetailNeighbors())
        #expect(detailNeighbors(items: items, currentID: nil) == DetailNeighbors())
        #expect(detailNeighbors(items: [], currentID: items[0].item.id) == DetailNeighbors())
    }
}

// MARK: - Bucket ladder

@Suite("detailPixelBucket: native default, snap up, top-tier → native")
struct DetailBucketTests {

    @Test("the ladder is exactly {1280, 2048, 3072} with an Int.max native sentinel")
    func ladder() {
        #expect(detailPixelBuckets == [1280, 2048, 3072])
        #expect(detailNativeBucket == Int.max)
    }

    @Test("nil (B2's default) and degenerate sizes ask for native")
    func nilAndDegenerateAreNative() {
        #expect(detailPixelBucket(longSidePx: nil) == detailNativeBucket)
        #expect(detailPixelBucket(longSidePx: 0) == detailNativeBucket)
        #expect(detailPixelBucket(longSidePx: -10) == detailNativeBucket)
        #expect(detailPixelBucket(longSidePx: .nan) == detailNativeBucket)
    }

    @Test("a size snaps UP to the next tier, and past the top tier → native")
    func snapUp() {
        #expect(detailPixelBucket(longSidePx: 1000) == 1280)
        #expect(detailPixelBucket(longSidePx: 1280) == 1280)
        #expect(detailPixelBucket(longSidePx: 1281) == 2048)
        #expect(detailPixelBucket(longSidePx: 2048) == 2048)
        #expect(detailPixelBucket(longSidePx: 3072) == 3072)
        #expect(detailPixelBucket(longSidePx: 3073) == detailNativeBucket)
        #expect(detailPixelBucket(longSidePx: 9000) == detailNativeBucket)
    }

    @Test("the cache key spells the native sentinel, not a nine-digit Int.max")
    func nativeKey() {
        #expect(DetailImageKey(hash: "abc", bucket: detailNativeBucket).cacheKey == "abc#native")
        #expect(DetailImageKey(hash: "abc", bucket: 2048).cacheKey == "abc#2048")
    }
}

// MARK: - Display decode decision (036 §3 B3)

@Suite("detailDisplayDecode: preview ≤1280, FIT ladder above, zoom→native")
struct DetailDisplayDecodeTests {

    @Test("the preview tier constant is the first FIT bucket (1280)")
    func previewTier() {
        #expect(detailPreviewTierPx == 1280)
        #expect(detailPreviewTierPx == detailPixelBuckets[0])
    }

    @Test("a ≤1280 viewport at 1× reuses the preview — no blob decode")
    func previewBranch() {
        #expect(detailDisplayDecode(fitLongSidePx: 640, zoom: 1) == .preview)
        #expect(detailDisplayDecode(fitLongSidePx: 1000, zoom: 1) == .preview)
        // Boundary: exactly the preview tier is still covered by the preview.
        #expect(detailDisplayDecode(fitLongSidePx: 1280, zoom: 1) == .preview)
    }

    @Test("not-yet-measured / degenerate sizes stay on the preview — never eager native")
    func degenerateIsPreview() {
        #expect(detailDisplayDecode(fitLongSidePx: 0, zoom: 1) == .preview)
        #expect(detailDisplayDecode(fitLongSidePx: -5, zoom: 1) == .preview)
        #expect(detailDisplayDecode(fitLongSidePx: .nan, zoom: 1) == .preview)
        #expect(detailDisplayDecode(fitLongSidePx: .infinity, zoom: 1) == .preview)
    }

    @Test("above 1280 at 1× is a FIT decode; the loader snaps the raw px up the ladder")
    func fitBranch() {
        // The decision passes the RAW measured px; `detailPixelBucket` quantizes it.
        #expect(detailDisplayDecode(fitLongSidePx: 1281, zoom: 1) == .decode(targetLongSidePx: 1281))
        #expect(detailDisplayDecode(fitLongSidePx: 2000, zoom: 1) == .decode(targetLongSidePx: 2000))
        #expect(detailDisplayDecode(fitLongSidePx: 3072, zoom: 1) == .decode(targetLongSidePx: 3072))
        // …and the buckets those raw sizes resolve to (the snap-up boundaries):
        #expect(detailPixelBucket(longSidePx: 1281) == 2048)
        #expect(detailPixelBucket(longSidePx: 2000) == 2048)
        #expect(detailPixelBucket(longSidePx: 3072) == 3072)
        #expect(detailPixelBucket(longSidePx: 3073) == detailNativeBucket)
    }

    @Test("zoom>1 is ALWAYS native regardless of viewport — one crisp decode for 1×…6×")
    func zoomBranch() {
        #expect(detailDisplayDecode(fitLongSidePx: 800, zoom: 1.01) == .decode(targetLongSidePx: nil))
        #expect(detailDisplayDecode(fitLongSidePx: 2400, zoom: 2) == .decode(targetLongSidePx: nil))
        #expect(detailDisplayDecode(fitLongSidePx: 5000, zoom: 6) == .decode(targetLongSidePx: nil))
        // Exactly 1 is NOT zoomed — the size rule governs (a small viewport → preview).
        #expect(detailDisplayDecode(fitLongSidePx: 800, zoom: 1) == .preview)
    }
}

// MARK: - Loader

@Suite("DetailImageLoader: coalescing, promotion, retainOnly")
struct DetailImageLoaderCoreTests {

    private func loader(_ probe: DecodeProbe) -> DetailImageLoader {
        DetailImageLoader(cache: DetailImageCache(), decode: probe.decode)
    }

    @Test("N concurrent requests for one key decode EXACTLY once")
    func concurrentRequestsCoalesce() async {
        let probe = DecodeProbe(blocking: ["a"])
        let loader = loader(probe)

        async let unblock: Void = {
            try? await Task.sleep(nanoseconds: 80_000_000)
            probe.release()
        }()

        let oks = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await loader.displayImage(hash: "a", url: url("a"), targetLongSidePx: nil) != nil
                }
            }
            var results: [Bool] = []
            for await ok in group { results.append(ok) }
            return results
        }
        await unblock

        #expect(oks.count == 24)
        #expect(oks.allSatisfy { $0 })
        #expect(probe.callCount("a") == 1)
    }

    @Test("a promoted preload is awaited, not re-decoded")
    func promotedPreloadNotReDecoded() async {
        let probe = DecodeProbe(blocking: ["a"])
        let loader = loader(probe)

        await loader.preload(hash: "a", url: url("a"), targetLongSidePx: nil)
        async let image = loader.displayImage(hash: "a", url: url("a"), targetLongSidePx: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        probe.release()

        #expect(await image != nil)
        #expect(probe.callCount("a") == 1)   // the preload was joined, not re-run
    }

    @Test("retainOnly cancels a preload OUTSIDE the window, keeps one INSIDE")
    func retainOnlyCancelsOutsideWindow() async {
        // Both preloads are in flight and blocked; the decode re-checks
        // cancellation after release, so a cancelled one yields nil (not cached).
        let probe = DecodeProbe(blocking: ["keep", "drop"])
        let loader = loader(probe)

        await loader.preload(hash: "keep", url: url("keep"), targetLongSidePx: nil)
        await loader.preload(hash: "drop", url: url("drop"), targetLongSidePx: nil)
        await loader.retainOnly(hashes: ["keep"])   // window keeps "keep", drops "drop"
        probe.release()
        probe.release()
        await loader.waitForPendingWork()

        #expect(loader.cached(hash: "keep", targetLongSidePx: nil) != nil)
        #expect(loader.cached(hash: "drop", targetLongSidePx: nil) == nil)
    }

    @Test("retainOnly NEVER cancels a preload promoted to current — even with an empty window")
    func retainOnlyKeepsPromoted() async {
        // "c" is preloaded, then a visible displayImage promotes it (drops it from
        // the cancellable set). An adversarial empty-window retainOnly must not blank
        // it: if promotion were broken, "c" would be cancelled and the image nil.
        let probe = DecodeProbe(blocking: ["c"])
        let loader = loader(probe)

        await loader.preload(hash: "c", url: url("c"), targetLongSidePx: nil)
        async let image = loader.displayImage(hash: "c", url: url("c"), targetLongSidePx: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)   // let the promotion land
        await loader.retainOnly(hashes: [])              // would cancel "c" if still a preload
        probe.release()

        #expect(await image != nil)
        #expect(probe.callCount("c") == 1)
    }

    @Test("a cached image is served without a second decode")
    func cacheHitDoesNotReDecode() async {
        let probe = DecodeProbe()
        let loader = loader(probe)

        _ = await loader.displayImage(hash: "a", url: url("a"), targetLongSidePx: nil)
        _ = await loader.displayImage(hash: "a", url: url("a"), targetLongSidePx: nil)

        #expect(probe.callCount("a") == 1)
        #expect(loader.cached(hash: "a", targetLongSidePx: nil) != nil)
    }
}

// MARK: - Cache eviction

@Suite("DetailImageCache: count-AND-cost bounded LRU")
struct DetailImageCacheTests {

    private func insert(_ n: Int, side: Int, into cache: DetailImageCache) {
        for i in 0..<n {
            let image = makeImage(side: side)
            let cost = image.bytesPerRow * image.height
            cache.insert(image, cost: cost, for: DetailImageKey(hash: "k\(i)", bucket: detailNativeBucket))
        }
    }
    private func resident(_ n: Int, in cache: DetailImageCache) -> Int {
        (0..<n).filter {
            cache.image(for: DetailImageKey(hash: "k\($0)", bucket: detailNativeBucket)) != nil
        }.count
    }

    @Test("the byte budget evicts; a roomy budget does not")
    func costEviction() {
        let side = 512
        let cost = makeImage(side: side).bytesPerRow * side
        #expect(cost > 1_000_000)

        let tight = DetailImageCache(totalCostLimit: cost * 2, countLimit: 100)
        insert(8, side: side, into: tight)
        #expect(resident(8, in: tight) < 8)

        let roomy = DetailImageCache(totalCostLimit: cost * 64, countLimit: 100)
        insert(8, side: side, into: roomy)
        #expect(resident(8, in: roomy) == 8)
    }

    @Test("the count budget evicts; a roomy count does not")
    func countEviction() {
        let tight = DetailImageCache(totalCostLimit: 1 << 30, countLimit: 3)
        insert(8, side: 64, into: tight)
        #expect(resident(8, in: tight) < 8)

        let roomy = DetailImageCache(totalCostLimit: 1 << 30, countLimit: 100)
        insert(8, side: 64, into: roomy)
        #expect(resident(8, in: roomy) == 8)
    }
}
