# 209 · Sidebar outline tree — styling & interaction polish (043 Phase C2)

## Summary

Post-verification polish on the `NSOutlineView` sidebar (from in-app feedback):
the tree now matches the sidebar's look and feels right.

## Changes (`CollectionsOutlineView.swift`, `SidebarView.swift`)

- **Chevron on the RIGHT** — native left triangle suppressed
  (`frameOfOutlineCell → .zero`); a right-aligned indicator glyph per parent row.
- **Whole-row toggle** — a click anywhere on a parent row expands/collapses it
  (the chevron is a plain indicator now); leaves just select. Selection/nav is
  unchanged.
- **Collapse-with-active-child fixed** — only re-reveal ancestors when the
  selection actually changes (`lastSyncedSelection`), so collapsing a folder whose
  child is open now sticks.
- **Selection** — flat Theme fill (`0x3A3A40`) + 1px `hairlineStrong` border, no
  focus ring / emphasized blue (custom `SidebarRowView`).
- **Cell** — no leading icon; 13pt Theme row font, `inkPrimary` text.
- **Alignment** — 14pt leading; `frameOfCell` strips NSOutlineView's fixed
  disclosure gap so the inset is exactly 14pt (+ per-level 16pt indent for
  children); `layout()` tracks the view width so rows fill; the view extends 8pt
  into the sidebar's right padding.
- **Expand glitch fixed** — `intercellSpacing = 0` (exact `rows * rowHeight`
  height) + synchronous height report on expand/collapse + immediate chevron flip;
  no animator.

## Status

Build + unit suites green. Verified in-app.
