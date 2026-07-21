# 186 — DetailImageLoader: full-res LRU + neighbour preload (036 §3 B2)

## Summary

Workstream B step B2 of `036-grid-smooth-plan.md` — the second half of **root
cause 3** (item-detail churn). B1 moved the overlay's state off the god-object;
B2 fixes the image itself: today `ItemDetailView.loadMedia` decoded the full-res
blob **uncached on every prev/next** (`NSImage(contentsOf:)`), so a fast walk
re-decoded large images repeatedly and held nothing for the step back — while
also deferring the pixel decode to first draw on the main thread.

New `DetailImageLoader` (an `actor`) decodes once, caches under a count-AND-cost
budget, and warms the two neighbours the instant the current image lands. Stepping
is now usually a cache hit and memory is bounded. `DetailSession` requests the
image and publishes it into `state.displayImage`; the previous image stays on
screen until the next resolves (no blank flash on step).

## What B2 provides vs what B3 will add

- **B2 exercises the `native` bucket only** — the parity-preserving default
  (`targetLongSidePx: nil`), so the display image looks identical to today's
  full-res decode. Memory is bounded by the cache, not by downsampling.
- **The 1280/2048/3072 downsample tiers are defined but not driven.** The ladder
  and quantizer (`detailPixelBucket(longSidePx:)`) live in B2; B3 slots in by
  passing a **measured** `targetLongSidePx` (media-area size × scale via
  `onGeometryChange`) and a native re-decode for zoom > 1. The loader API does not
  change — B3 only starts choosing a tier. A synchronous `cached(hash:target…)`
  seam is already exposed for B3's instant-paint.

## The loader API

- `DetailImageCache` — `NSCache`, key `"hash#bucket"` (native spelled
  `"hash#native"`), `totalCostLimit = 384 MB`, `countLimit = 5`, cost = decoded
  bytes. Count-AND-cost because full-res images are few and large: {prev,current,
  next} is three, so 5 gives one step of back-step hysteresis; the byte budget
  caps the pathological case (a 40 MP panorama is ~160 MB, so ~2 resident before
  memory runs away). The plan's numbers hold against real sizes.
- `actor DetailImageLoader`
  - `displayImage(hash:url:targetLongSidePx:) async -> CGImage?` — cache hit →
    return; miss → decode at the quantized bucket, cache, return. Coalesces via a
    `[key: Task]` map; a promoted preload is **awaited, not re-decoded**.
  - `preload(hash:url:targetLongSidePx:)` at `.utility` for neighbours.
  - `retainOnly(hashes:)` — cancels in-flight **preloads** outside the window.
