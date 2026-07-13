# 091 — Spaces: frames + text elements (005-E3, part 2)

The app half of E3: freeform **frames** and **text** on a space board, on top of
the renderer's vector path (090). Element rows were already modelled + validated
in the core (086); this draws, creates, edits, and group-moves them.

## Summary

- **`ElementRendering`** (new): the bridge between Core's `ElementStyle`
  (hex-string colours in the `space_item.style` JSON) and the renderer's
  `FrameStyle` / `TextStyle` / `RGBAColor`. Hex ↔ `RGBAColor` parsing, default
  styles for new elements, and `Color` ↔ hex interop for the inspector's pickers.
- **`SpaceContent`** now draws element rows: every row (asset + element) becomes a
  tile; `content(for:)` maps element rows to `.frame` / `.text`. **Frames are
  group containers** (005 open-Q1, chosen): `groupMembers(forDraggedTileID:)`
  returns every tile whose centre falls inside a dragged frame's world rect, so
  the renderer carries them along. (Prior behaviour skipped element rows entirely.)
- **`SpaceModel`**: `addFrame` / `addText` (a rubber-banded world rect →
  `addElement`; frames seed behind the content at min-z, text on top at max-z, and
  the new element is selected), `style(forItemID:)`, `updateStyle`, and
  `selectedElement` (the selected row iff it's an element — drives the inspector).
  Group-move needs no new model code: the host fires `onMoveTile` once per carried
  tile, each persisting through the existing placement write.
- **`SpaceView`**: a Select / Frame / Text tool picker (a create tool
  rubber-bands, then snaps back to Select), `onCreateElement` wiring, and an
  element inspector popover. Double-clicking an element opens it too. The empty
  space now shows the canvas (with a non-blocking hint) so the first frame / text
  can be drawn onto it.
- **`ElementInspector`** (new): the popover editor (decision — chosen over an
  inline canvas overlay, avoiding overlay↔canvas coordinate mapping under
  pan/zoom). Text: string + size + colour. Frame: label + border colour/width +
  optional fill. Edits a local copy, commits on Done (one write + reload, so
  typing doesn't rebuild the canvas host).

## Files changed

- Added: `ElementRendering.swift`, `ElementInspector.swift`
- Edited: `SpaceContent.swift` (element rows + frame grouping),
  `SpaceModel.swift` (element CRUD + `selectedElement`), `SpaceView.swift`
  (tool picker + create + inspector + empty overlay)
- Tests: `AtelierRefsTests/SpaceLayoutTests.swift` — `drawsElementRows`
  (element → `.text` mapping, replacing the old skip test) +
  `frameGroupsContainedTiles` (containment membership)

## Migration notes

None — the v4 schema (086) already carries element rows; this is UI + rendering.
Element rows created before E3 (there were none) would now draw.

## Tests

App unit target green (46 tests, 0 failures). New coverage: an element row maps to
`.text` content with its string, an asset row stays `.image`, and a frame's
group membership is exactly the contained tile. Renderer-side behaviour is
covered by 090's `EngineVectorTests`. SwiftUI/CA views are compile-only per repo
convention; the inspector popover + rubber-band create want a manual pass.

## Known issue (pre-existing, not E3)

`AtelierRefsUITests` (`testLaunchAndSwitchTabs`, `testLibraryShowsFolderChrome`)
still assert the old `Canvas / Library / Sweeps` TabView that the navigation
redesign removed — stale since that change, tracked separately.
