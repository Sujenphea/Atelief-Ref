//
//  DetailImageLoader.swift
//  AtelierRefs
//
//  036 §3 B2 — the full-resolution detail-image loader: an LRU cache plus
//  prev/next neighbour preload, so stepping through the item-detail overlay is
//  instant and bounded in memory.
//
//  Fixes the second half of **root cause 3** (item-detail churn): today
//  `ItemDetailView.loadMedia` decodes the full-res blob UNCACHED on every
//  prev/next step (`NSImage(contentsOf:)`), so a fast walk through a folder
//  re-decodes large images repeatedly and holds nothing for the step back. This
//  loader decodes once, caches the result under a byte-AND-count budget, and warms
//  the two neighbours the moment the current image lands — so a step is usually a
//  cache hit and memory can never run away.
//
//  Reuses the SAME decode seam as the thumbnail pipeline (036 §4 C1): the shared
//  ``ImageDecoding`` helper (off-main, fully-decoded bitmap, real byte cost,
//  `cacheImmediately` so no lazy decode lands on the main thread at first draw),
//  and the SAME coalescing/cancel discipline — one `Task` per key, promoted
//  preloads awaited not re-decoded, and the "a request promoted to current must
//  never be cancelled" hazard the pipeline already guards. This is that pattern at
//  full-res scale: few, large images rather than many small ones, so the cache is
//  count-AND-cost bounded where the thumbnail cache is cost-only.
//
//  What B2 provides vs what B3 adds: B2 exercises the **native** bucket only (the
//  parity-preserving default — the display image looks identical to today's
//  full-res decode). The 1280/2048/3072 downsample tiers are defined here as a
//  ladder but are LEFT for B3 to drive from the measured media-area size
//  (`onGeometryChange`) plus the zoom>1 native re-decode. B3 slots in by passing a
//  real `targetLongSidePx`; nothing about this API changes.
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation

// MARK: - The detail bucket ladder (pure)

/// The pixel long-side ladder the full-res detail image is decoded to, ascending.
///
/// B3 drives these downsample tiers from the measured media-area size (a laptop
/// viewport rarely needs more than 1280–2048 px at fit); B2 never requests them —
/// it only ever asks for ``detailNativeBucket``. Kept here so B3 adds tiers, not a
/// second quantizer.
nonisolated let detailPixelBuckets: [Int] = [1280, 2048, 3072]

/// Sentinel bucket: decode at (effectively) native resolution — no downsample.
/// B2's default, and B3's zoom>1 request. `Int.max` so it always sorts above every
/// real target and never collides with a real pixel bucket.
nonisolated let detailNativeBucket = Int.max

/// The `maxPixelSize` handed to ImageIO for the ``detailNativeBucket``: large
/// enough that no photograph a user would open is downsampled (a 268-megapixel
/// square would be the first to touch it), so "native" is byte-for-byte the
/// full-res image for all real content, while still bounding a pathological
/// gigapixel source instead of trying to rasterize it whole.
nonisolated let detailNativeDecodeMaxPixelSize = 16_384

/// The bucket to decode a detail image whose on-screen long side is `longSidePx`
/// pixels, snapped **UP** so the bitmap is never upscaled at draw. `nil` (B2's
/// default — "just give me native") or a size past the top tier → native.
///
/// Snaps up rather than to-nearest for the same reason the thumbnail ladder does
/// (``thumbnailPixelBucket``): a bucket below the drawn size is visibly soft, one
/// above is a free compositor downscale.
nonisolated func detailPixelBucket(longSidePx: CGFloat?) -> Int {
    guard let longSidePx, longSidePx.isFinite, longSidePx > 0 else { return detailNativeBucket }
    for bucket in detailPixelBuckets where CGFloat(bucket) >= longSidePx { return bucket }
    return detailNativeBucket
}

// MARK: - Pure neighbour helper

/// The item currently shown plus the two the user can step to (036 §3 B2), so the
/// loader knows exactly what to preload and what to retain.
nonisolated struct DetailNeighbors: Equatable, Sendable {
    var current: CollectionItemDetail?
    var previous: CollectionItemDetail?
    var next: CollectionItemDetail?
}

/// The {prev, current, next} triple around `currentID` in `items`.
///
/// **No wrap** — matches the detail navigator's clamp (`ItemDetailView`'s prev/next
/// buttons disable at the ends): the first item has no previous, the last no next.
/// A single item is its own current with no neighbours; a `currentID` not in
/// `items` (already deleted) yields an empty triple. Pure, so it is unit-tested
/// directly.
nonisolated func detailNeighbors(
    items: [CollectionItemDetail], currentID: UUID?
) -> DetailNeighbors {
    guard let currentID,
          let i = items.firstIndex(where: { $0.item.id == currentID }) else {
        return DetailNeighbors()
    }
    return DetailNeighbors(
        current: items[i],
        previous: i > 0 ? items[i - 1] : nil,
        next: i + 1 < items.count ? items[i + 1] : nil)
}

