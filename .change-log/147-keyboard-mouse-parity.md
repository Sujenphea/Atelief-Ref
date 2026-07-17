# 147 — Keyboard/mouse parity batch

## Summary

Second batch from the UX review (see `.docs/034-ux-consistency-overview.md`),
closing theme 3 — "keyboard/mouse parity holes" in the highest-traffic surfaces.

- **Item Detail is zoomable without a trackpad.** Zoom was pinch-only, locking out
  mouse users. The zoom/pan state is lifted out of `ZoomableImage` into
  `ItemDetailView`, and the top bar gains **zoom-out / percentage / zoom-in**
  controls (image assets only). Keyboard: **⌘−** out, **⌘+** (and a Shift-free **⌘=**
  mirror) in, **⌘0** fit-to-view. The percentage button doubles as the reset. Pinch
  and double-click-to-fit still work and now share the same state, so a button press
  after a pinch continues from where the pinch left off. Zoom resets to fit on
  prev/next navigation.
- **Space board tools have shortcuts.** **V** Select, **F** Frame, **T** Text —
  design-tool muscle memory, no longer a trip to the segmented picker. Implemented as
  zero-size hidden shortcut buttons behind the tool picker; a focused text field
  still takes plain keys first, so typing into a text element / inspector isn't
  hijacked.

## Files changed

### AtelierRefs
- `ItemDetailView.swift` — lift `zoom`/`pan` into `ItemDetailView`; `zoomControls`
  in the top bar (⌘−/⌘+/⌘=/⌘0), `zoomBy`/`resetZoom`; `ZoomableImage` now takes
  `@Binding` zoom/pan + `maxZoom` instead of owning them; reset on navigation moved
  into `loadMedia` (so the `.id(asset.id)` remount is gone).
- `SpaceView.swift` — `toolShortcuts` (V/F/T) behind the tool picker; updated the
  picker help text.

## Migration notes

None. `ZoomableImage`'s API changed (now `init(image:zoom:pan:maxZoom:)` with
bindings) but it is `private` to `ItemDetailView.swift` — no external callers.

## Verify

- Item Detail on an image → top-bar +/−/% controls appear; ⌘+ / ⌘− / ⌘0 zoom and
  fit; the % updates; pinch still works and agrees with the buttons; prev/next
  resets to 100%. Non-image kinds (color/link/tweet/video) show no zoom controls.
- Space board → press V/F/T to switch tools; typing into a text element or the
  element inspector still inserts those letters (not a tool switch).
