# 018 — Canvas Direct Manipulation: Snapping, Resize Handles, Camera, Clipboard

> Sourced from a reconnaissance pass over `ref/Nook` (2026-07-27) — a macOS
> browser whose **Easel** feature (`ref/Nook/Components/Easel/`, ~4.3k lines) is a
> near-complete infinite canvas and a direct analogue to Spaces. This doc captures
> what is worth taking, what is deliberately *not*, and the legal caveat on one
> asset set.
>
> **Framing decision: do not port the engine.** Easel carries its own
> `CameraState`, its own `CATiledLayer` renderer (`EaselTileLayer.swift`), and its
> own snapshot/LOD/decode pipeline — a parallel stack to `CanvasRenderer`
> (`CanvasTransform`, `CanvasEngine`, `ThumbnailCache`, `LODPolicy`,
> `CanvasSelection`, plus marquee + edge auto-pan in `CanvasHostView`). Ours has
> ~2.5k lines of tests behind it. The value in Easel is the **interaction layer
> layered on top**, which Spaces largely lacks. That layer is what this doc scopes.

## Status (re-verified against the tree 2026-08-11)

**All seven phases are closed** — six built, and C7 answered by measurement. Everything below describing "no snapping of
any kind", "no resize on canvas at all", "no cursor feedback", "no camera
persistence" and "schema is at v15" is **historical** — the reconnaissance
snapshot of 2026-07-27, not the code as it stands.

| Phase | State | Where |
|---|---|---|
| C1 snapping | **shipped** | `CanvasRenderer/CanvasSnapping.swift` + `CanvasSnappingTests` |
| C2 resize handles | **shipped** | `CanvasRenderer/ResizeHandles.swift` + `ResizeHandleTests`, `EngineResizeTests` |
| C3 camera persistence | **shipped** | schema **v17** (`Migrator.swift:155`), `SpaceCamera.swift`, `SpaceCameraTests`, `SpaceCameraPersistTests`, `CameraRestoreTests` |
| C4 paste + duplicate | **shipped** | `SpaceView.pasteOntoBoard` (`:948`), `space.duplicateTiles` (`:389`, ⌥-drag), `PasteSeamTests`, `SpaceDuplicateTests` |
| C5 format bubble | **shipped** | `SpaceFormatChrome.swift` + `SpaceFormatChromeTests`; see also `.change-log/352` (floating bars unified into one container) |
| C6 cursor state machine | **shipped** | `CanvasHostView.swift:420` tracks the hovered **handle** rather than the cursor (`NSCursor.frameResize` vends a fresh instance per call), original art — no Arc assets taken |
| C7 perf harness + pinch smoothing | **shipped / closed** | Harness: `CanvasPinchBakeoff.swift` (on-screen, `-canvas-pinch-bakeoff`) + `CanvasBenchmark` pinch cases. `magnify(with:)` is now phase-bracketed with vsync-coalesced commits and a frozen LOD tier (`CanvasZoomGesture` + `CanvasEngine.beginZoomGesture`). **The GPU-scale smoothing was measured and refused** — see [087](../087-canvas-pinch-results.md) |

**Nothing is left open.** C7 closed the way this doc asked it to: the harness ran
first and said the smoothing was not needed. A pan of the same board hitches
identically to a pinch, so the cost was never pinch-specific — it scales with the
visible tile count, which is now [087](../087-canvas-pinch-results.md) §7's follow-up
rather than this doc's. Schema is at **v19**, not v15.

The licensing question (below) resolved in practice: Clusters A and B were
implemented from the described behaviour into our own files with our own tests,
and the cursor art was not taken.

## Current state at the time of writing (historical — see Status above)

Grepped across `AtelierRefs/AtelierRefs`, `CanvasRenderer/Sources`, and
`AtelierCore/Sources`:

