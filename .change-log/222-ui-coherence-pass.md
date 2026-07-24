# 222 — UI coherence pass (titles, counts, empty states, search density)

## Summary

A cross-page consistency sweep so pages stop each inventing their own title
scale, padding, empty state, and grid density. Decisions were confirmed with the
user before implementing.

- **One page-title role.** `Theme.Typography.sectionTitle` is redefined to **15pt
  semibold** (the old Home section-header look) and is now the single title token.
  Home section headers, the Collection page title, the Space page title, and the
  detail-inspector section headers all use it — previously `.title3.semibold` /
  `.title2.bold` / `.headline` / 20pt regular respectively.
- **Counts everywhere.** Home sections ("Collections", "Spaces") and the Search
  results panel now show a count in the same `.callout` / secondary-ink style the
  Collection and Space headers already used.
- **Space title de-duplicated.** Dropped `SpaceView`'s native `.navigationTitle`
  so the name shows only in the in-content header (parity with Collection).
- **Search grid matches the collection grid.** Search results now honour the
  persisted global density notch (was hardcoded 4-up `.default`) and drive the
  same `⌘±` zoom, instead of ignoring the preference and offering no control.
- **Empty states unified on `ContentUnavailableView`.** The Collection grid's
  bare tertiary `Text` and the Space canvas's bespoke `VStack` are now icon +
  title + description like Spaces / Sweeps / Search already were.
- **Item detail sits on the panel tone.** `ItemDetailView` backgrounds on
  `Theme.Colors.panel` (#212121) instead of the system `.background`, so opening
  an item is no longer a colour jump.
- **Token migration on the touched surfaces.** Hardcoded fonts / spacings / radii
  on Home, Collection, Space, and Search were swapped for `Theme` tokens
  (`sectionTitle`, `Spacing.*`, `Radius.tile`/`card`/`cover`). Selection-ring radii
  now reference each surface's own radius token (masonry `tile`, home `cover`).

## Files changed

- `Theme.swift` — `Typography.sectionTitle` → 15pt semibold; doc updated.
- `CollectionsGalleryView.swift` — section header uses the token + inkPrimary and
  takes a `count:`; ring radii → `Radius.cover`; spacing/padding → tokens.
- `CollectionView.swift` — title → `sectionTitle`; content padding → `Spacing.xl`
  (24); empty state → `ContentUnavailableView`; grid spacing/inset, drop-overlay
  and skeleton radii → tokens.
- `SpaceView.swift` — title → `sectionTitle`; removed `.navigationTitle`; empty
  hint → `ContentUnavailableView`; header padding → tokens.
- `LibrarySearch.swift` — `LibrarySearchable` / `LibrarySearchResults` take
  `GridViewPreferences`; results grid uses global density + `⌘±` zoom; result
  count in the mode-picker row; spacing/inset/padding → tokens.
- `AppShellView.swift` — pass `gridPrefs` into every `LibrarySearchable`.
- `ItemDetailView.swift` — background → `Theme.Colors.panel`.
- `MasonryGridItem.swift` — cell/ring `cornerRadius` → `Theme.Radius.tile`.

## Notes / not done

- **Collection header stickiness (deferred).** The user prefers Home's behaviour,
  where the title scrolls away with content. The collection header is currently
  pinned above an internally-scrolling `NSCollectionView`; making it scroll away
  requires the header to live inside the grid's scroll region (a boundary
  supplementary header in `MasonryCollectionLayout` + `MasonryGridHost`). That is a
  contained but non-trivial AppKit change with test implications, so it is left as
  a focused follow-up rather than bundled into this pass.
- **Sidebar "No spaces yet"** stays a compact rail row — `ContentUnavailableView`
  is a full-pane treatment and does not fit a sidebar section.
- **Menus** already converge on `.borderlessButton` for every live menu (sidebar,
  collection overflow, detail); no change needed. Selection bars were already
  unified via `SelectionActionBar` (215).
- Remaining hardcoded values in `BulkSweepsView` / `SettingsView` /
  `FloatingAddButton` were left for a later token pass (not user-facing pages in
  this sweep).

## Migration notes

None — no API or data changes. `LibrarySearchable` gained a required
`gridPrefs:` parameter; all call sites (in `AppShellView`) are updated.
