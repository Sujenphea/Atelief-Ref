# 187 — Detail decode strategy (036 §3 B3)

Layers a **sizing decision** on top of B2's `DetailImageLoader` so the item-detail
overlay decodes at the right pixel tier instead of always at native. B2 exercised
the `native` bucket only (`targetLongSidePx: nil`) and left the `1280/2048/3072`
ladder defined-but-unused; B3 measures the media area and drives that ladder. No
loader surface changed — B3 only supplies a real `targetLongSidePx` and reacts to
zoom.

## The tier decision (pure function)

`detailDisplayDecode(fitLongSidePx:zoom:) -> DetailDisplayDecode` in
`DetailImageLoader.swift`, where `fitLongSidePx = mediaAreaLongSide(pt) × displayScale`:

| Input | Decision | What decodes |
| --- | --- | --- |
| `zoom > 1` (any viewport) | `.decode(nil)` → **native** | one native decode, crisp for 1×…6× |
| `fitLongSidePx ≤ 1280`, zoom ≤ 1 | `.preview` | **nothing** — the eager 1280 preview is the display image |
| `fitLongSidePx > 1280`, zoom ≤ 1 | `.decode(fitLongSidePx)` → FIT bucket | one downsampled decode (`detailPixelBucket` snaps 1280/2048/3072) |
| `0` / `nan` / `inf` (not yet measured) | `.preview` | nothing (never eager native) |

Multiplying points by `displayScale` is deliberate — sharpness is set by physical
pixels. Consequence (honest): on a 2× Retina display the ≤1280 "preview only" branch
only fires for media areas ≤ 640pt; a wider viewport is 1400px+ and correctly takes
the 2048 FIT decode (the 1280 preview would be upscaled = soft). So the FIT decode is
the common Retina case, not the preview branch the plan prose implies. This is
strictly parity-safe: it always requests ≥ the drawn size, never softer than today.

## How ≤1280 avoids a decode entirely

`ThumbnailTier.large` (1280) is generated eagerly at ingest and is already shown as
the overlay's placeholder (`previewImage`). In the `.preview` case the session calls
the loader **not at all** — `displayImage` stays nil and the media area renders the
1280 preview, which at 1× is as sharp as a native decode downscaled to the same area.
Neighbour preloads are skipped too (neighbours in a ≤1280 viewport step from their own
previews), so the common laptop case is truly decode-free.

## Zoom>1 native swap without blank

On zoom-in the session requests native but keeps the current FIT (or preview) image
up; `displayImage` swaps in place only when native lands. No blank on open, step, or
zoom-in. Zoom-out to ≤1280 keeps the higher-res image already held (downscales crisply)
rather than dropping to the preview.

## Avoiding pinch-zoom decode storms

Two independent guards: (1) the view reports on the `zoom` **@State**, which only
changes at a settle point (button press / gesture end), never on the transient pinch
`@GestureState` — so decode happens at zoom settle; (2) every `zoom > 1` quantizes to
the **same** native bucket, and the session de-dups by requested `DetailImageKey`
(hash+bucket), so a 1.1×→6× drag and in-bucket geometry jitter both collapse to a
single decode.

## FIT-only neighbour preloads (preserved)

Neighbours always preload at `fitLongSidePx` (never native), even while the current
image is a zoom>1 native decode. B2's guarantees are intact: previous image retained
until the new one lands, `retainOnly` window still contains current.

## Files changed

- `AtelierRefs/AtelierRefs/DetailImageLoader.swift` — added `detailPreviewTierPx`,
  `DetailDisplayDecode`, and the pure `detailDisplayDecode(fitLongSidePx:zoom:)`.
  Loader cache / coalescing / `retainOnly` untouched.
- `AtelierRefs/AtelierRefs/DetailSession.swift` — sizing state (`fitLongSidePx`,
  `zoomLevel`, `currentItems`, `lastDisplayKey`, `displayTask`); decode-aware
  retention in `load`; `updateDisplayTarget(fitLongSidePx:zoom:)`; `loadDisplayImage`
  branches preview vs FIT vs native with de-dup; neighbour preloads on the FIT bucket;
  `waitForDisplayWorkForTesting()`.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `@Environment(\.displayScale)`,
  `onDisplayTarget` closure, `onGeometryChange` on the media area, report on zoom
  settle. Space board / library search leave `onDisplayTarget` nil (no-op).
- `AtelierRefs/AtelierRefs/CollectionView.swift` — host wires `onDisplayTarget` →
  `session.updateDisplayTarget`.
- Tests: `DetailImageLoaderTests.swift` (+`DetailDisplayDecodeTests`),
  `DetailSessionTests.swift` (+`DetailSessionSizingTests`).

## Verification

- Release build green (xcodebuild exit 0), no new warnings.
- `AtelierRefsTests` serial: 457 tests / 77 suites passed (incl. 9 new B3 tests).
- `onGeometryChange` and live pinch can't run headlessly — the pure decision and the
  session→loader threading (bucket per request, FIT-only neighbours, de-dup) are
  covered instead.

## Migration notes

None. `ItemDetailView.onDisplayTarget` defaults to nil; non-loader callers unaffected.

## What remains for B4

Most-Viewed reorder / `flushViewBumps` (coalesced open + non-disruptive reorder) is
untouched — out of B3 scope.

## Amends to `.docs/036`

§3 B3 says ≤1280 is "the common laptop case"; on a Retina display that holds only for
media areas ≤ 640pt (points × 2× scale), so the FIT downsample decode is the common
Retina path. The pixel-tier rule is unchanged; the framing is what shifts.
