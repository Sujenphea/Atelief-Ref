# 177 — Thumbnail call-site migration, `ThumbnailCache` deleted (036 §4 C3)

Step 2 of the amended `036` sequence. Every thumbnail consumer now draws from
``ThumbnailPipeline`` at a bucket derived from **its own** analytic display
size, and the old `ThumbnailCache` is gone. Unlike `176` this DOES change
rendering behavior on every surface that shows a thumbnail.

## Summary

**`ThumbnailCache` is deleted.** It was an `NSCache<NSString, NSImage>` with
`countLimit = 512`, no byte accounting, and one bitmap per hash regardless of
the size drawn — a 30 pt drop-rail cover and a full-width grid cell shared the
same 512 px `NSImage`. Zero references remain outside comments (and the
untouched `Debug/` bake-off harness, which keeps its own copy of the decode
path on purpose).

**Every call site passes its own bucket.** This is the point of C1; requesting
512 everywhere would have preserved the bug in new clothing.

| call site | drawn size | bucket at 2× |
|---|---|---|
| grid cell (`CollectionView` → `CollectionCell`) | analytic masonry frame, per cell | 128–512, varies |
| drag preview (`CollectionView`) | 84 pt | 192 |
| `CoverCard` (Collections gallery, Spaces list) | 204 pt (220 column max − 16 pt card inset) | 512 |
| `CollectionDropRail` cover | 30 pt | **128** |
| `CollectionStackCard` fan tile | 92 pt | 192 |
| `AddFromLibrarySheet` cell | 120 pt (columns max) | 256 |
| `LibrarySearch` result cell | 140 pt (columns max) | 384 |

The grid is the one site whose size is genuinely per-item, so the bucket is
computed by the GRID from the cell's analytic `MasonryLayout` frame — the same
frame the marquee hit-test and the cell offset read — and passed down.
`CollectionCell` never guesses, because its frame is applied by its parent.
`bucket` joins `CollectionCell`'s `==`, without which the `.equatable()` skip
would keep a stale bitmap across a ⌘± density step that crossed a boundary.

For the two `LazyVGrid` sheets the bucket is derived from the columns'
`maximum:`, hoisted to a `maxCellSide` constant next to the `GridItem` so the
two cannot drift. That is an upper bound, not the live width — an adaptive grid
narrower than its maximum decodes slightly more than it draws. Deliberate: the
alternative is a `GeometryReader` per sheet for at most one bucket step.

**`CGImage` all the way to the draw.** `ThumbnailTile` now takes a `CGImage`
and draws `Image(decorative:scale:orientation:)`. It is NOT round-tripped back
through `NSImage` to keep the old `Image(nsImage:)` — that would reintroduce
the exact lazy-provider cost `176` measured (1.07 ms at first draw, on the main
thread, mid-scroll). `decorative:` because the accessibility label lives on the
cell; a label here would double-announce every grid item.

**Two-step paint.** `AsyncThumbnail` keys on `hash + bucket` and paints a
bucket-TOLERANT synchronous hit first (any bucket already decoded for that
hash, larger preferred), then awaits and swaps in the exact bucket only if the
first hit wasn't already exact. This is what makes C2's density tolerance work
in practice: most ⌘± steps stay in-bucket and re-decode nothing, and a step
that does cross paints instantly from the neighbour while the exact one loads.

**Window-driven prefetch.** New pure `masonryPrefetchIndices(…)` in
`GridWindowing.swift` (same geometry as `masonryVisibleIndices` at twice the
overscan, minus the rendered set) and a `ThumbnailWindowPrefetcher` holding the
outstanding-hash bookkeeping. Driven from the existing band-change seam, which
already fires a few times per screenful. Requests carry the same per-cell
bucket the cell will ask for — a prefetch at the wrong bucket is a decode the
visible cell then has to repeat. Held in plain `@State`, like `moveTargetsCache`,
so mutating it does not re-render the grid on the frame already doing the most
work.

The other call sites got no prefetch: none of them knows an upcoming working
set worth guessing at.

## A correctness rule worth stating once

