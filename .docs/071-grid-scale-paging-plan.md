# 071 · Grid scale — windowed collection reads

**Kind:** plan
**Status:** proposed, not started
**Relates to:** 036 (AppKit grid), 037 (grid bake-off), 038 (grid spike), 056
(production ship overview), 011-B1 (masonry frame math), 307/309 (post grouping)

---

## 1. The problem, as measured

`ScaleHarnessTests` (release build, `ATELIER_SCALE_N`) over a seeded library:

| N | `collectionItems` | FTS search | seed |
|---:|---:|---:|---:|
| 2,000 | 64.75 ms | 8.03 ms | 0.754 ms/asset |
| 5,000 | 149.29 ms | 17.33 ms | 0.893 ms/asset |
| 10,000 | 305.98 ms | 35.90 ms | 1.228 ms/asset |
| 20,000 | 750.05 ms | 82.70 ms | 2.449 ms/asset |

Opening a collection is linear in N and crosses the perception threshold
(~100 ms) somewhere around 3,000 items. At 20,000 it is a visible three-quarter-
second wait. Search is not a problem at any measured size, and the 82.70 ms
figure is a deliberate worst case — the harness query `swatch` matches *every*
row, so it ranks 20,000 candidates to return a page.

Only `Unsorted` is realistically going to reach these sizes, but it is also the
collection people open most.

## 2. What already exists — do not rebuild it

