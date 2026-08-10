# 372 — The Exports Move Into the Overflow

Follow-up to [371](371-archive-in-the-selection-bar.md). Adding Archive made the
collection's selection bar the widest in the app — count, Clear, Delete, Remove,
Archive, contact sheet, web page, ring, `…`. The two exports move into the `…`
overflow, which is what that popover is for.

## Why those two and not the others

The bar carries the verbs a selection is FOR — delete it, take it out of here,
put it away. An export is a considered, occasional act that opens a config panel
anyway, so a dedicated glyph bought a click that the `…` already offers and cost
width on every selection, including the ones that will never export anything.

**The progress ring stays in the bar.** It is status rather than an action, and
cancelling a running export must not require reopening a menu to find the
Cancel.

Bar is now: count · Clear · Delete · Remove · Archive · ring · `…`.

## The nested-popover problem, and the anchor that avoids it

Both exports were `Button` + `SelectionBarIcon` + their own
`.popover(isPresented:)`. A menu row cannot simply keep that popover: **on macOS
a popover raised from inside another popover's content is torn down with its
parent, and the parent dismisses on the first click outside itself** — which is
any click on the panel.

So the rows follow the pattern `M` / `A` already use here. Each closes the
overflow and sets `exportPanel`, and a zero-size `exportPanelAnchor` sitting
where the bar does presents the panel via `.popover(item:)`. Second copy of an
existing idiom rather than a new one, down to handing the keyboard back to the
grid on dismiss.

`ContactSheetExportButton` / `CollectionSiteExportButton` became
`ContactSheetExportPanel` / `CollectionSiteExportPanel` — the panel bodies with
their triggers removed. Both had exactly one caller, so nothing else moved.

## The knobs had to move too, or they would have reset

A popover rebuilds its content on every presentation. The panels' `@State
config` survived before only because the *button* view outlived the popover it
raised; hosted on an anchor, the format, column count and toggles would have
snapped back to defaults every time a panel opened.

`CollectionView` now owns the three config values and passes bindings, so they
persist for as long as the collection is on screen — the behaviour the glyphs
had. This is the one thing in the change that would have been a silent
regression, and it is the reason the panels take `@Binding` rather than keeping
`@State`.

## Disabled states, preserved

`!isExporting` on both, and the web page additionally requires a non-empty
collection, exactly as the glyphs were gated. As `SelectionMenuRow(isEnabled:)`
now.

The File-menu commands (`File ▸ Export Contact Sheet…` / `Export Web Page…`) are
untouched and still export with default settings — a separate path, deliberately.

## Tests

None added. This is chrome with no seam: the export machinery
(`ContactSheetExport.map`, `CollectionSiteExport.plan`, `ExportController`) is
unchanged and already covered, and what moved is which control presents it.
Verified by hand: both panels open from the `…`, keep their knobs across
open/close, export, and disable while one is running.

## Files changed

- `CollectionView.swift` (bar extras, overflow rows, `ExportPanelKind`,
  `exportPanelAnchor`, the three config states)
- `ContactSheetExportControls.swift`, `CollectionSiteExportControls.swift`
  (button → panel)

## Migration notes

`ContactSheetExportButton` and `CollectionSiteExportButton` no longer exist. A
new host presents `…ExportPanel` and owns its config binding — see
`exportPanelAnchor` for the shape.