`masonryPrefetchIndices` excludes the rendered window, and
`ThumbnailWindowPrefetcher.update(requests:keep:)` takes the rendered hashes as
`keep`. Both exist for the same reason, and it is not an optimization: a
visible request JOINS an in-flight prefetch task rather than starting a second
decode. So a hash crossing from the prefetch ring into the visible window would,
without `keep`, be cancelled by the next band change — cancelling the very
decode the on-screen cell is awaiting, and blanking it. Tested both ways.

## Files changed

- `AtelierRefs/AtelierRefs/SharedThumbnail.swift` — `ThumbnailCache` **deleted**;
  `AsyncThumbnail` / `AssetContentThumbnail` / `CoverCard` take a bucket;
  `ThumbnailTile` takes a `CGImage`.
- `AtelierRefs/AtelierRefs/CollectionCell.swift` — `bucket` input, in `==`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — per-cell bucket from the
  analytic frame; `prefetchThumbnails(…)` on the band seam; drag-preview bucket.
- `AtelierRefs/AtelierRefs/GridWindowing.swift` — `masonryPrefetchIndices(…)`.
- `AtelierRefs/AtelierRefs/ThumbnailPipeline.swift` — `ThumbnailWindowPrefetcher`.
- `AtelierRefs/AtelierRefs/CollectionDropRail.swift`,
  `CollectionStackCard.swift`, `AddFromLibrarySheet.swift`,
  `LibrarySearch.swift` — buckets from their own sizes.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — stale `ThumbnailCache` doc ref.
- `AtelierRefs/AtelierRefsTests/GridWindowingTests.swift` +4,
  `ThumbnailPipelineTests.swift` +5.

`AtelierIngestion` is untouched — C1 already opened everything C3 needed.

## Migration notes

- `ThumbnailTile(image:)` now takes `CGImage?`, not `NSImage?`. It is internal
  and had two callers, both in this file; any new caller must decode through the
  pipeline rather than hand it an `NSImage`.
- The default bucket on `AsyncThumbnail` / `AssetContentThumbnail` /
  `CollectionCell` is the 512 tier ceiling, so a NEW surface that forgets to
  pass one is merely wasteful, never blurry. That is a deliberate failure
  direction, not an endorsement of the default — pass a real size.
- **`Debug/` was not touched**, per the bake-off's requirement that the measured
  harness stay bit-identical. Its SwiftUI modes build the real `CollectionCell`,
  so they DO pick up the pipeline (`CGImage`, fully decoded off-main) — but they
  do not pass a `bucket`, so they take the 512 default. See the note to `036`
  below.

## Found while implementing — should amend `036`

1. **`cancelPrefetch` cannot interrupt a decode already in progress.** The
   pipeline checks `Task.isCancelled` once, BEFORE entering the decode closure,
   so cancellation reliably drops queued work and is a no-op against work
   already inside ImageIO. `036` §4 C1 describes prefetch cancellation without
   qualifying this. It is the right design (an ImageIO decode is not
   interruptible mid-flight anyway, and the result is cached rather than
   discarded), but a test that asserts "cancelled ⇒ not cached" is racy, and one
   was written and corrected here.

2. **The DECISION GATE will measure C3 only partially, and `036` §5 step 4
   should say so.** The harness's SwiftUI modes build the real `CollectionCell`,
   so they inherit the pipeline — the eager off-main decode, which is the effect
   §5's falsifiable prediction is actually about, IS measured. What they do not
   inherit is the bucketing: they never pass `bucket:`, so every cell takes the
   512 default, while the production grid asks for 128–512 per its analytic
   frame. So the gate measures the decode-timing half of C1+C3 and none of the
   cache-pressure / texture-size half.

   That skews the gate CONSERVATIVE (it under-reports the improvement), so a
   "Smooth" verdict from it is trustworthy and a "Not smooth" one is not
   conclusive. Worth stating explicitly before the numbers exist, since the
   pre-registered rule turns that verdict into a 9-day decision. Passing the
   frame-derived bucket in the harness's `masonryCell` would close the gap and
   is a one-line change — but it is a change to a harness that must stay
   bit-identical to what was already measured, so it is a decision for whoever
   runs step 4, not something done here.

3. The C3 spec lists "the rail, the stack view" and the covers; grepping found
   **three more** consumers (`AddFromLibrarySheet`, `LibrarySearch`, and the
   drag preview, the last of which §4 C3 does mention in passing). All migrated.
</content>
</invoke>