- **No snapping of any kind.** `CanvasArrange.swift` provides align/distribute as
  *discrete button operations* on a settled selection (`Operation` enum, 8 cases,
  pure `apply(_:to:)` on `[CGRect]`). There is no live snap during a drag, no
  proximity threshold, no guide rendering. Zero hits for `snap`/`guide` in any
  canvas path.
- **No resize on canvas at all.** No `Handle` type, no handle hit-testing, no
  resize drag mode. `CanvasHostView` tracks element *create* (rubber-band, `:72`),
  object *drag* (`:79`), and *marquee* (`:94`) — resize is simply absent. Element
  geometry can only change via create, drag, or [053]'s text auto-resize.
- **No cursor feedback.** Zero `NSCursor` references in the app or the renderer.
  The pointer is the system arrow over every canvas state.
- **No camera persistence.** Zero hits for `zoom`/`camera`/`viewport` in
  `AtelierCore/Sources`; the `space` table (`Migrator.swift:375–383`) is
  `id / name / cover_asset_id / created_at / updated_at` (+ `sort_index` from
  v10). Every space reopens at the default transform.
  `CanvasEngine.frameToContent(padding:)` (`:275`) exists as the fit-to-content
  fallback, so the *reset* half is already built.
- **Clipboard is copy-only.** `CanvasHostView.copy(_:)` (`:581`) is wired as a
  responder action with `NSUserInterfaceValidations` (`:607`). There is no paste,
  no ⌘D duplicate. `keyDown` (`:568`) handles only Delete/Forward-Delete.
- **Pinch is unsmoothed.** `magnify` (`:233–236`) is a direct
  `engine.zoom(by:aroundScreenPoint:)` per event — no gesture-scoped GPU scale, no
  deferred re-raster.
- **Text formatting is popover-only.** `ElementInspector.swift:5–9` documents
  choosing the popover *specifically to avoid* overlay↔canvas coordinate mapping
  under pan/zoom. **That constraint is now stale**: [053]'s 2B inline editing built
  the SwiftUI-boundary seam, so screen-space floating chrome is viable.
- `ElementStyle` (`SpaceItem.swift:50–94`) already carries `fontFamily` /
  `fontWeight` / `textAlign` / `resizeMode` from the 053–055 phase — the model side
  of a format bubble is done.
- Schema is at **v15** (`Migrator.swift:39`, append-only, pinned by a test).

## Cluster A — Snapping + alignment guides (highest value per effort)

Three pure-geometry functions in `InfiniteCanvasView.swift:988–1094`:

1. **`computeSnap(for bbox:)`** — snaps the dragged selection's bounding box
   edges/centers (`minX/midX/maxX` × `minY/midY/maxY`) to the same six anchors on
   every *non-selected* object within `6 / zoom` world units. Returns `(dx, dy,
   guides)` where a guide is `(isVertical: Bool, coordinate: CGFloat)`. Nearest
   wins per axis, independently.
