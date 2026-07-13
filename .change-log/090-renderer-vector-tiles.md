# 090 — Renderer vector tiles (005-E3, part 1)

The renderer half of E3: the **vector tile path** that unblocks frames + text on
a space board. Decision T3 (hybrid): the image path — pooled / culled / LOD /
decode, benchmark-gated at ~8 ms/frame for thousands of thumbnails — is
**untouched**; frames and text are crisp vector siblings that bypass the decode
pipeline entirely (they number in the dozens per board). No app wiring yet — that
lands in 091; this ships the seam + engine + interaction so the app has a target.

## Summary

- **`TileContent`** (new seam): `TileProvider.content(for:)` returns
  `.image` / `.frame(FrameStyle)` / `.text(TextStyle)`, defaulting to `.image`
  so every existing provider is unchanged. New value types `FrameStyle`,
  `TextStyle`, and `RGBAColor` (a `Sendable` stand-in for the non-`Sendable`
  `CGColor`, converted at draw time). Colours + `strokeWidth` / `fontSize` are
  world units — the engine scales them by zoom so borders/glyphs keep a constant
  world size and stay crisp.
- **`CanvasEngine` rendering**: `sync()` branches per tile. A `.frame` draws on
  its own pooled layer (fill + world-thickness border + corner radius) with no
  cache key or decode. A `.text` (and a frame's optional label) rides a
  `CATextLayer` sibling keyed by tile id — created/dropped exactly like the
  video `▶` badges, **outside** the recycled `LayerPool`. `backingScale` (set by
  the host) keeps text Retina-crisp headlessly. New `textOverlayCount`
  introspection for tests.
- **Frame-as-group drag**: `TileProvider.groupMembers(forDraggedTileID:)` (default
  none) lets a provider declare which tiles a drag carries. `beginDrag` snapshots
  the group; the live offset applies to every carried tile; `currentDragOrigins()`
  (non-mutating) reports the final world origin of the frame **and** each carried
  tile so the host can persist them all. `endDrag()` is unchanged (single-tile
  path + existing tests stay green).
- **Tool mode + drag-to-create**: `CanvasHostView.tool` (`.select` / `.frame` /
  `.text`) + `onCreateElement(tool, worldRect)`. A create tool rubber-bands a
  dashed preview and reports a normalized WORLD rect on mouse-up; a click with the
  text tool drops a default-sized text box. `normalizedRect(from:to:)` is pure +
  unit-tested. Threaded through `CanvasView` as `tool:` + `onCreateElement:`.

## Files changed

- Added: `TileContent.swift`
- Edited: `TileProvider.swift` (`content` + `groupMembers` seams),
  `Host/CanvasEngine.swift` (vector render + group drag + `backingScale` +
  `textOverlayCount`), `Host/CanvasHostView.swift` (tool mode + rubber-band
  create + group-aware `mouseUp`), `Host/CanvasView.swift` (`CanvasTool`, new
  params)
- Added tests: `EngineVectorTests.swift` (frame/text render, overlay lifecycle,
  image-tile regression, frame-group drag, rubber-band normalization) +
  `CanvasBenchmark.testVectorElementsWithinBudget` (400 vector elements stay
  within the 120fps budget)

## Migration notes

None — additive protocol methods with defaults; no schema change. The image path
and all its invariants (exact sublayer counts, bounded pool, cache ceiling) are
unchanged, verified by the retained suites.

## Tests

Full `CanvasRenderer` suite green (96 tests). New E3 coverage asserts frames add
no sibling layer, text/label add exactly one `CATextLayer` each and release it on
cull, image tiles are byte-for-byte unaffected (sublayer counts), a frame drag
carries its group by the same delta, and the rubber-band rect normalizes
corner-order-independently. The vector benchmark is the perf regression guard.
