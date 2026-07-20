# 174 — Bake-off: restore production fidelity to both SwiftUI grid modes

## Summary

The 037 bake-off's two SwiftUI modes stubbed out the per-cell work production
actually pays. Every divergence made the harness **cheaper** than production, all
in the same direction, so the experiment was one-directionally biased: it could
honestly REJECT the SwiftUI option but never honestly ACCEPT it — which is
backwards, since accepting it is what cancels the 1–2 week `NSCollectionView`
rewrite. A "Smooth" verdict would have been an artifact of the stubs.

Restored, in the `.full` wrapper branch only, **identically in both modes**:

1. **Real drag preview** — production's `AssetContentThumbnail(asset:url:)` at
   84×84 with the count badge, replacing `Color.clear.frame(1×1)`. 035 §4:
   230 ms/20 s. The payload is now a model-shaped per-cell query matching
   `dragPayload(forCellItemID:)` (whole selection when the cell is selected, else
   the cell alone) rather than a literal — and its `sourceCollectionID` is a fixed
   constant instead of a freshly minted `UUID()` per cell per build.
2. **Real context menu** — production's two-`Menu` structure, each with a
   `ForEach` over move destinations plus the inner divider, the conditional
   "Set as Cover", a `Divider`, and the two counted destructive verbs. Replaces
   one `Button("Placeholder")`. 035 §4: 122 ms/20 s.
3. **Marquee capture + rectangle layers and the named coordinate space** — the
   full-content-rect `.contentShape(Rectangle())` and `DisplayLinkHost` NSView
   that make up the hit-test surface 035 §3 still measures at 385 ms/20 s after
   windowing. `itemIDs` is rebuilt per parent pass exactly as production does.
4. **Real selection lookups** — a deterministic scattered ~10% selection (every
   10th item, no randomness) with a `lead`, so each cell performs a genuine
   `Set.contains` and a `lead` comparison instead of hardwired `false`. Because
   the selection is non-empty, `isSelecting` is true, so the **production**
   `selectionCircle` (a `Button` + palette `Image` + backing `Circle`) now draws
   on every visible cell, as it does in production during triage.

`.stripped` is deliberately **unchanged** — no wrappers, no marquee layers, no
coordinate space, no selection lookups. It is the control that 037 §2's wrapper
axis depends on; restoring cost into it would have destroyed the comparison.

## How the two modes are kept identical

The modes must differ in exactly one thing (the `Equatable` cell) or the
experiment is void. Two mechanisms enforce that:

- The cell **leaves** — drag preview, context menu, selection circle, seeded
  selection, destination fixtures — are defined once in `BakeoffCellFidelity` /
  `BakeoffSelection` and called with the same arguments from both files. They
  carry no "equatable or not" parameter, so they add no branch to either hot
  path. This makes identity a compile-time fact rather than a review promise;
  duplicating them would leave a standing risk that one file's menu drifts by a
  `Button` and the modes quietly stop being comparable.
- The cell **hosting structure** stays duplicated, as before, because that is the
  variable under test. A normalised diff of the two grid bodies now differs only
  in the `ForEach` body (inline `@ViewBuilder` call vs `MasonryCellView` +
  `.equatable()`), and the two `.full` cell trees differ only in line wrapping
  and the hover routing that `.equatable()` structurally requires.

## Destination count

`BakeoffCellFidelity.destinationCount = 4`, matching the user's measured real
library (4 collections). Split as 1 subfolder + 3 roots so **both** `ForEach`
branches of production's `targetButtons` and the divider between them render.

Menu cost scales **linearly** in this number and is paid **twice per cell** (both
"Move to" and "Add to" enumerate the same list). A user with 40 folders pays ~10×
the `cellMenu` component — order 1.2 s/20 s against 035 §4's 122 ms/20 s
baseline. If the verdict lands near a threshold, re-run with this raised to the
largest library that must stay smooth before trusting the margin.

## `==` change

`MasonryCellView` gains one stored input, `actionTargets: [UUID]`, and it is
included in `==`. It drives the drag payload and the menu's counted verbs, so
omitting it would ship a cell that drags the **wrong assets** — the one
stale-cell variant that destroys data rather than merely drawing wrong. Cheap to
compare despite being an array: every selected cell is handed the same
copy-on-write buffer, so `Array.==` short-circuits on buffer identity, mirroring
`IngestionModel.cachedSelectedAssetIDs`.

## Known residual divergences (all documented in-file)

- **Callbacks are inert.** Marquee/drop/menu/press actions do nothing — the
  harness carries no `IngestionModel` by seam design. Direction: negligible; a
  programmatic scroll fires none of them. The TREES, which are the measured cost,
  are all built.
- **Destinations are synthetic**, not a real folder tree. Count and shape match
  production; names/ids do not. Direction: neutral.
- **`moveTargets` is a `static let`**, where production memoises via
  `MoveTargetsCache`. Direction: harness marginally cheaper (one memo lookup per
  cell), well under a microsecond.
- **The 4 destinations reflect today's library**, not a power user's. Direction:
  harness cheaper for larger libraries — see the scaling note above.

## Files changed

- `AtelierRefs/AtelierRefs/Debug/SwiftUIWindowedBakeoffGrid.swift`
- `AtelierRefs/AtelierRefs/Debug/SwiftUIEquatableBakeoffGrid.swift`
- `AtelierRefs/AtelierRefsTests/MasonryCellEquatableTests.swift`

## Migration notes

None — Debug bake-off harness only, no production code path touched. Bake-off
numbers taken **before** this change are not comparable to numbers taken after
and must be discarded.