// MARK: - Cache

/// Identity of one decoded detail image: content hash at a pixel bucket.
nonisolated struct DetailImageKey: Hashable, Sendable {
    let hash: String
    let bucket: Int

    /// `"hash#bucket"`, with the native sentinel spelled `"hash#native"` rather
    /// than a nine-digit `Int.max` (036 §3 B2 keying).
    var cacheKey: String {
        bucket == detailNativeBucket ? "\(hash)#native" : "\(hash)#\(bucket)"
    }
}

/// Process-wide LRU for decoded full-res detail images.
///
/// Count-AND-cost bounded, unlike the thumbnail cache (036 §4 C1) which is
/// cost-only: full-res images are FEW and LARGE, so both limits earn their keep.
/// `countLimit = 5` bounds the working set — {prev, current, next} is three, so
/// five leaves one step of back-step hysteresis. `totalCostLimit ≈ 384 MB` charges
/// the real decoded byte size, which is what actually caps the pathological case:
/// five 12-megapixel photos are ~240 MB (count governs), but a 40-megapixel
/// panorama is ~160 MB each so the byte budget evicts down to ~2 resident giants
/// before memory runs away. Both numbers are the plan's and hold up against real
/// full-res sizes.
///
/// `@unchecked Sendable`: `NSCache` is internally thread-safe, so the loader actor
/// can hand it to the off-actor decode task to fill.
nonisolated final class DetailImageCache: @unchecked Sendable {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    init(totalCostLimit: Int = 384 * 1024 * 1024, countLimit: Int = 5) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    func image(for key: DetailImageKey) -> CGImage? {
        cache.object(forKey: key.cacheKey as NSString)?.image
    }

    func insert(_ image: CGImage, cost: Int, for key: DetailImageKey) {
        cache.setObject(Box(image), forKey: key.cacheKey as NSString, cost: max(0, cost))
    }
}

// MARK: - The loader