2. **`snapResizePoint(_:handle:)`** — same idea for the dragged resize point,
   restricted to the axes the handle actually moves (`.top`/`.bottom` don't snap X).
3. **`snapAspectFrame(_:handle:)`** — the subtle one: aspect-locked resize can't
   snap an edge by translating it, so it solves for the *uniform scale about the
   fixed anchor* that lands a moving edge on a target, then rejects the result if
   it would breach min-size.

**Why this ports cleanly:** no AppKit dependency, no camera dependency beyond a
scalar zoom for the threshold, no mutation — pure `CGRect` in, adjustment out.
Lands as `CanvasSnap.swift` beside `CanvasArrange.swift`, unit-tested in the
existing target the same way `CanvasArrange` is.

Ripple: guide *rendering* is new — a screen-space overlay line pair. `CanvasHostView`
already owns two comparable transient layers (`makeMarqueeLayer` `:485`,
`makeCreatePreviewLayer` `:430`); a third follows the same pattern.

Design question to settle: whether snapping also targets **space-level guides**
(a grid, or the union bbox of the selection) rather than only sibling objects.
Easel does objects-only. Recommend matching that for v1.

## Cluster B — Resize handles

`InfiniteCanvasView.swift:469–555` + `:947–986`.

1. **`handleAt(_:frameWorld:)`** (`:490`) — hit-tests 8 handles in *screen* space
   (so the target stays a constant size at every zoom): four corner squares win
   first, then four edge bands drawn strictly *between* the corner zones, which is
   what keeps tiny frames from becoming un-hittable.
2. **`resizedFrame(_:handle:to:keepRatio:aspect:)`** (`:513`) — the branch-heavy
   core: corners move two edges, sides move one; `keepRatio` anchors corners at the
   opposite corner via `aspectRect` (`:957`), and anchors *edges* about the
   perpendicular center. Min-size clamping is threaded through every branch. This
   is the function most worth copying rather than rederiving.
3. **`cornerHandleRects(for:)`** (`:970`) — draw geometry, visual only; hit-testing
   deliberately does not read it.

Needs a `dragMode` state machine in `CanvasHostView` — it currently has flat
create/drag/marquee tracking, and resize adds a fourth mode with a captured
start-frame. Sequence **after** Cluster A so `snapResizePoint`/`snapAspectFrame`
land into a resize path that already exists, rather than being written blind.

Interaction with [053]: an `.auto` `resizeMode` text element should either ignore
the height handle or drop to `.fixed` on manual resize. Recommend the latter
(matches Figma) — settle before building.

## Cluster C — Camera persistence

`InfiniteCanvasView.swift:1893–1915`. Two functions: a 0.4s-debounced write-through
that coalesces a whole gesture into one persist, and `flushCameraPersist()` invoked
on close/space-switch so the last gesture is never lost.

Ours needs the same debounce plus a **schema change** — the first in this doc.
Recommend `space.camera TEXT NULL` holding a `{x, y, zoom}` JSON blob, mirroring
the `space_item.style` precedent (`Migrator.swift:400`): opaque TEXT, `Codable`,
all-optional, so the shape can grow (e.g. a saved "home" view) without a second
migration. A NULL/undecodable value falls back to
`CanvasEngine.frameToContent(padding:)`, which is already the correct first-open
behaviour and stays correct for restored-but-stale cameras.

Migration slot: **v16** (append to `registeredIdentifiers` *and* the pinning test).

## Cluster D — Clipboard: paste + duplicate

`InfiniteCanvasView.swift:1249–1292`. `pasteObjects` (`:1260`) handles the
offset-and-reselect behaviour (pasted copies land offset from the source and become
the new selection); `duplicateSelectionInPlace` (`:1278`) is the ⌘D variant.

We have the responder-action scaffolding already (`copy(_:)` + validations at
`CanvasHostView.swift:581/607`) — paste and duplicate slot into the same seam.
The real work is ours, not Easel's: new `space_item` rows through `SpaceModel`'s
serialized write chain with correct undo registration (`registerReversible`,
`SpaceModel.swift:108`), and a decision on whether pasting an asset tile
duplicates the row only (recommended — blobs are immutable and shared) or the asset.

## Cluster E — Lower priority / read-don't-copy

1. **Floating format bubble** — `:700–815` + `EaselTextFormatPopovers.swift`.
   Screen-space bubble below the selected text box, flipping above near the
   viewport edge and *coordinating with the color palette* so the two never
   collide. `applyStyle` (`:765`) is the clean pattern worth stealing regardless:
   mutate → refit height → live-update the editor → commit undo → resync the
   popover model. Replaces or supplements `ElementInspector`; only worth it once
   A–D land, since it's polish on top of manipulation.
2. **Cursor state machine** — `cursorForCurrentState()` (`:437`) is a well-ordered
   priority chain (active drag mode → tool → handle hover → chrome hover →
   I-beam over an active editor → body grab → arrow). Take the *ordering*; see
   the provenance note below on the art.
3. **`EaselPerf.swift`** (198 lines) — opt-in instrumentation via
   `defaults write` or an env var, near-zero cost when off. Logs draw rate with a
   grid/objects/rest breakdown, LRU hit/miss/upgrade, decode volume split
   main-thread-fetch vs off-main-decode, and **vsync drops during a pan** — the
   signal that separates a main-thread hitch from raster starvation. That is
   exactly the question docs 035–039 kept asking of the grid. Adapt the shape to
   `CanvasRenderer`; don't copy internals (they instrument a different pipeline).
4. **Pinch smoothing** — `:2226–2330`. GPU-scales the tile layer and text overlay
   during the gesture, re-rasters only on release, and covers the reveal with a
   bitmap snapshot overlay. Two non-obvious traps are documented in the comments
   and are worth reading even if we build our own: `zPosition` alone will not
   composite above AppKit's subview-managed layers, and text must be laid out at a
   *reference* point size so the gesture-scaled render and the settle render are
   pixel-identical (otherwise line height visibly snaps on release).

## Explicitly out of scope

The rest of Nook is a browser and irrelevant here: the Tab / Extension / Cookie /
Profile / AI managers, `Components/DragDrop/` (2.2k lines — superseded by our own
unified drag, [048]), `EmojiPicker`, and the gradient `ColorPicker` stack unless
space theming becomes a goal. `Utils/HoverTrackingView.swift` (NSTrackingArea hover
to dodge SwiftUI `.onHover` recursive hit-testing) is a reasonable micro-grab *if*
that ever surfaces in a profile — not before.

## Provenance / licensing (blocking check)

`InfiniteCanvasView.swift:570` loads cursor art from nine `EaselCursor*.imageset`
entries, under a comment reading *"Uses Arc's own cursor art (bundled in the asset
catalog)."* Those PNGs appear to be **extracted from Arc browser**. Take the cursor
state machine; commission or draw our own art.