- Pure helpers: `detailNeighbors(items:currentID:)` ({prev,current,next}, **no
  wrap** — matches the navigator's clamp), `detailPixelBucket(longSidePx:)`
  (snap-UP, `nil`/past-top → native).

## How the two hazards are avoided

- **No blank flash on step.** `DetailSession.load` carries the previous
  `state.displayImage` into the new state on a step (a fresh open starts empty), so
  `ItemDetailView` keeps drawing the last image until the new one is published. In
  the common case the neighbour was preloaded, so the new image is a cache hit and
  the swap is instant. Prev/next preloads are kicked **only after the current
  image resolves**, so they never contend with the visible decode.
- **The promoted-preload-vs-cancel race** (which would blank the detail image
  mid-step) is guarded **twice**, independently:
  1. `retainOnly` only ever cancels keys still in `preloadKeys`. The moment
     `displayImage` joins an in-flight preload it **removes that key from
     `preloadKeys`** (promotion), so it is no longer cancellable. Because the loader
     is an `actor`, promotion and `retainOnly` cannot interleave.
  2. `DetailSession` always calls `retainOnly` with a window that **contains the
     current hash** (it is the "current" of {prev,current,next}), so even an
     unpromoted current-key preload is retained.
  This mirrors the C1 hazard (`ThumbnailPipeline`: a hash crossing the prefetch
  ring into the visible set must be excluded from cancellation) at full-res scale.

## Reuse of the C1 decode/cache discipline

No second decoder: `DetailImageLoader.imageIODecode` calls the shared
`ImageDecoding.decodedThumbnail(from:url:maxPixelSize:cacheImmediately:true)` — the
same off-main, fully-decoded, EXIF-transformed, byte-costed bitmap the thumbnail
pipeline uses (`native` maps to `detailNativeDecodeMaxPixelSize = 16384`, past any
real photo). Same coalescing shape (`[key: Task]`, decode once, promoted work
awaited), same "visible/promoted loads are never cancelled" rule, same cost-based
`NSCache` accounting — just count-bounded too. Output is `CGImage` →
`Image(decorative:)`, so no `NSImage` lazy-decode-at-first-draw is reintroduced.

## Files changed

- **`DetailImageLoader.swift`** (new) — ladder + `detailPixelBucket`,
  `detailNeighbors`/`DetailNeighbors`, `DetailImageKey`, `DetailImageCache`, and
  the `actor DetailImageLoader`.
- **`DetailImageLoaderTests.swift`** (new) — injected-decode suites: neighbours
  (ends/single/unknown/no-wrap), bucket ladder (nil/degenerate→native, snap-up,
  native key), coalescing (N concurrent → one decode), promoted-preload-not-re-
  decoded, `retainOnly` cancels-outside / **keeps-promoted** (adversarial empty
  window), and count-AND-cost eviction with roomy-budget controls.
- **`DetailSession.swift`** — `State.displayImage` is now `CGImage?` (was
  `NSImage?`); `init` gains `loader` + `displaySource`; `present`/`step` take the
  feed `items`; `load` retains the previous image on step; `loadDisplayImage` +
  `retentionWindow` + `applyRetentionAndPreload` wire the loader (request → publish
  → preload neighbours → `retainOnly`). Media-less kinds clear the image only when
  one is present (keeps the B1 single-publish invariant, unit-verified).
- **`ItemDetailView.swift`** — new `displayImage: CGImage?` + `usesExternalImageLoader`
  props; `mediaImage` prefers the loader image (`Image(decorative:)`) with the
  1280 preview as fallback; `loadMedia` skips its internal image decode under the
  loader (video path unchanged); `ZoomableImage`/`LinkDetailView`/`TweetDetailView`
  take a SwiftUI `Image`. The Space board + library search keep their own decode
  via the defaulted params (untouched behaviour).
- **`CollectionView.swift`** (`CollectionDetailHost`) — injects `displaySource`
  (blob hash + URL, nil for media-less), passes `model.items` into
  `present`/`step`, and feeds `displayImage` + `usesExternalImageLoader: true`.

## Verification

- Release build green on `xcodebuild`'s own exit status (0). No new warnings.
- `AtelierRefsTests`, `-parallel-testing-enabled NO`: **448 tests / 75 suites
  passed** (was 428 at A4; +20). B1 `DetailSession` and C1 `ThumbnailPipeline`
  suites still green. UI tests not run (out of scope).

## What is owed to manual / B3 verification

- The no-blank-flash step, the neighbour cache-hit "instant" feel, and steady
  memory under the budget are behavioural and covered by the manual Instruments
  pass 036 §6 lists (arrow stepping incl. a 40 MP image; memory under budget).
- Space board + library search still own their full-res decode (no loader). B3 (or
  a follow-up) can migrate them and delete `ItemDetailView`'s internal decode path.

## Amend to `036`

- **§3 B2 default is `native`, stated.** The plan says "quantize to buckets
  (1280/2048/3072/native)" but is silent on B2's default. B2 uses **native** for
  behaviour parity (the display image must look identical); B3 lowers it to a
  measured tier for the fit case. Recorded here and in the loader doc comment.
- **`state.displayImage` is `CGImage`, not `NSImage`.** The B1 seam was typed
  `NSImage?`; B2 changed it to `CGImage?` to render via `Image(decorative:)` and
  avoid the `NSImage` lazy-decode cost C1 measured away (the plan's own stated
  preference). `ItemDetailView` + the private card views now take a SwiftUI `Image`.
- The 384 MB / count 5 numbers are correct for real full-res sizes (reasoning in
  `DetailImageCache`'s doc) — left as the plan specifies.

## Migration notes

No data or schema changes. Any future full-window detail surface should request
its image through `DetailImageLoader` (with a measured `targetLongSidePx`) rather
than decoding the blob inline.