/// Full-res detail-image loader with an LRU cache, coalesced decodes, and
/// prev/next neighbour preload (036 §3 B2).
///
/// An `actor`, so the in-flight/preload bookkeeping needs no lock: every mutation
/// runs to completion between suspension points. The heavy decode is offloaded to
/// a detached task (off the actor AND off the main thread) — the actor only ever
/// shuffles pointers.
actor DetailImageLoader {
    /// The decode seam — synchronous, injected for tests exactly as
    /// ``ThumbnailPipeline`` does, so coalescing/cancel/eviction are exercised
    /// without ImageIO or the filesystem.
    typealias Decode = @Sendable (URL, Int) -> DecodedThumbnail?

    /// Identity of an asset's full-res source: its content hash and on-disk blob
    /// URL. `nil` for a media-less kind (no blob to decode).
    typealias Source = (hash: String, url: URL)

    static let shared = DetailImageLoader()

    private let cache: DetailImageCache
    private let decode: Decode

    /// One task per key ⇒ N concurrent requests for the same image decode ONCE and
    /// all await the same task (036 §3 B2 coalescing, mirroring C1).
    private var inFlight: [DetailImageKey: Task<Void, Never>] = [:]
    /// Which of `inFlight` are NEIGHBOUR PRELOADS — the ONLY keys ``retainOnly``
    /// may cancel. A key leaves this set the instant ``displayImage`` promotes it
    /// to the current/visible image, which is half of why a promoted preload can
    /// never be cancelled (the other half: ``retainOnly`` is always called with a
    /// window that CONTAINS the current hash). See ``retainOnly(hashes:)``.
    private var preloadKeys: Set<DetailImageKey> = []

    init(
        cache: DetailImageCache = DetailImageCache(),
        decode: @escaping Decode = DetailImageLoader.imageIODecode
    ) {
        self.cache = cache
        self.decode = decode
    }

    /// The production decoder: one ImageIO decode to the bucket (native ⇒
    /// ``detailNativeDecodeMaxPixelSize``), EXIF-transformed, **pixels forced now**
    /// on the background thread via the shared ``ImageDecoding`` helper — the same
    /// decoder C1 uses, not a second one.
    static let imageIODecode: Decode = { url, bucket in
        let maxPixel = bucket == detailNativeBucket ? detailNativeDecodeMaxPixelSize : bucket
        return try? ImageDecoding.decodedThumbnail(
            from: url, maxPixelSize: maxPixel, cacheImmediately: true)
    }

    // MARK: Synchronous read (B3 instant-paint seam)

    /// A cache hit for `hash` at the bucket `targetLongSidePx` snaps to, or `nil`.
    /// Thread-safe (the cache is), so B3 can peek it on the render path before
    /// awaiting. B2 does not use it.
    nonisolated func cached(hash: String, targetLongSidePx: CGFloat?) -> CGImage? {
        cache.image(for: DetailImageKey(
            hash: hash, bucket: detailPixelBucket(longSidePx: targetLongSidePx)))
    }

    // MARK: Visible load

    /// Decode (or join an in-flight decode of) the full-res image for the item the
    /// overlay is showing NOW.
    ///
    /// Cache hit → return it. Miss with a preload already in flight for this key →
    /// **promote and await it** (no second decode): the key is removed from
    /// `preloadKeys` so a later ``retainOnly`` can't cancel the very decode this
    /// awaits. Miss with nothing in flight → start a `.userInitiated` decode.
    @discardableResult
    func displayImage(hash: String, url: URL, targetLongSidePx: CGFloat?) async -> CGImage? {
        let key = DetailImageKey(hash: hash, bucket: detailPixelBucket(longSidePx: targetLongSidePx))
        if let hit = cache.image(for: key) { return hit }
        await join(key: key, url: url, visible: true).value
        return cache.image(for: key)
    }

    // MARK: Preload

    /// Warm `hash` at `.utility` for a neighbour. Skipped if already cached or in
    /// flight (a promoted neighbour is neither re-queued nor re-decoded).
    func preload(hash: String, url: URL, targetLongSidePx: CGFloat?) {
        let key = DetailImageKey(hash: hash, bucket: detailPixelBucket(longSidePx: targetLongSidePx))
        guard cache.image(for: key) == nil, inFlight[key] == nil else { return }
        _ = startTask(key: key, url: url, visible: false)
    }

    /// Cancel in-flight PRELOADS whose hash is not in `hashes` — the caller passes
    /// its current {prev, current, next} window, so anything the user stepped past
    /// stops decoding.
    ///
    /// Two invariants keep this from ever blanking the visible image:
    ///  1. **Only `preloadKeys` are touched.** A key started as a visible load, or
    ///     a preload that ``displayImage`` promoted, is not in `preloadKeys` and is
    ///     therefore never cancelled here.
    ///  2. **The current hash is always in `hashes`.** The window this is called
    ///     with contains the current item by construction, so even a still-unpromoted
    ///     current-key preload is retained. This is the C1 hazard (a hash crossing
    ///     from the ring into the visible set must be excluded from cancellation),
    ///     enforced at the call site there and here.
    func retainOnly(hashes: Set<String>) {
        for (key, task) in inFlight where preloadKeys.contains(key) && !hashes.contains(key.hash) {
            task.cancel()  // `finish` clears the bookkeeping when the task ends.
        }
    }

    // MARK: Internals

    /// Join the existing task for `key`, or start one. When a VISIBLE request joins
    /// an in-flight preload it **promotes** it (drops it from `preloadKeys`) so it
    /// is no longer cancellable. No `await` inside, so this is atomic on the actor.
    private func join(key: DetailImageKey, url: URL, visible: Bool) -> Task<Void, Never> {
        if let existing = inFlight[key] {
            if visible { preloadKeys.remove(key) }
            return existing
        }
        return startTask(key: key, url: url, visible: visible)
    }

    /// Start the decode task and record it. The decode runs OFF the actor (detached)
    /// and OFF the main thread; only `finish` hops back to mutate bookkeeping.
    private func startTask(key: DetailImageKey, url: URL, visible: Bool) -> Task<Void, Never> {
        if !visible { preloadKeys.insert(key) }
        let decode = self.decode
        let cache = self.cache
        let bucket = key.bucket
        let task = Task.detached(priority: visible ? .userInitiated : .utility) { [weak self] in
            // Cancellation is checked ONCE before the decode (mirrors C1): a preload
            // cancelled while still queued never runs; one already inside ImageIO
            // finishes and is cached anyway (a decoded image is worth keeping).
            if !Task.isCancelled, let decoded = decode(url, bucket) {
                cache.insert(decoded.image, cost: decoded.byteCost, for: key)
            }
            await self?.finish(key)
        }
        inFlight[key] = task
        return task
    }

    private func finish(_ key: DetailImageKey) {
        inFlight[key] = nil
        preloadKeys.remove(key)
    }

    /// Await everything in flight — test/diagnostic support only.
    func waitForPendingWork() async {
        for task in inFlight.values { await task.value }
    }
}
