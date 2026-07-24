# 223 — Collection header scrolls away; chips removed; import floated

## Summary

Collection-page follow-ups to 222, confirmed with the user:

- **Header scrolls away (the motivating issue).** The Collection title row (name +
  "N items" + New-Subfolder button) now lives INSIDE the grid's scroll region and
  scrolls off the top with the content, like Home — instead of pinning above the
  grid. Implemented as a non-pinned boundary supplementary header in the AppKit
  masonry grid (`MasonryCollectionLayout` + `MasonryGridHost`), so it costs nothing
  at scroll time (no SwiftUI re-render per tick).
- **Subfolder chips removed.** The in-page horizontal chip row duplicated the
  sidebar's collection tree, which already shows and navigates subfolders. Removed
  it and its now-orphaned context menu.
- **Import progress floated.** The batch progress bar is now a floating pill at the
  bottom (stacked above the selection bar when both show) instead of sitting inline
  in the header — so an in-flight import no longer reflows the title row.

## How the scroll-away header works

- `MasonryCollectionLayout` gains `headerHeight`. When > 0 it folds that band into
  the top inset it solves items against (so marquee / hit-test / keyboard-nav math,
  all riding `solved.frames`, shift with it automatically) and emits a single header
  supplementary attribute at content `y ∈ [0, headerHeight]` — NOT pinned.
- `MasonryGridHost` registers a `MasonryHeaderContainer` (an `NSView` wrapping an
  `NSHostingView`) for the header kind, supplies it via the diffable data source's
  `supplementaryViewProvider`, and refreshes its SwiftUI `rootView` on every
  `update` (the provider isn't re-invoked for in-place name/count edits).
- `GridHostConfiguration` gains `header: AnyView?` + `headerHeight`. Search passes
  neither, so its grid is byte-for-byte unchanged (no header attributes emitted).
- `CollectionView` passes `headerContent` into the grid config; the reserved band
  height is the header's MEASURED natural height (a hidden off-screen copy reports
  it via `onGeometryChange`, seeded near the real value to avoid a first-frame
  overlap), so the band hugs the row. The header→grid gap is the grid's `topInset`,
  restored to the pre-222 12pt. The header also renders above the loading skeleton
  so the title never blinks out on a collection switch. The ⌘V paste hook stays in
  the SwiftUI key path (a shortcut button hosted inside the AppKit header wouldn't
  receive key events).

## Files changed

- `MasonryCollectionLayout.swift` — `headerHeight`; header supplementary attributes
  in `prepare()`; header included in `layoutAttributesForElements`; new
  `layoutAttributesForSupplementaryView`.
- `MasonryGridHost.swift` — `masonryHeaderKind`, `MasonryHeaderContainer`, config
  `header`/`headerHeight`, registration + provider + live refresh on `update`.
- `CollectionView.swift` — header → `headerBar` hosted in the grid; chips + their
  menu removed; import → floating `importIndicator`; paste hook moved to `content`;
  header shown over the skeleton; title `lineLimit(1)`.

## Verification

- Builds clean; `MasonryCollectionLayoutTests` pass (default `headerHeight == 0`
  keeps the prior geometry exactly, so the zero-invalidation-on-scroll guarantee is
  untouched).
- NEEDS an interactive smoke test (can't be automated here): (1) the header scrolls
  away and returns; (2) the New-Subfolder button inside the hosted header still
  fires; (3) hover / marquee / selection rings / keyboard nav still line up with
  cells now that items sit below the header band; (4) title updates live on rename
  and count updates on import/delete.

## Migration notes

`GridHostConfiguration` gained two defaulted fields (`header`, `headerHeight`); all
existing call sites compile unchanged. No data changes.
