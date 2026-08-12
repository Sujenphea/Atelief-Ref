# 383 — The Poster That Was Already There

Three symptoms reported together — "opening video can be a bit laggy, and colors /
tags don't work on videos" — turned out to be two bugs, and both were fixed with a
file that ingest had already written and nothing was reading.

## 1 · What was actually broken

A throwaway probe over a real video-kind asset, before touching anything:

```
manual-tag-applied: motion   readback: ["motion"]
needsAnalysis-contains-video: false
needsSuggestions-contains-video: false
analysis-colors: nil      color-rows: 0
search-by-tag-finds-video: true
```

So **manual tags were never broken** — apply, read back and search all work on a
video, and nothing in that path is kind-gated. What did not work was everything
DERIVED: `assetsNeedingAnalysis` filtered `WHERE a.kind = 'image'`, so a video
never got an `asset_analysis` row, so `colors` was nil, so `ColorsSection` — which
hides itself when the list is empty — was permanently absent rather than visibly
empty. `assetsNeedingSuggestions` carried the same filter, so no ✦ chip could ever
reach a video either.

That second one is [382](382-the-tag-that-asks-before-it-stays.md)'s, one day old.
It was written by mirroring the analysis query, and inherited an exclusion without
re-asking whether it was still true.

## 2 · It was not true

The analysis exclusion cited 012's deferral: video analysis "needs a poster-frame
path", priced as a frame-sampling project and pushed to v2. But the poster frame is
rendered **at ingest** (`ThumbnailGenerator.makeVideoPoster`) and has been sitting
on disk as a JPEG tier ever since — it is what the grid draws, and what
`previewImageURL` already serves to the detail page.

So "analyze the poster frame" costs a thumbnail read. `AnalysisSource.imageData`
now answers the one question both passes ask — given this asset, what image do I
hand the model? — with the blob for an image and the poster for a video. It is
shared between `AnalysisBackfill` and `SuggestionBackfill` so the two can never
disagree about what a video looks like; if they did, an asset could be OCR'd from
its poster and classified from a failed movie decode, and only the second would
look broken.

Videos now get OCR, colors, a perceptual hash and suggested tags. Near-duplicate
detection is deliberately left images-only — a poster's dHash is a weak claim about
a video, and the review surface acts on whole assets.

## 3 · The lag, measured — and the fix that was refused

`VideoOpenProbeTests` (opt-in, `ATELIER_VIDEO_PROBE=1 swift test --filter
VideoOpenProbe`) times the four costs on the video-open path. On a 640×480
synthetic clip:

```
1 AVKit load    :    12.6 ms   first video of the session only
2 AVPlayer(url:):     1.1 ms   main actor, blocking
3 → readyToPlay :    92.4 ms   black screen after 2
4 poster decode :     2.1 ms   the placeholder
──────────────────────────────────────────────────────
user waits      :    93.5 ms   (2 + 3)
could see       :     2.1 ms   (4, already decoded in DetailSession)
```

The obvious suspect was that `loadMedia` builds the player **synchronously on the
main actor**, three lines above an image arm that deliberately hops off-main via
`Task.detached`. Moving it was scoped, and the measurement refused it: that
construction costs **1.1 ms**. The 93 ms wait is step 3, which is already
asynchronous — it was simply being spent on a spinner and then on `AVPlayerView`'s
opaque black, while the 1280 poster sat decoded in `previewImage`, fetched by
`DetailSession` for every kind including this one.

So the fix is to draw it. The poster goes **on top of** the player, not behind it —
`AVPlayerView` paints black from the moment it is installed, so a poster behind it
would be invisible for precisely the window it exists to cover. It lifts on
`.readyToPlay`, and also on `.failed`: a poster left up over a player that will
never draw looks exactly like a working video that refuses to play, and hides the
one signal a person could report.

A real 1080p file only widens the gap — step 3 grows with the file, step 2 does
not — so the refusal holds a fortiori. The probe takes
`ATELIER_VIDEO_PROBE_PATH=…` if anyone wants the real number.

This is [087](../.docs/087-canvas-pinch-results.md)'s shape a second time: the
harness ran first and said the interesting-looking optimization was not the
problem.

## Files

**AtelierCore**
- `Services/AppServices.swift` — `assetsNeedingAnalysis` and
  `assetsNeedingSuggestions` take `kind IN (image, video)`

**AtelierIngestion**
- `Analysis/AnalysisSource.swift` — new; the shared blob-vs-poster rule
- `Analysis/AnalysisBackfill.swift`, `Analysis/SuggestionBackfill.swift` — read
  through it (and shed two now-dead error enums)
- `Tests/…/VideoOpenProbeTests.swift` — new; the measurement, opt-in

**AtelierRefs**
- `ItemDetailView.swift` — the poster placeholder, `videoReady`,
  `awaitFirstFrame(of:)`

**Tests** — `AnalysisSourceTests` (4), plus a video case each in
`AnalysisBackfillTests`, `SuggestionBackfillTests`, `ServicesAnalysisTests` and
`ServicesSuggestionsTests`.

## Migration notes

None — no schema change. Existing videos become analysis candidates the moment
this ships and pick up colors, OCR and suggestions on the next idle pass, because
"needs analysis" was always a query rather than a ledger. A video whose poster tier
was never written (an old ingest, a reaped thumbnail) fails as a typed miss the
batch counts and moves past, rather than by handing an `.mp4` to ImageIO.

## Two things about running the suite, found on the way

Neither is caused by this change, and both cost enough time to be worth writing
down.

**The AtelierIngestion bundle wedges intermittently under `swift test`'s default
parallelism.** Not a failure and not a timeout — the process simply stops, CPU flat,
part-way through, and has to be killed. Same signature as the
`VNClassifyImageRequest` deadlock [382](382-the-tag-that-asks-before-it-stays.md)
§9 documents, and it shows up around the AVFoundation-heavy suites. `swift test
--no-parallel` is reliable (427 tests, 45 suites, 6.7 s, green) and is what the
numbers here come from.

**`EmbeddingBackfillTests.ocrUnchangedIsTouch` is a pre-existing flake.** It failed
in a serial run here, which looked exactly like this change breaking it — the test
asserts that a re-analysis with the same OCR text is a touch rather than a
re-embed, and `upsertAnalysis` is a file this change touches. Checked properly by
stashing everything and running it on HEAD: **2 failures in 3 runs with none of
this change present.** The cause is millisecond resolution — `analyzed_at` and the
embedding's own timestamp can land in the same stored millisecond, so the "newer
than" comparison that makes the asset re-qualify is false. An idle machine makes it
MORE likely, which is why serial runs surface it. Left alone: fixing it is a change
to the staleness comparison, not to anything here.

## Not done

- **Player construction stays on the main actor.** Measured at 1.1 ms; see §3.
- **Near-duplicate detection stays images-only.**
- **Only the poster frame is analyzed**, not sampled frames — text that appears at
  0:42 is still invisible to search. That is the v2 cost 012 named, and it is still
  real; what changed is that the *first* frame was never worth deferring.
