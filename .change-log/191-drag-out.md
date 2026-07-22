# 191 — Drag-out: export the original file from grid + detail (011 · Cluster A)

Closes the reference tool's "payoff loop": refs can now be dragged OUT of the app
into Finder / Figma / Photoshop as the **original file**, named
`<title-or-source>-<shorthash>.<ext>`. Internal reorder / move / drop-to-rail keep
working byte-identically. First slice of `.docs/feature-todo/011-ux-features.md`
Cluster A (U1); ⌘C / ⌘⌥C + share sheet are the next increment.

Plan + full design-review record: `~/.claude/plans/binary-tumbling-swing.md`
(architecture / code-quality / test / performance review, 16 decisions).

## What ships

- **Grid drag-out (AppKit).** A drag off a cell now carries, alongside the internal
  `AssetDragPayload`, one **file promise per byte-backed asset** in grid order.
  Dropping outside the app copies the originals; dropping inside still reorders /
  moves. Media-less-only drags stay internal (no promise → external op `[]`).
- **Detail drag-out (SwiftUI).** Dragging the detail media pane **at fit**
  (`zoom == 1`) exports the original via `NSItemProvider(contentsOf:)` +
  `suggestedName`. Gated to fit so it never contests the zoom-in pan gesture — and
  because `zoom` commits only at gesture *end*, the gate toggles between gestures,
  never mid-pinch (no remount hitch).
- **Shared naming.** Both surfaces name the file through one pure `AssetExport`
  helper, so grid and detail (and the future ⌘C / 008 export) can't drift.

## Design decisions (from the review)

- **Pure `AssetExport`** (no AtelierIngestion): the extension comes from the blob
  file's own `pathExtension`, so the name, the on-disk file, and the drag `UTType`
  share one source (`UTType(filenameExtension:)`).
- **`AssetFilePromiseProvider: NSFilePromiseProvider`** vends `.assetIDs` on the
  **primary** dragged item, so one session serves both internal drop and external
  file — the drop-to-rail interop path reads the payload unchanged.
- **Stateless `AssetFilePromiseDelegate.shared`** singleton: `NSFilePromiseProvider`
  holds its delegate weakly and a drag can outlive its source view (collection
  switch tears the grid coordinator down mid-drag), so a stable owner is required.
- **Failure-honest (5A):** promises are built only for assets whose blob exists,
  and `writePromiseTo` re-checks at drop and `completionHandler(error)`s on failure
  (no zero-byte file, no crash). Copy runs on a background queue (APFS clone
  same-volume).

## Files

- **New:** `AssetExport.swift` (pure naming + `AssetExportItem` + `exportItem`),
  `AssetFilePromise.swift` (`AssetFilePromiseProvider` + delegate).
- **Edited:** `MasonryGridHost.swift` — `beginDragHandoff` builds file-promise
  drag items (primary carries the payload; one drag image, 14A); external `.copy`
  op when promises exist; new pure `gridExportPlan(assetIDs:details:blobURL:)` in
  the tested-helpers section (order-preserving filter). `ItemDetailView.swift` —
  cached per-asset `exportItem` + a fit-gated `.onDrag` modifier.
- **Tests:** `AssetExportTests` (exhaustive sanitize / baseName / filename +
  `exportItem` temp-file matrix), `AssetFilePromiseTests` (delegate copy success /
  missing-source failure / filename; provider `.assetIDs` round-trip == original +
  gated writableTypes), `GridExportPlanTests` in `MasonryGridHostTests`
  (byte-backed / mixed / all-media-less / missing / grid-order / undragged-excluded).

## Verification

- App unit bundle → **TEST SUCCEEDED** (new suites green).
- `xcodebuild build -scheme AtelierRefs` → **BUILD SUCCEEDED**.
- **Manual (pending, needs a live drag):** drag a grid cell into Finder + Figma →
  original file, human name; multi-select → N files in grid order; internal
  reorder / drop-to-rail / move still work; detail image drag at fit → file;
  a media-less item starts no broken external drag; the detail drag-vs-pan
  interaction when zoomed in.

## Migration notes

None. No schema / wire / service-contract change. File promises are the
sandbox-safe export path — the drop destination is granted by the drag machinery,
so no entitlement change was needed. New sources are auto-included by the Xcode
file-system-synchronized group.
