# 038 — Grid bake-off: results and verdict

Measurements taken against the protocol and decision rule pre-registered in
`037-grid-bakeoff-protocol.md`. Raw JSON (including every frame interval, so any
percentile is recomputable) under the run's `results/` directory.

## 1. Environment

`MacBookPro18,3`, macOS 26.5 (25F71), Release build, plugged in, quiescent.
Fixed 1100×820 window. Both displays report **60 Hz** — so **P = 16.67 ms**, not
the 8.33 ms `037` §4 anticipated. There is no active ProMotion panel; the frame
budget is the *forgiving* one, which makes the SwiftUI failures below harder to
explain away, not easier.

30 launches × 3 ramps = 90 runs; 599–600 frames each.

## 2. Results (median; n=3 cold, n=6 warm)

| scale | mode / wrappers | state | p95 | p99 | worst | >P | >2P | verdict |
|---|---|---|---|---|---|---|---|---|
| 200 | windowed / full | warm | 16.67 | 34.16 | 39.28 | 16 | 8 | Not smooth |
| 200 | windowed / stripped | warm | 16.67 | 34.26 | 44.54 | 14 | 7 | Not smooth |
| 200 | equatable / full | warm | 25.17 | 49.80 | 60.12 | 45 | 26 | Not smooth |
| 200 | equatable / stripped | warm | 16.67 | 33.33 | 47.42 | 10 | 5 | Not smooth |
| 200 | **appKit** | warm | 16.67 | 16.67 | 16.67 | 0 | 0 | **Smooth** |
| 2000 | windowed / full | warm | 50.90 | 60.26 | 97.70 | 534 | 314 | Not smooth |
| 2000 | windowed / stripped | warm | 25.00 | 34.70 | 76.03 | 30 | 8 | Not smooth |
| 2000 | equatable / full | warm | 57.11 | 106.82 | 234.06 | 244 | 167 | Not smooth |
| 2000 | equatable / stripped | warm | 34.54 | 42.50 | 68.84 | 136 | 39 | Not smooth |
| 2000 | **appKit** | warm | 16.67 | 16.67 | 16.67 | 0 | 0 | **Smooth** |

Cold runs are omitted here (same verdicts, worse magnitudes) except to note
AppKit is identical cold and warm.

## 3. Findings

### 3.1 Option A is dead — 035's recommendation was wrong

The equatable cell is **not an improvement and is frequently worse** than the
plain windowed baseline. At 200 warm it loses consistently across all 6 runs
(p99 49.8 vs 34.2; >2P 26 vs 8), outside noise. At 2000 the two are within
noise. `035` §6 recommended this as the cheap fix that would remove "~80% of the
residual hitch"; measured, it removes none of it.

Plausible mechanism: `==` over ten fields per cell, evaluated for every windowed
cell on every band republish, costs more than the `body` it skips — the cell
bodies were never the dominant term the equality check assumes.

**This is the single highest-value result of the exercise.** It was the
recommended path, it is half a day of work, and it would have shipped and
changed nothing.

### 3.2 The jank is real at 200 items, at a realistic scroll speed

The user's largest real collection is 192 items and their complaint was that the
grid degrades above ~100. That reproduces: `windowed/full` at 200 items is
**Not smooth at 1,533 pt/s** — a realistic flick — with 8 frames over 2P warm
(18 cold) and a worst frame of 39–47 ms.

So this is **not** a 2000-item scaling ceiling. Something is wrong at a scale
where nothing should be.

### 3.3 The per-cell wrappers are the largest SwiftUI-side effect measured

Stripping `.draggable`/`.dropDestination`/`.contextMenu`/`.onHover` at 2000 warm
takes >2P from **314 → 8**. This is the third outcome `037` §2 anticipated, and
it is large — but stripped still fails at 2000 and at 200-warm, so deferring
wrappers alone does not reach Smooth.

### 3.4 AppKit is perfect, and that is exactly the problem

