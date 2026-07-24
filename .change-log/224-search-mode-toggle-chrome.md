# 224 — Search mode toggle: app chrome, right-aligned

## Summary

Restyled the keyword / meaning switch at the top of the search results panel so it
matches the app's design system instead of the stock macOS `.segmented` `Picker`, and
moved it to the trailing edge.

- New `SearchModeToggle` (private, `LibrarySearch.swift`): a `field` capsule holding two
  pill segments, the active one raised to `selection` with `inkPrimary` ink and a
  `hairline` border — the same monochrome language as the selection action bar
  (`.selectionBarChrome()` / `SelectionBarIcon`), so the search surface reads as one
  coherent chrome.
- `modePicker` row reordered: the "N results" count now takes the **leading** slot and
  the toggle sits **trailing**, aligned to the grid's 24pt content margin.
- A subtle `Theme.Motion.gentle` fill transition on selection change.

## Files changed

- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — replaced the `Picker(.segmented)` in
  `LibrarySearchResults.modePicker` with `SearchModeToggle`; swapped count/toggle order;
  added the `SearchModeToggle` view.

## Notes

- Behaviour unchanged: still bound to `search.mode`, still re-runs via the existing
  `onChange(of: search.mode)` in `LibrarySearchable`.
- Purely presentational — no model or query changes. Build succeeds.
