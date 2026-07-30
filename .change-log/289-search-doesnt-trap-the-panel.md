# 289 — Search doesn't trap the panel

## Summary

Searching from an open space left no way back to the board. Clicking the space in
the sidebar did nothing at all, and the results grid stayed up over the panel —
the search field's `×` was the only exit. Two independent defects stacked:

**1. The Spaces outline swallowed a click on the already-open row.**
`SpacesOutlineView.rowClicked()` was an empty `@objc` stub, so nav only ever came
from `outlineViewSelectionDidChange` — which AppKit fires *only when the outline's
selection actually changes*. The open space is already the selected row, so
clicking it produced no delegate callback and no `nav` call. Collections had
already hit and fixed exactly this (`CollectionsOutlineView.rowClicked`, with the
"a click is authoritative for nav" comment); the Spaces list never got the same
treatment.

**2. `LibrarySearchable` never dropped its query on navigation.**
Its `LibrarySearchModel` is a `@StateObject`, and `AppShellView.rootContent`
routes destinations through one `switch` — so `.space(A)` → `.space(B)` and
`.collection(A)` → `.collection(B)` stay in the same arm, keep the same view
identity, and keep the same search model. An active query therefore survived a
sidebar click and kept covering the new pane's content.

Same root shape as the existing `.id(id)` on `spaceDestination`: the switch
preserves identity across a selection change, and state that should be
per-destination has to be reset explicitly.

Fixed by adding `NavModel.navigationPulse`, bumped by `selectSidebar` on every
navigation *intent* — including re-selecting the row already selected, which
changes no observable state and so can't be detected from `sidebarSelection`.
`LibrarySearchable` resets and re-`configure`s its search model on a bump.

### Also fixed by the same change

The re-`configure` re-points the search model at the destination's
`collectionID`. Nothing else refreshed it: `configure` ran only from
`.task(id: model.isReady)`, so after `.collection(A)` → `.collection(B)` the
model still held A. A "This collection" scoped search on B was querying A.

## Files changed

- `AtelierRefs/AtelierRefs/SpacesOutlineView.swift` — `rowClicked()` resolves the
  clicked row and calls `nav.openSpace`, so a click on the open space re-asserts
  nav. Unconditional (unlike the Collections guard) so the already-selected case
  still pulses.
- `AtelierRefs/AtelierRefs/NavModel.swift` — new `@Published private(set) var
  navigationPulse`, bumped in `selectSidebar`.
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `LibrarySearchable` takes `nav`
  and resets + re-configures its search model on a pulse.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — the five `LibrarySearchable`
  call sites pass `nav`.

## Migration notes

`LibrarySearchable` gained a required `nav: NavModel` parameter. It is observed
for `navigationPulse` only.

Behaviour change worth knowing: a sidebar click now always clears an active
search. Previously a query survived (invisibly scoped to the pane you left);
now navigating means "show me this destination".
