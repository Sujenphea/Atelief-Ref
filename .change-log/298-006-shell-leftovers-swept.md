# 298 — 006 shell leftovers swept

Residue from the 193 shell migration that the compiler could not flag: a view
nobody constructs, two enum cases nobody selects, and a UI smoke suite testing a
toolbar that no longer exists. Each one read as intentional, which is the cost.

## Summary

- **`SpacesListView.swift` deleted** (132 lines). Zero construction sites —
  `SpacesOutlineView` (sidebar) and the gallery's Spaces section replaced it. Its
  delete-confirmation state (`IngestionModel.pendingSpaceDeletion`) is still very
  much alive; the dialog moved to `ContentView`, and the doc comment that still
  pointed readers at `SpacesListView` now says so.
- **`SidebarItem.search` removed.** Nothing ever called `selectSidebar(.search)`
  and `restoredSelection()` only ever returns `.collection` or `.home`, so the
  `case .home, .search:` arm in `AppShellView` was unreachable. Search became the
  panel's persistent toolbar field (`LibrarySearchable`).
- **`AppRoute.spaces` removed**, along with the `EmptyView()` branch it routed
  to. It was labelled "legacy route; retained for compatibility", but nothing
  pushes it and nothing persists `AppRoute` — there was no compatibility to keep.
- **`AtelierRefsUITests` target removed** — sources, the target, its dependency,
  proxy, build phases, configuration list, and both build configurations.

## Why the UI suite went rather than got fixed

`testLaunchAndNavigateShell` asserted `app.buttons["Sweeps"]` at launch. That
toolbar has not existed since 193 moved Spaces/Capture into the sidebar and put
Sweeps behind Capture ▸ "Bulk Import Sweeps…"; the only `"Sweeps"` string left in
the app is a `Text` in the sheet header, so no such button *can* exist at launch.
The suite had therefore been red for long enough that it gated nothing — a
permanently-failing smoke test is worse than none, because it trains you to
ignore the one signal that would catch a broken launch. Removed rather than
rewritten, deliberately: the unit suites carry the coverage, and XCUITest against
a custom AppKit sidebar is a real project rather than a patch. Verified stale
independently of this work by running it at `4fde3c2`, where it fails identically.

**One trap for whoever removes a target next.** The UI target's build
configurations are `990778962…` / `990778972…` (the pair carrying
`PRODUCT_BUNDLE_IDENTIFIER = sujenphea.AtelierRefsUITests`). The adjacent
`9907788D…` / `9907788E…` — which look like they belong to the same block — are
the **project's** Debug/Release configs. Removing those yields "The project
contains no build configurations - it may have been damaged" and the project will
not open. Match configs by their contents, never by id adjacency.

## Files changed

- Deleted: `AtelierRefs/AtelierRefs/SpacesListView.swift`,
  `AtelierRefs/AtelierRefsUITests/` (both sources).
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — UI test target and all
  its objects removed (116 lines); no `UITests` reference remains.
- `AtelierRefs/AtelierRefs/NavModel.swift` — `SidebarItem.search`,
  `AppRoute.spaces` removed.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — the two arms that handled them.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — stale doc comment corrected.
- Tests: `NavModelTests.swift` — "non-collection routes are left untouched" now
  exercises `.capture` + two `.space` entries (the coverage is unchanged; it no
  longer needs dead cases to express it). `CollectionActivationTests.swift` drops
  `.search` from the destinations it enumerates.

## Test results

`AtelierRefs` scheme — **TEST SUCCEEDED**. The scheme's full `test` action is now
green end to end, which it was not before: the UI suite made every run red.

## Migration notes

No behaviour change and no persisted state affected — nothing serialises
`SidebarItem` or `AppRoute`. `xcodebuild ... -scheme AtelierRefs test` no longer
builds or runs a UI test bundle; nothing else referenced that target.