More broadly: confirm Nook's license permits reuse **before** lifting any code
verbatim. If it doesn't, Clusters A and B are small and well-understood enough to
reimplement from the described behaviour — the value in this doc is largely the
*specification* of what correct snapping and aspect-locked resize do, which is not
itself copyrightable.

## Schema / migration impact

- **Cluster C only**: `space.camera TEXT NULL`, one additive column, **v16**.
- Clusters A, B, D, E: **zero schema**. B and D write existing geometry/rows
  through existing `SpaceModel` write paths.

## Phased implementation

1. ~~**C1 (S) — snapping.**~~ **Shipped** as `CanvasSnapping.swift`.
2. ~~**C2 (M) — resize handles.**~~ **Shipped** as `ResizeHandles.swift`.
3. ~~**C3 (S) — camera persistence.**~~ **Shipped** — as **v17**, not the v16 this
   doc predicted (v16 went to the Unsorted-home reconcile).
4. ~~**C4 (S–M) — paste + duplicate.**~~ **Shipped.**
5. ~~**C5 (M) — format bubble.**~~ **Shipped** as `SpaceFormatChrome`.
6. ~~**C6 (S) — cursor state machine.**~~ **Shipped**, original art.
7. ~~**C7 (M) — perf harness + pinch smoothing.**~~ **Closed.** The harness was built
   and run first, as this entry insisted, and it refused the smoothing: at ~500 tiles
   the unsmoothed pinch already lands every frame on the vsync, and past ~1,200 tiles a
   plain PAN of the same board hitches identically, so the cost was never in the pinch.
   Both traps recorded here turned out not to apply to our tree — the engine's layers
   live on one layer-hosting surface with the editor as a real subview above it, and
   [060](../060-spaces-text-render-design.md)'s `TextRenderLayer` already shapes in
   world units, so gesture-scaled and settled renders differ only in resolution. The
   trap that DID apply is one this doc does not record: culling holds no layers for the
   world a scale-down would reveal. See [086](../086-canvas-pinch-smoothing-plan.md) /
   [087](../087-canvas-pinch-results.md).

