# 050 — Canvas drag-to-place with placement persistence

## Summary

The Canvas tab was pan/zoom + select only — tile positions came entirely from
`CanvasContent`'s justified-rows layout and couldn't be changed. This adds
**drag-to-place**: press a tile and drag it to a new position, and the placement
**persists** (survives folder switch, import, and app relaunch) via the existing
`AppServices.setCanvasPlacement` seam:

- Press-and-drag a tile to move it; a move begins only after ~3 pt of movement,
  so a plain click still selects (double-click still activates, right-click still
  menus). Pressing empty space does nothing — panning stays on scroll.
- The move is **optimistic + in-memory first**: on mouse-up the engine reports
  the tile's final world origin, the provider is updated in memory synchronously
  (so the tile stays exactly where dropped — no snap-back), and only then does
  the renderer re-sync. The durable DB write hops OFF the main actor.
- Dragging does **not** reset the viewport: the provider is mutated in place and
  the `CanvasView` is never rebuilt on a move, so pan/zoom are untouched.
- `w/h/z` are re-persisted alongside the new `x/y`, "pinning" the tile at its
  dropped size. `CanvasContent.layout` already honours `canvas_x/y/w/h`, so a
  later provider rebuild (folder switch / relaunch) reproduces the drop exactly.

## What changed

### Renderer (`CanvasRenderer`)

- **`CanvasEngine` — transient live-drag offset (no provider mutation).**
  - New private `dragTileID: Int?` + `dragWorldOffset: CGSize`, and a
    `displayWorldFrame(for:)` helper that offsets ONLY the dragged tile's world
    frame. `sync()` and `tile(atScreenPoint:)` both go through it, so the dragged
    tile, its badge, and the selection highlight follow the cursor live while
    everything else is unchanged.
  - Public API (all additive): `beginDrag(tileID:)`, `updateDrag(byScreenDelta:)`
    (converts a **cumulative** screen delta to a world delta via
    `world = screen / transform.scale` — sign is direct: uniform positive scale,
    no y-flip in the transform — then re-syncs), and
    `endDrag() -> (tileID: Int, worldOrigin: CGPoint)?` (returns stored origin +
    offset, clears state, and does **not** sync — the host mutates the provider
    then calls `sync()`). Plus `currentScreenFrame(forTileID:)` introspection for
    the tests.
- **`CanvasHostView` — click-vs-drag on the mouse events.**
  - `mouseDown` records the press point + hit tile as a drag candidate (keeps
    select-on-down + double-click-activate). `mouseDragged` begins the drag once
    the cumulative move passes the threshold, then feeds `updateDrag`. `mouseUp`
    finalizes: `endDrag()` → `onMoveTile?` → `engine.sync()` (that ordering is
    what avoids the viewport reset / snap-back). Empty-space presses never drag.
  - New `onMoveTile: ((Int, CGPoint) -> Void)?` closure and a pure static
    `exceedsDragThreshold(_:threshold:)` helper (unit-tested).
- **`CanvasView`** threads `onMoveTile` through `init` / `apply(to:)` with a
  default, so the spike, benchmark, and existing app call sites keep compiling.

### App (`AtelierRefs`)

- **`CanvasContent`** — `tiles` is now `private(set) var`, with
  `setPlacement(tileID:x:y:)` mutating the tile in place while preserving its
  `w/h/z`. This is the in-memory update the renderer reads next `sync()`.
- **`IngestionModel.moveCanvasTile(tileID:to:)`** — resolves the tile's asset id
  and current `w/h/z` from the cached `CanvasContent`, calls
  `content.setPlacement(...)` synchronously (tile stays put), then fires
  `services.setCanvasPlacement(collectionID:assetID:x:y:w:h:z:)` in a `Task` off
  the main actor. Failures surface via the existing `lastError`. It does **not**
  bump `contentsVersion`, so the `CanvasView` is not rebuilt (pan/zoom survive).
  Needed `import CanvasRenderer` for `Tile`'s `w/h/z`.
- **`CanvasScreen`** wires `CanvasView`'s `onMoveTile` to `moveCanvasTile`.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — drag state +
  `beginDrag` / `updateDrag` / `endDrag` / `displayWorldFrame` /
  `currentScreenFrame`; `sync()` + `tile(atScreenPoint:)` use the display frame.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — click-vs-drag
  (`mouseDown`/`mouseDragged`/`mouseUp`), `onMoveTile`, `exceedsDragThreshold`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — thread
  `onMoveTile`.
- `CanvasRenderer/Tests/CanvasRendererTests/DragTests.swift` (new) — 8 tests.
- `AtelierRefs/AtelierRefs/CanvasContent.swift` — mutable `tiles` + `setPlacement`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `moveCanvasTile` + import.
- `AtelierRefs/AtelierRefs/CanvasScreen.swift` — wire `onMoveTile`.
- `AtelierRefs/AtelierRefsTests/CanvasPlacementTests.swift` (new) — 5 tests.

No `AtelierCore` change — the `setCanvasPlacement` seam was already in place.

## Verification

- `cd CanvasRenderer && swift test` — **87 tests in 17 suites passed** (incl. the
  8 new `DragTests`). Run 4+ consecutive times green after the changes. One
  pre-existing, product-unrelated flake was observed once in an early run:
  `SpikeDataTests` "the same seed yields pixel-identical images (T12)" — the
  known ImageIO decode/encode-jitter harness flake documented in changelog 048,
  not touched by this work; it passes in isolation and passed on every
  subsequent full-suite run.
- `cd AtelierRefs && xcodebuild … test -only-testing:AtelierRefsTests` —
  **TEST SUCCEEDED**, 27 tests passed (5 new `CanvasPlacementTests` + the
  existing 22).
- `cd AtelierRefs && xcodebuild … build` — **BUILD SUCCEEDED**.
- The AppKit mouse drag itself (`mouseDown`/`mouseDragged`/`mouseUp`) is
  **compile-verified only** — no runtime GUI test here; the geometry it drives is
  fully covered by `DragTests` through the engine's public API + introspection
  (dragged tile moves by exactly the screen delta, others don't, `endDrag`
  origin = stored + screenDelta/scale with the sign pinned, hit-test tracks the
  live position, highlight follows). A manual click-through remains pending,
  consistent with the runtime-UI-verification note in 046/047.

## Migration notes

None — no schema change. The `canvas_x/y/w/h/z` columns already exist and
`CanvasContent.layout` already honours them, so a persisted placement reloads on
relaunch. Additive behaviour and additive public renderer API (new closure +
engine methods are defaulted / additive), so the spike, benchmark, and existing
app call sites are unaffected. New files (`DragTests.swift`,
`CanvasPlacementTests.swift`) are picked up automatically — no `.xcodeproj` edit.
`IngestionModel` gains `import CanvasRenderer` (already a dependency via
`CanvasContent`). Existing select / double-click-activate / right-click-menu /
⌫-delete and scroll-pan / pinch-zoom behaviour are all preserved.
