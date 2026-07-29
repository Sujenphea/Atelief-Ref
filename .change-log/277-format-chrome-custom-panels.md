# 277 — Format chrome: align segment, custom panels

## Summary

The Space board's floating text-format bubble is redesigned to the Figma-style
reference: the pill now reads `align · colour · Aa · size` (alignment promoted to
its own segment, hairline dividers dropped), and every segment opens a **custom
dark chrome panel** — same fill / hairline / shadow as the bubble — instead of a
system `NSPopover`.

- The align segment's icon mirrors the box's current alignment; it opens a pill of
  the three alignment icons with the current one highlighted (stays open across
  picks, so trying all three is three clicks).
- The "Aa" panel slims to the font family list only. Weight and the Auto/Fixed
  width toggle remain in the element inspector, which already carried them.
- Panels stack on the far side of the bubble from the box (box → bubble → panel),
  flip at viewport edges, and land on whole points — pure math in
  `SpaceTextChromeLayout.panelOrigin`, unit-tested.
- Custom panels don't take key-window focus, so inline text editing stays live
  while a panel is open (picking a size/colour/alignment no longer commits the
  edit). Clicking anywhere outside a panel dismisses it.
- The pill breathes: `panelPadding` (8) becomes `bubblePadding` (12) — the inset
  from the pill's edge to its first and last segment, wider than the 8pt gap
  BETWEEN segments so the ends read as an edge rather than one more gap — and
  `bubbleHeight` is derived (`segmentHeight + bubblePadding`, 34) so the icons get
  the same 6pt above and below. The align panel mirrors the bubble's shape, so it
  takes the wider inset too.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — bubble reorder, `alignWidth`,
  panel sizes + `panelOrigin` in the layout enum, custom panel presentation
  (tap-catcher + positioned panel), `SpaceTextFontPopover` → `SpaceTextFontPanel`
  (family only), `SpaceTextSizePopover`/`SpaceTextColorPopover` → `…Panel`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `showAlignPanel` state, popover →
  panel flag renames, `formatTarget` guard + focus comment updated.
- `AtelierRefs/AtelierRefs/FontFamilyCatalog.swift` — comment updated for the
  rename.
- `AtelierRefs/AtelierRefsTests/SpaceFormatChromeTests.swift` — bubble width
  formula updated (four segments, no dividers); new panel-origin tests (stacking
  side, flip at edges, on-screen clamp, whole points); new test that the pill's
  height leaves an even margin around its segments.

## Migration notes

- `SpaceTextChromeLayout.dividerWidth` and `fontPopoverWidth` are gone; panel
  frames come from `alignPanelSize` / `fontPanelSize` / `sizePanelSize` /
  `colorPanelSize`.
- `SpaceTextChromeLayout.panelPadding` is gone — use `bubblePadding`. The panels
  (font / size / colour) never used it; they inset with `Theme.Spacing` tokens.
- Weight and text-box width are now formatted ONLY through the element inspector.
