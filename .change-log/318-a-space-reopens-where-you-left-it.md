# 318 — A space reopens where you left it (018 · Cluster C)

Every board used to open framed-to-fit, every time. Pan across a big moodboard,
zoom into one corner, leave, come back — and you were back at the top-left of the
whole thing, hunting for where you were. A space now remembers its camera, and
the fit becomes what it always should have been: the answer when there is no
camera worth restoring.

## Summary

- **`SpaceCamera`** (new, `AtelierCore`) — `{x, y, zoom}`, `Codable`, encoded to
  the new `space.camera` TEXT column. Shaped exactly like `ElementStyle` and its
  `space_item.style` column: opaque TEXT, every field optional, `jsonString()` /
  `init?(jsonString:)`. That is what lets the shape grow later — a saved "home"
  view, a per-window camera — without a second migration.
- **Migration v17** — one additive column, `ALTER TABLE space ADD COLUMN camera
  TEXT NULL`. See *Migration notes*.
- **`AppServices.setSpaceCamera(spaceID:camera:)`** — the write, through the
  funnel like everything else.
- **`CanvasCamera` + `CanvasTransform.camera(viewportSize:)` /
  `settingCamera(_:viewportSize:)`** (`CanvasRenderer`) — the window-independent
  form of a camera and the conversion both ways.
- **`CanvasEngine.restoreCamera(_:)`** — the restore-or-fit rule, riding the same
  one-shot seam `framesContentWhenReady` already armed.
- **`SpaceModel.cameraChanged(_:)` / `flushCameraPersist()`** — a 0.4s debounce
  and the explicit flush.

## What is stored is a centre, not a translation

`CanvasTransform` carries a `translation`: the screen position of world origin.
Persisting that would have been the obvious move and it would have been wrong,
because a screen offset only means anything against the window size that produced
it. Reopen on a laptop a board you left on a 6K display and the content slides by
half the difference.

So the stored camera is the **world point at the centre of the viewport**, plus
the zoom. That survives a window resize by construction, and the two conversions
are pure functions on `CanvasTransform`, unit-tested as a round-trip.

## One rule, one fallback

There are three ways to have no camera worth restoring, and they all get the same
answer — `frameToContent(padding:)`, which is already the correct first-open
behaviour:

1. **NULL** — the board has never been opened by a build that saves cameras.
2. **Undecodable** — a corrupt blob, or one missing half its fields. `resolved`
   collapses both into `nil` rather than defaulting: a style has a sensible
   default for every field, but "where were you looking" does not, and inventing
   one opens the board somewhere the user has never been.
3. **The restored viewport intersects no content.** A camera parked in deep space
   — content deleted since, or a window small enough to miss it — reopens the
   board as an empty grey void, which reads as data loss.

The rejected alternative for (3) was "clamp until some fraction of the board is
visible". A threshold has to invent a number, and every number it could invent
silently moves a camera the user deliberately parked: panning until your work is
a sliver at the edge is a place you are allowed to be. `showsContent(under:)` is
a plain rect intersection, measured against the same `contentWorldBounds` the fit
itself uses — hoisted out of `frameToContent` precisely so the fallback and the
thing it falls back to can never disagree about where the content is.

## The flush is the whole feature

A 0.4s debounce is what stops a pan writing sixty rows a second. It is also,
unchecked, what eats the **last** gesture of every session: you pan, you close
the board, and the timer dies with the view holding the only copy of where you
were — so the one camera that never persists is the one you actually left.

`flushCameraPersist()` is called from `SpaceView.onDisappear`, whose identity is
keyed to the space id, so it fires on a space-switch as well as on navigating
away. It writes only what is pending, so calling it on every teardown costs
nothing. (An outright ⌘Q does not run `onDisappear`; the residual exposure is the
0.4s since the last gesture.)

The restore itself comes back through the same notification a pan does — the
engine has one transform seam, deliberately — so the model keeps a baseline of
what is already on disk and drops a change back to it. Without that, opening a
board would write the camera it just read, on every open.

That baseline is refreshed by a reload only until the canvas has reported a
camera of its own. `init`'s load and an explicit first `load()` race, and the
loser returns early without seeding; the winner can therefore land *after* the
first write and re-adopt a row that write has not reached yet. Adopting it would
make the next identical report look like a change. A test caught this.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/SpaceCamera.swift` — new.
- `AtelierCore/Sources/AtelierCore/Domain/Space.swift` — the `camera` column.
- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` — v17.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` —
  `setSpaceCamera`; does not bump `updatedAt` (looking at a board is not editing
  it) and is idempotent rather than `.notFound` (the flush on close can land
  after the board was deleted).
- `CanvasRenderer/Sources/CanvasRenderer/CanvasTransform.swift` — `CanvasCamera`
  and the two conversions.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` —
  `contentWorldBounds` hoisted out of `frameToContent`, `camera`,
  `showsContent(under:)`, `restoreCamera(_:)`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — the
  `restoreCamera` property consumed by the existing framing one-shot, and
  `onCameraChanged`, which carries the value so the app never reads it back off a
  weakly-held host.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — pass-through.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `openingCamera`, the debounce, the
  flush, the baseline.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — wires all three, plus
  `.onDisappear`.
- Tests (new, 40): `AtelierCoreTests/SpaceCameraTests.swift` (11),
  a `Migration v17` suite in `AtelierCoreTests/MigrationTests.swift` (4, plus the
  pinned identifier list and the `space` column-shape test),
  `CanvasRendererTests/CameraRestoreTests.swift` (16),
  `AtelierRefsTests/SpaceCameraPersistTests.swift` (9).

## Test results

- `swift test --package-path AtelierCore` — 599 tests in 89 suites, passed.
- `swift test --package-path CanvasRenderer` — 408 tests in 49 suites, passed.
- `AtelierRefs` scheme (`xcodebuild … test`) — **TEST SUCCEEDED**, 991 test cases.

## Migration notes

**v17 — additive, NULL-safe, no back-fill.**

`ALTER TABLE space ADD COLUMN camera TEXT NULL;` — one column, nothing rebuilt,
nothing rewritten. `"v17"` is appended to `Migrator.registeredIdentifiers`, to
the migrator body, and to the pinned `committedIdentifiers` list in
`MigrationTests`; no shipped migration body was touched.

Every existing `space` row keeps `camera = NULL`. There is deliberately **no
back-fill**: there is no historical camera to recover, and NULL already means
what the first open has always done — fit the board to the window. An upgraded
library is therefore indistinguishable from the current build until the user pans
a board, at which point that board starts remembering.

Downgrade is safe in the only way that matters: an older build never reads the
column, and a newer build reading a blob written by an older or newer one decodes
forgivingly — unknown keys are ignored, missing ones resolve to "no usable
camera", and both land on the same fit. The column cannot make a board
unopenable.

`AppServices.schemaVersion` (recorded in backup and archive manifests, 008 ·
H5/H6) now reports `"v17"`, so a backup written by this build is refused by
older readers as being from a future schema — which is the existing and correct
behaviour.