Zero missed vsyncs across ~5,400 frames at both scales, cold and warm. Verified
not to be an artifact: 601 scroll ticks, 602 bounds-change queries, 154
layout-attribute queries, **0 `prepare()` calls during scroll**, 19 rendered
cells matching analytic frames (worst deviation 0.23 pt), 150,950 pt travelled.

## 4. The confound that blocks the decision

`037` §5 says: Option A "Not smooth" + AppKit "Smooth" → **Option B confirmed.**
Applied literally, the rewrite is justified.

That rule should not be applied literally, because it was written without
knowledge of a confound discovered during implementation:

**The AppKit mode does not only differ by framework.** `layer.contents` requires
a `CGImage`, which the shared `ThumbnailCache` (`NSCache<NSString, NSImage>`)
cannot vend — so that mode necessarily runs its own ImageIO pipeline,
downsampling to a bucket derived from the analytic frame. That is precisely
`036` Workstream C. The SwiftUI modes serve 512 px `NSImage`s through the old
shared path.

`037` §3.2 assumed a cold/warm split would isolate this. It does not: the
bucketed-`CGImage` advantage applies to **every frame, warm included** — smaller
textures, no `NSImage`→`CGImage` conversion, no SwiftUI resampling. Cold and
warm AppKit are identical, so the split isolates nothing.

**Therefore the matrix cannot separate "NSCollectionView recycling" from
"Workstream C thumbnail pipeline." The data is consistent with either carrying
most of the benefit.**

## 5. Verdict: not yet — run one more cell first

The missing experiment is **SwiftUI + bucketed-`CGImage` thumbnails**. It is not
extra work: Workstream C is already sequenced at steps 2–3 of `036` §5, ahead of
the AppKit migration, and is justified independently of which grid wins.

Reordering it to run *first*, then re-measuring the SwiftUI modes, is decisive:

| SwiftUI + C result | Conclusion |
|---|---|
| Smooth | The thumbnail representation was the bottleneck. **Skip A1–A4 — ~9 days saved.** |
| Still Not smooth | Framework ceiling confirmed with the confound eliminated. **Proceed with Option B on evidence.** |

Cost: ~2 days, already planned. Compare against committing 1–2 weeks on a
comparison that cannot currently distinguish the two hypotheses.

Combine with §3.3: the candidate cheap path is **Workstream C + deferred per-cell
wrappers**, both measured in days. If that reaches Smooth, the rewrite is moot.

## 6. Amendments owed to earlier docs

- `035` §6 recommendation (Option A) is **refuted** — see §3.1.
- `036` §2's "frames map 1:1 with **zero conversion**" needs a sub-pixel
  asterisk: the coordinate space is confirmed, but AppKit pixel-snaps item views
  and masonry heights are fractional (`columnWidth / aspect`). Worst measured
  deviation 0.233 pt over 612 comparisons. Hover, marquee, selection rings and
  hit-testing must ride the **analytic** frames, never live cell frames.
- `037` §5's decision table needs the §4 confound folded in; a "Smooth" AppKit
  row is not by itself a framework verdict.

## 7. Caveats on these numbers

- **Cross-scale comparison is not like-for-like.** Full travel in fixed duration
  means 2000 items scrolls at 15,095 pt/s vs 1,533 pt/s at 200 (~9.8×). The
  2000-item figures are an extreme stress test beyond any human flick.
  Comparisons *within* a scale are valid; across scales they are not.
- "Cold" means empty memory caches; on-disk thumbnails existed and the OS file
  cache was warm. A true cold-disk run is worse for every mode.
- All 200-item runs preceded all 2000-item runs, so thermal drift is confounded
  with scale.
- Noisiest cell: equatable/full warm at 2000 (p99 spread 42.9–126.7).
- Within-noise pairs: windowed/stripped vs equatable/stripped at both scales;
  equatable vs windowed at 2000/full.
