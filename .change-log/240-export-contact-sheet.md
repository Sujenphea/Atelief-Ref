# 240 — Contact-sheet export for collections (B4)

052 · Track B · **B4** — the last export deliverable. A collection has no spatial
layout to preserve (unlike a Space moodboard), so this GENERATES one: the app's
own round-robin masonry (`MasonryLayout` — the exact grid the collection screen
shows) packs the assets into cells, each an image plus an optional caption below
it, and the result flows through the identical B2/B3 pipeline.

## Design (locked with the user)

- **Masonry** layout (match the app grid), not uniform cells.
- **PDF + PNG only** — HTML export deferred to a later pass.
- **Captions on** by default: asset name → source title → author handle → origin
  host, whichever resolves first.

## What it reuses (no package code added)

`MoodboardExport.pages` / `render`, `MoodboardURLImageProvider`, `ExportConfig`,
`ExportController` (save panel / progress / cancel / partial-skip report) and the
completion toast are all reused as-is. B4 only adds the app-side generator + UI:
a collection contact sheet is, to the renderer, just another set of
`MoodboardElement`s.

## How it works

`ContactSheetExport.map(details:config:imageURL:)` (pure given the resolver):
1. Keep only rows that draw something (image / colour); a media-less link/tweet
   or unknown is skipped, counted, and — crucially — takes **no cell**, so the
   grid stays gap-free (052 · 7A, same skip-report as the moodboard).
2. Reserve caption height by inflating each cell's aspect before masonry packing,
   so a caption never overlaps the next row in its column.
3. Emit an image element per cell + (captions on, non-empty) a text element below.

The `MoodboardExport.Mapping` it returns feeds `ExportController.requestExport`
verbatim.

## Surfaces

- **Selection bar** → `ContactSheetExportButton`: a config popover (format · PDF
  layout / PNG scale · columns 3–6 · captions) exporting the selection, with the
  reused `ExportProgressRing` beside it for progress + Cancel.
- **File ▸ Export Contact Sheet…** (`ExportContactSheetCommand`, focused-value):
  exports selection-or-whole-collection with defaults; enabled only when a
  collection is focused. No shortcut (⇧⌘E is the Space moodboard export).

The shared progress ring / success toast wording was genericised from "moodboard"
to "Exporting…" / "Export complete" now that two export kinds share them.

## Files changed

- **New**: `ContactSheetExport.swift` (bridge), `ContactSheetExportControls.swift`
  (popover + File command), `AtelierRefsTests/ContactSheetExportTests.swift`.
- **Modified**: `CollectionView.swift` (env `ExportController`, selection-bar
  button + ring, File-menu focused action), `AtelierRefsApp.swift` (command),
  `MoodboardExportControls.swift` + `ContentView.swift` (generic export wording).

## Tests

`ContactSheetExportTests` (14, host-free): selection-or-collection rows; the
caption fallback chain; round-robin column packing; caption placement + height
reservation (next cell doesn't overlap); a skip takes no cell (gap-free); colour
swatches register no URL; URL registration; empty/all-skipped ⇒ empty mapping;
and an end-to-end generate→pages→render PDF smoke. Geometry is asserted with a
0.01pt tolerance (division-based masonry ⇒ float noise, not exact integers).

## Migration notes

- No schema, data, or package change. Contact-sheet export is additive UI +
  app-side mapping; nothing to re-run.
- HTML export remains unbuilt (deliberately deferred); no other B-track work
  outstanding.
