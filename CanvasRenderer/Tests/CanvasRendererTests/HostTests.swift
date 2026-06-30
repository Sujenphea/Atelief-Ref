import CoreGraphics
import QuartzCore
import Testing
@testable import CanvasRenderer

// Helpers ---------------------------------------------------------------------

@MainActor
private func makeImage(side: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return ctx.makeImage()!
}

/// A fixed-geometry provider so engine tests assert exact visible sets.
private struct FixedProvider: TileProvider {
    let tiles: [Tile]
}

private func gridTiles() -> [Tile] {
    // 5×5 grid of 50×50 tiles, spaced 100 world units, ids row-major.
    var tiles: [Tile] = []
    for row in 0..<5 {
        for col in 0..<5 {
            tiles.append(Tile(id: row * 5 + col, x: Double(col) * 100, y: Double(row) * 100, w: 50, h: 50))
        }
    }
    return tiles
}

// LayerPool -------------------------------------------------------------------

@MainActor
@Suite("LayerPool")
struct LayerPoolTests {
    @Test("obtain allocates, recycle parks for reuse without re-allocating")
    func obtainRecycleReuse() {
        let pool = LayerPool()
        let a = pool.obtain()
        let b = pool.obtain()
        #expect(pool.inUseCount == 2)
        #expect(pool.allocatedCount == 2)

        pool.recycle(a)
        #expect(pool.inUseCount == 1)
        #expect(pool.freeCount == 1)
        #expect(pool.allocatedCount == 2) // still 2 allocated, one parked

        let c = pool.obtain() // should reuse the parked layer, not allocate
        #expect(c === a)
        #expect(pool.allocatedCount == 2)
        _ = b
    }

    @Test("recycle detaches the layer from its superlayer")
    func recycleDetaches() {
        let pool = LayerPool()
        let root = CALayer()
        let layer = pool.obtain()
        root.addSublayer(layer)
        #expect(layer.superlayer === root)
        pool.recycle(layer)
        #expect(layer.superlayer == nil)
    }
}

// ThumbnailCache --------------------------------------------------------------

@MainActor
@Suite("ThumbnailCache")
struct ThumbnailCacheTests {
    let keyA = ThumbnailCache.Key(imageID: 1, tier: .low)
    let keyB = ThumbnailCache.Key(imageID: 2, tier: .low)
    let keyC = ThumbnailCache.Key(imageID: 3, tier: .low)

    @Test("insert then fetch returns the image")
    func roundTrip() {
        let cache = ThumbnailCache(maxBytes: 1 << 20)
        let image = makeImage(side: 32)
        cache.insert(image, for: keyA)
        #expect(cache.image(for: keyA) === image)
        #expect(cache.image(for: keyB) == nil)
    }

    @Test("LRU eviction drops the least-recently-used entry over the ceiling")
    func lruEviction() {
        let image = makeImage(side: 64)
        let cost = image.bytesPerRow * image.height
        let cache = ThumbnailCache(maxBytes: 2 * cost) // room for exactly two
        cache.insert(makeImage(side: 64), for: keyA)
        cache.insert(makeImage(side: 64), for: keyB)
        cache.insert(makeImage(side: 64), for: keyC) // evicts A (LRU)
        #expect(cache.count == 2)
        #expect(cache.image(for: keyA) == nil)
        #expect(cache.image(for: keyB) != nil)
        #expect(cache.image(for: keyC) != nil)
        #expect(cache.residentBytes <= 2 * cost)
    }

    @Test("accessing an entry refreshes its recency so it survives eviction")
    func touchProtectsFromEviction() {
        let image = makeImage(side: 64)
        let cost = image.bytesPerRow * image.height
        let cache = ThumbnailCache(maxBytes: 2 * cost)
        cache.insert(makeImage(side: 64), for: keyA)
        cache.insert(makeImage(side: 64), for: keyB)
        _ = cache.image(for: keyA)                    // A is now most-recent
        cache.insert(makeImage(side: 64), for: keyC)  // evicts B, not A
        #expect(cache.image(for: keyA) != nil)
        #expect(cache.image(for: keyB) == nil)
        #expect(cache.image(for: keyC) != nil)
    }