This is the first thing to establish, because the obvious proposals ("show
placeholders", "virtualise the grid") are already implemented and are not where
the time goes.

- **Per-cell placeholder tint.** `MasonryGridItem.setImage(nil)` paints
  `Theme.NS.mediaBackdrop` into the cell's layer and clears it only when the
  decoded `CGImage` lands (`MasonryGridItem.swift:958`). `prepareForReuse`
  resets to that state, so a recycled cell is a grey tile until its decode
  resolves.
- **Masonry-shaped load skeleton.** `CollectionView.gridSkeleton`
  (`CollectionView.swift:645`) draws `.quaternary` tiles at deterministic
  aspects while `loadedCollectionID != collectionID`. This is what is on screen
  for the whole 750 ms today.
- **Cell virtualisation.** `NSCollectionViewDiffableDataSource` plus
  `NSCollectionViewPrefetching` on the coordinator
  (`MasonryGridHost.swift:414`, `:891`), feeding the bucketed, byte-budgeted,
  off-main `ThumbnailPipeline`. Only visible-plus-prefetch cells exist or
  decode. The SwiftUI windowed path was deleted in 036 §4 A4.

**Consequence:** placeholders make the wait *legible*, not *shorter*. The
remaining cost is entirely upstream of the view layer.

## 3. Where the 750 ms actually goes

`AppServices.collectionItems(in:sort:)` (`AppServices.swift:1685`) is a single
`CollectionItem ⋈ Asset ⋈ Source` join — no N+1 — that materialises **all N**
`CollectionItemDetail` values before the model can publish anything. Its own
doc comment records the contract as deliberate:

> Collection-scoped, so the FULL array is returned (P16 — the views need every
> item), which is why no keyset cursor is needed here.

Two mechanical facts make the per-row cost higher than it looks:

1. **UUIDs are stored as lowercase TEXT.**
   `AppServices.key(_:) = id.uuidString.lowercased()` (`:3228`). Each
   `CollectionItemDetail` therefore round-trips roughly six 36-byte strings back
   through `UUID(uuidString:)` — `item.id`, `item.collectionID`, `item.assetID`,
   `asset.id`, `asset.sourceId`, `source.id`. At 20,000 rows that is ~120,000
   UUID parses and ~120,000 transient `String` allocations.
2. **`Asset` is a wide row.** ~20 columns including `payload` (JSON TEXT),
   `searchText` (denormalized FTS text), `note`, `name`, `dedupKey`. The grid
   reads almost none of them.

> **Hypothesis, not yet measured.** I believe decode dominates the SQL scan
> here, and that the wide-column half matters *less* than it appears because the
> harness seeds plain images, whose `payload`/`searchText`/`note` are all `nil`.
> If that is right the win comes from decoding *fewer rows*, not narrower ones —
> which points at paging over projection. **Phase 0 exists to settle this before
> any code is written.** A real library with tweets and links has fat columns the
> harness does not.

## 4. The constraint that shapes everything

`MasonryLayout.swift:11-17` names it directly:

> the virtualization trap: only on-screen cells exist, so live cell frames can't
> see offscreen rows — computed frames must

The masonry frame solve is deliberately kept over **every** item, offscreen
included, because the marquee hit-test and keyboard column arithmetic resolve
against computed frames rather than live cells. That needs an aspect ratio per
item, which needs a row per item. So the full array is not incidental — it is
load-bearing.

Auditing every consumer of `IngestionModel.items`, the ones that genuinely need
all N are:

| Consumer | Needs |
|---|---|
| Masonry frames, content height (`MasonryLayoutCache`) | `width`, `height` |
| Diffable snapshot, `selectionStore.prune` | `item.id`, ordered |
| ⇧-range / arrow nav / select-all (`GridNavigation`, `GridSelection`) | `item.id`, ordered |
| `assetIDsByItemID` (`IngestionModel.swift:558`) | `(item.id, asset.id)` |
| `favoriteAssetIDs` (`:2298`) | `asset.id`, `isFavorite` |
| `mostViewedReorder` (`:1958`) | `asset.viewCount` |
| Reorder + undo `priorOrder` (`:1981`, `:2012`, `:2216`, `:2246`) | `asset.id`, ordered |
| `PostGroups` (`PostGrouping.swift:159`) | `source` provenance URL + carousel index |

Everything else — cell configuration, detail overlay, context menu, drag
pasteboard, the three export paths — needs full detail for a *subset*
(visible window, selection, or one item), and the export paths are already
async with progress UI.

`PostGroups` is the awkward one: `postGroupKey(for: detail.source)` normalises
the source URL, so a narrow row cannot simply drop `source.original_url`. See
§6.3.

## 5. Phase 0 — measure before choosing (blocking gate)

Two probes. Neither is speculative work; both answer a question that changes the
plan.

**0a — split the 750 ms.** Extend `ScaleHarnessTests` to time, separately:
(i) `SELECT COUNT(*)` over the same join (scan only, no decode);
(ii) a raw `Row.fetchAll` with no struct mapping;
(iii) the current full `CollectionItemDetail` mapping;
(iv) a hand-written narrow projection of the §4 columns.
Run at N = 5,000 / 20,000, release.

*Decides:* whether §6.1 (narrow row) is worth doing on its own, or is only
useful as the enabler for §6.2 (windowing).

**0b — settle the scroll question.** The bake-off harness already exists and is
scriptable: `GridBakeoffWindow` behind `-grid-bakeoff`, with
`-grid-bakeoff-autorun mode=…,duration=…,repeats=…,out=…` and `-library-root`
pointing at a throwaway library (`Debug/GridBakeoffWindow.swift:1-19`,
`Debug/BakeoffAutorun.swift:33-53`). It owns its own `IngestionModel`, so a run
cannot disturb the real library.

Seed a 20,000-item library, run the existing autorun matrix, compare against the
recorded 200-item baseline in 037/038.

*Decides:* whether scroll is a problem at all. A 750 ms open is paid once per
collection; a dropped frame is paid on every gesture. **If 0b is bad, it
outranks everything below.**

## 6. The change, in three stages

Gated on Phase 0. Each stage ships independently and leaves the app correct.

### 6.1 — Narrow the all-N row

Introduce a projection type in `AtelierCore` alongside the existing detail:

```swift
/// The per-item facts the grid needs for EVERY item in a collection — the
/// layout solve, selection arithmetic, and the diffable snapshot. Deliberately
/// excludes every column only the visible cells or the detail overlay read.
public struct CollectionItemSummary: Sendable, Equatable {
    public let itemID: UUID
    public let assetID: UUID
    public let kind: AssetKind
    public let width: Int?
    public let height: Int?
    public let isFavorite: Bool
    public let viewCount: Int
    public let blobHash: String?      // the thumbnail key — cheap, avoids a
                                      // second round-trip for the visible window
    public let postGroupSourceURL: String?   // see §6.3
    public let carouselIndex: Int?
}
```

and `func collectionItemSummaries(in:sort:) -> [CollectionItemSummary]` using
the same `ORDER BY` ladder, selecting only these columns.

`IngestionModel` grows `summaries: [CollectionItemSummary]` beside `items`.
Nothing else changes yet — `items` is still fully populated. This stage is
purely additive and independently testable: assert
`collectionItemSummaries` is order-identical and count-identical to
`collectionItems` for all three sort modes, at every N the harness runs.

### 6.2 — Window the detail hydration

`loadContents(of:)` becomes:

1. `collectionItemSummaries` → publish → grid can solve frames, snapshot, and
   paint placeholder cells. **This is the new time-to-first-paint.**
2. A `DetailWindow` actor hydrates full `CollectionItemDetail` in ranges as the
   coordinator's `prefetchItemsAt` reports them, keyed by `item.id`, with the
   same load-ID staleness guard `loadContents` already uses.
3. `items` becomes a sparse `[UUID: CollectionItemDetail]` cache rather than a
   dense array. Every consumer that reads it for a *subset* takes a
   `detail(for:) async` seam; the consumers in the §4 table move to `summaries`.

The call-site churn is the real cost of this stage — roughly the 27 `model.items`
references in `AtelierRefs/`, of which the exports (`ContactSheetExport.rows`,
`CollectionSiteExport`, `ExportWebPageAction`) want a bulk re-fetch rather than
the window, and should call `collectionItems` directly at export time.

**Selection-dependent paths must not regress.** ⌘A over 20,000 items, then
Copy or Delete, has to hydrate what it needs — that is a bulk fetch by id, not
20,000 window misses.

### 6.3 — Post grouping

`PostGroups(items:)` needs a normalised URL per item, so §6.1 carries
`postGroupSourceURL` and `carouselIndex` in the summary. That keeps one
`TEXT` column in the all-N read.

If Phase 0a shows that column is itself material, the fallback is to build
`PostGroups` on a background task *after* first paint and bump `itemsVersion`
when it resolves — carousels collapse a beat after the grid appears. This is
acceptable (the toggle already forces a re-solve via `itemsVersion`, per the
`GridHostConfiguration` doc comment) but it is a visible reflow, so prefer
carrying the column.

## 7. Rejected alternatives

- **Two-stage publish** (fetch first 500 rows, publish, fetch the rest, publish
  again). Roughly a tenth of the work and gets most of the perceived win.
  Rejected as the *destination* but worth keeping as a fallback if §6.2's call-
  site churn proves too invasive to land safely before ship. Its costs: the
  scrollbar jumps when the second publish lands, and select-all / keyboard nav
  are briefly wrong — which is a correctness wobble, not just a cosmetic one.
- **Keyset-cursor paging at the service layer.** Clean for an infinite feed,
  wrong here — the masonry solve needs the last item's aspect to know the
  content height, so a cursor that has not reached the end cannot produce a
  correct scrollbar.
- **Store UUIDs as BLOB.** Probably the single largest mechanical win available
  and it would help every read in the app, not just this one. Rejected *for this
  plan* — it is a schema migration touching every table and every query, with
  backup/restore and archive-import implications (068), and it should be its own
  document rather than a rider on a grid change.
- **Cap the grid at N items with a "show more".** Rejected: `Unsorted` is
  exactly where people scroll to the bottom looking for something they just
  captured.

## 8. Test plan

- `ScaleHarnessTests`: extend with the Phase 0a breakdown; add a summary-vs-
  detail parity assertion across all three sort modes.
- New `CollectionItemSummaryTests` in `AtelierCoreTests`: order and count parity
  with `collectionItems`, including the `.mostViewed` tie-break ladder.
- `GridSelectionStoreTests`, `MostViewedReorderTests`, `AppUndoTests`,
  `PostGroupingTests` all currently build fixtures via `collectionItems` /
  `setItemsForTesting` — they are the existing regression net for §6.2 and must
  keep passing unmodified where possible.
- `CollectionActivationTests` guards the skeleton-vs-content transition; §6.2
  changes when `isLoaded` flips, so these assertions need re-reading rather than
  re-writing.
- Bake-off autorun at 20,000, before and after, as the scroll regression gate.

## 9. Sequencing

```
Phase 0a ─┐
          ├─→ decide → 6.1 → 6.2 → 6.3
Phase 0b ─┘   (0b may pre-empt: fix scroll first)
```

**Exit criterion:** opening a 20,000-item collection paints a laid-out
placeholder grid in under 100 ms, and scrolling it holds frame at the bake-off's
recorded threshold.

**Recommendation:** run Phase 0 before committing to any of §6. If 0a shows
decode dominates and 0b shows scroll is healthy, §6.1 + §6.2 is the right
investment. If 0b shows scroll is *not* healthy at 20k, stop and re-plan —
a fast open onto a janky grid is the worse outcome.

**Ship consideration:** none of this blocks a release aimed at libraries under
~5,000 items, where the open is already 149 ms. It becomes necessary as soon as
`Unsorted` is expected to hold five figures.