## Test strategy

- **Snapping**: pure — threshold scales with zoom; nearest-wins per axis;
  self-exclusion (a selected object never snaps to itself or to a co-selected
  sibling); no-candidate returns zero adjustment and no guides; the aspect-locked
  scale solution preserves the ratio exactly and is rejected below min-size;
  degenerate frames (zero width/height).
- **Resize**: pure — corner vs edge zone precedence at every frame size including
  smaller-than-two-handles; each of the 8 handles moves exactly the intended
  edges; min-size clamping on every branch; `keepRatio` preserves aspect within
  epsilon for corners *and* edges; screen-space hit target stays constant across
  a zoom sweep.
- **Camera**: round-trip encode/decode; NULL and undecodable both fall back to
  `frameToContent`; debounce coalesces N gestures into one write; flush-on-close
  persists the final value (the regression that matters).
- **Paste/duplicate**: offset placement, new-rows-become-selection, undo restores
  the pre-paste row set exactly, z-order of pasted rows, paste-into-a-different-space.
- Bubble / cursors / pinch: compile-only + manual pass (repo convention).

## Effort: **A: S · B: M · C: S · D: S–M · E: M–L**

A/B/C/D are independent of each other except the stated sequencing preferences;
E depends on all of them.

## Risks & edge cases

- **Snap performance is O(objects × 9) per drag frame.** Easel scans every object
  unconditionally. Fine at Easel's scale; a dense space needs the candidate set
  culled to the visible viewport (or a coarse spatial bucket) before this ships.
  Measure before optimizing, but do measure.
- **Resize + `.auto` text resizeMode conflict** — unsettled (see Cluster B).
- **Resize adds a drag mode to a state machine that currently assumes three.**
  `resetGestureState()` (`CanvasHostView.swift:290`) must learn the new mode, and
  the marquee/create/drag disambiguation at `mouseDown` gains a handle-hover check
  that must run *before* hit-testing the object body.
- **Camera restore across a resized window** — a persisted transform from a
  larger window can restore content fully offscreen. Clamp to keep some content
  visible on restore, or re-fit when the restored viewport contains nothing.
- **Guide overlay must not fight the pinch/pan transform** — it is screen-space
  and transient; it should be torn down on gesture end, not transformed.
- **Licensing** (see Provenance) — blocks verbatim copying, not the work itself.

## Settled decisions (this pass, 2026-07-27)

- **Engine stays ours.** `CanvasRenderer` is not replaced or hybridized; only the
  interaction layer above it is sourced from Easel.
- **Nook's browser subsystems, `DragDrop/`, and the pickers are out of scope.**
- The [053] rationale for popover-only text editing ("avoid coordinate mapping") is
  **superseded** by 2B's transform seam — screen-space floating chrome is now on
  the table.

## Open questions — closed by C1–C6 shipping

1. ~~Snap targets: sibling objects only, or also a space grid?~~ Settled by
   `CanvasSnapping` as built; see `CanvasSnappingTests` for the pinned behaviour.
2. ~~Manual resize of an `.auto` text element?~~ Settled in `EngineResizeTests` /
   `TextAutoWidthTests`.
3. ~~Paste of an asset tile: clone the row or the asset?~~ **The row.** Blobs are
   immutable and shared; `PasteSeamTests` pins it.
4. ~~Format bubble replaces or supplements `ElementInspector`?~~ Settled by
   `SpaceFormatChrome` + `.change-log/352`, which folded the floating chrome into
   one container.
5. ~~Is Nook's license compatible with verbatim reuse?~~ **Moot** — A and B were
   reimplemented from the described behaviour into our own files and tests, and
   none of the Arc-derived cursor art was taken.

Nothing is open for C7 beyond "measure first".
