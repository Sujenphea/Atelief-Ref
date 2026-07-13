# 093 — UI smoke tests realigned to the nav shell

The two XCUITest smoke tests still drove the old 3-tab `TabView`
(`Canvas / Library / Sweeps`) that the navigation redesign (087) removed, so they
had been failing since that change. Rewritten against the current
`NavigationStack` shell.

## Summary

- **`NavModel.restoreIfNeeded`**: honours a `-uitest-fresh-nav` launch argument
  to skip last-collection restore, so UI tests land on a deterministic root (the
  Collections gallery) instead of whatever collection was last opened.
- **`AtelierRefsUITests`**:
  - `testLaunchAndSwitchTabs` → **`testLaunchAndNavigateShell`**: asserts the
    app-level Spaces / Sweeps toolbar affordances (the former tabs, now reachable
    from every screen) and that opening Spaces pushes the Spaces list.
  - `testLibraryShowsFolderChrome` → **`testGalleryShowsUnsortedCollection`**:
    asserts the protected Unsorted collection card on the gallery root after
    bootstrap (replacing the old folder-sidebar check).
  - `testLaunchPerformance` unchanged.

## Files changed

- Edited: `AtelierRefs/AtelierRefs/NavModel.swift` (test-only fresh-nav hook),
  `AtelierRefs/AtelierRefsUITests/AtelierRefsUITests.swift` (both smoke tests)

## Migration notes

None — test-only, plus a launch-argument guard that is inert in normal runs.

## Tests

Both rewritten UI tests pass (`testLaunchAndNavigateShell`,
`testGalleryShowsUnsortedCollection`); `testLaunchPerformance` retained.