    @Test("a single image larger than the ceiling is kept, not thrashed")
    func oversizedKept() {
        let image = makeImage(side: 128)
        let cost = image.bytesPerRow * image.height
        let cache = ThumbnailCache(maxBytes: cost / 2) // smaller than one image
        cache.insert(image, for: keyA)
        #expect(cache.count == 1)
        #expect(cache.image(for: keyA) === image)
    }
}

// DecodeScheduler -------------------------------------------------------------

@MainActor
@Suite("DecodeScheduler")
struct DecodeSchedulerTests {
    @Test("blocking decode downsamples to within the target pixel size")
    func decodeBlockingDownsamples() {
        let images = FixtureImageSet(count: 1, seed: 3)
        let image = DecodeScheduler.decodeBlocking(data: images.encoded[0], maxPixelSize: 128)
        #expect(image != nil)
        #expect((image?.width ?? .max) <= 128)
        #expect((image?.height ?? .max) <= 128)
    }

    @Test("an async request populates the cache and fires onDecoded")
    func asyncRequestPopulatesCache() async {
        let images = FixtureImageSet(count: 1, seed: 3)
        let cache = ThumbnailCache(maxBytes: 1 << 20)
        let scheduler = DecodeScheduler(cache: cache)
        let key = ThumbnailCache.Key(imageID: 0, tier: .low)

        await confirmation("onDecoded fires once") { decoded in
            scheduler.onDecoded = { firedKey in
                #expect(firedKey == key)
                decoded()
            }
            scheduler.request(key: key, data: images.encoded[0], maxPixelSize: 128)
            // Give the background decode + main-actor hop time to complete.
            try? await Task.sleep(for: .seconds(2))
        }
        #expect(cache.image(for: key) != nil)
        #expect(scheduler.inFlightCount == 0)
    }

    @Test("retainOnly cancels in-flight decodes whose key is no longer needed")
    func retainOnlyCancelsStale() {
        let images = FixtureImageSet(count: 2, seed: 3)
        let cache = ThumbnailCache(maxBytes: 1 << 20)
        let scheduler = DecodeScheduler(cache: cache)
        let keep = ThumbnailCache.Key(imageID: 0, tier: .low)
        let drop = ThumbnailCache.Key(imageID: 1, tier: .low)

        // No await between request and retainOnly, so the Tasks haven't run yet
        // and both are still registered as in-flight.
        scheduler.request(key: keep, data: images.encoded[0], maxPixelSize: 128)
        scheduler.request(key: drop, data: images.encoded[1], maxPixelSize: 128)
        #expect(scheduler.inFlightCount == 2)

        scheduler.retainOnly([keep])
        #expect(scheduler.inFlightCount == 1)
    }
}

// CanvasEngine (headless smoke; thorough invariants live in CP5) ---------------

@MainActor
@Suite("CanvasEngine sync")
struct CanvasEngineTests {
    private func makeEngine() -> CanvasEngine {
        let engine = CanvasEngine(
            provider: FixedProvider(tiles: gridTiles()),
            images: FixtureImageSet(count: 4, seed: 1),
            viewportSize: CGSize(width: 250, height: 250)
        )
        engine.prefetchMarginScreen = 0 // deterministic visible set
        return engine
    }

    @Test("after sync, one layer per visible tile is attached to the root")
    func oneLayerPerVisibleTile() {
        let engine = makeEngine()
        engine.sync()
        let visible = engine.currentVisibleTiles().count
        #expect(visible > 0)
        #expect(engine.activeLayerCount == visible)
        #expect(engine.rootLayer.sublayers?.count == visible)
    }

    @Test("panning the content fully off-screen recycles every layer (no leak)")
    func panAwayRecyclesAll() {
        let engine = makeEngine()
        engine.sync()
        let peak = engine.allocatedLayerCount
        #expect(peak > 0)

        engine.setTransform(CanvasTransform(scale: 1, translation: CGPoint(x: -100_000, y: -100_000)))
        #expect(engine.activeLayerCount == 0)
        // Allocated layers are parked for reuse, not leaked or grown.
        #expect(engine.allocatedLayerCount == peak)
    }

    @Test("a zero-size viewport shows nothing")
    func zeroViewport() {
        let engine = makeEngine()
        engine.viewportSize = .zero
        engine.sync()
        #expect(engine.activeLayerCount == 0)
    }
}
