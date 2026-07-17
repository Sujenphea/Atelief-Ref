# 153 — Search results: selection + batch triage (034 P2)

## Summary

The search-results grid was open-only: you could find items but not act on them (a
"triage dead-end"). It now supports **multi-select** and a **batch context menu**,
so found items can be added to a collection or deleted without leaving search.

Selection reuses the pure `GridSelection` reducer (asset ids as the universe —
search hits have no folder membership), so click / ⌘-click / ⇧-range / ⌘A / Esc /
Return behave exactly like the main grid, plus a hover/selection circle (keyed off
the cell container so it doesn't flicker, per changelog 149). Verbs are scoped to
what a membership-less hit supports: **Add to Collection** (copy), **Delete**, and
**Reveal in Finder** for a lone byte-backed item. Delete flows through the shared
confirmation + the unified Undo toast (150); a completed delete re-runs the query
so the removed card leaves the grid.

**Deferred (documented):** arrow-cursor navigation and marquee rubber-band are NOT
ported — the results use an adaptive `LazyVGrid` with no analytic frames to drive
that index/offset math. Click/keyboard triage covers the parity gap the backlog
called out; a full masonry port would be its own change.

## Files changed

### AtelierRefs
- `LibrarySearch.swift` — `LibrarySearchModel` gains `resultsVersion` (prune signal)
  and `rerun()`; `LibrarySearchResults` rewritten with a `GridSelection`, hover
  circle, selection visuals, click/⌘/⇧ routing, `⌘A`/`Esc`/`Return`/`Delete` keys,
  and a Finder-scope batch context menu (Add to Collection / Reveal / Delete).

## Migration notes

None. A plain click still opens the detail overlay (idle mode); selection only
engages once you ⌘/⇧-click or use the hover circle.

## Verify

- Search → results appear → ⌘-click or hover-circle two hits → right-click →
  **Add to Collection ▸** a folder → both are added (they still match, stay listed).
- Select some hits → **Delete** → confirm → a "Deleted N — Undo" toast appears and
  the cards leave the results grid → **Undo** restores them.
- ⌘A selects all results; Esc clears; a plain click still opens the item.
