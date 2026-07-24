# 220 — Collection cards adopt the grid selection reducer (cmd/shift-select)

Home collection/space cards gained cmd-click, shift-range, and ⌘A selection by
adopting the shared `GridSelection` reducer, replacing the marquee-only
`Set<UUID>`. Cards now select like the collection grid and search results. Work
item B of `.docs/048-drag-unification-plan.md`.

## CollectionsGalleryView.swift
- `selectedCardIDs: Set<UUID>` → `@State selection = GridSelection()` (plain
  `@State`; a store is only needed for the AppKit host's Combine subscription).
- Plain click navigates when idle, toggles when selecting (Finder parity) via
  `plainCardClick` → `gridClickAction` → open-detail effect mapped to
  `nav.openCollection`/`openSpace`. Unsorted always navigates (never selectable).
- New `CardSelectionGestures` modifier: ⌘-click (toggle) + ⇧-click (range) via
  `.simultaneousGesture(TapGesture().modifiers(...))` (a Button won't fire on a
  modified click). ⌘A via `.onKeyPress`. Marquee/Clear/batch-delete/ring read
  `selection.ids`; marquee applies `.marquee(hits:base:)`.
- `orderIDs` (roots minus Unsorted, then spaces) feeds ⇧-range and ⌘A.

## Notes
- Intended change: clicking a selected card while selecting now toggles it
  (Finder parity) rather than navigating.
- Arrow-key cursor not wired (adaptive LazyVGrid has no fixed column count).
- Reparent DnD and Unsorted-not-selectable unchanged.

## Verification
- `xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` — SUCCEEDED.
