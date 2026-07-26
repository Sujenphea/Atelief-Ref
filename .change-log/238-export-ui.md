# 238 — Moodboard export UI + save/error surface

052 · Track B · **B3**. Wires the `AtelierExport` engine (237/B2) into the app: a
Figma-style export popover on the Space board, an off-main render with a top-bar
progress ring, and a `ToastCenter` result summary.

## Summary

- **Package linked** — `AtelierExport` added to the Xcode app target (6 pbxproj
  sites, mirroring the sibling local packages).
- **Sandbox entitlement** — `files.user-selected.read-only` →
  `…read-write`, so the save panel's chosen file is writable (052 · A1/B3).
- **App↔package bridge** (`MoodboardExport.swift`, pure/testable) — maps
  `SpaceItemDetail` + `AssetContent` + `ElementStyle` into the package's
  `MoodboardElement` model; a `.color` → swatch, any image-backed kind (image /
  video poster / link & tweet card) → image via `previewImageURL`, `.text` /
  `.frame` elements → their styled content; non-renderable rows counted as skips
  (052 · 7A). `rows(items:selected:)` encodes the selection-or-whole-board scope.
  `MoodboardURLImageProvider` decodes each request lazily through the shared
  `ImageDecoding` downsampler (052 · 13A/16A).
- **`ExportController`** (window-level `ObservableObject`) — owns the
  `NSSavePanel`, runs the render on a detached task (052 · 15A) with a
  thread-safe `CancelFlag` (detached tasks don't inherit cancellation),
  publishes `progress`, and reports success / cancelled / failed + skip count.
- **UI** (`MoodboardExportControls.swift`) — in the Space header:
  - `MoodboardExportButton` → popover: Format (PDF/PNG) + one contextual row
    (PDF: Single page / Letter pages · PNG: 1×/2×/3×) + a live `N refs · M pages`
    count, then **Export…** hands off to the save panel.
  - `ExportProgressRing` → a determinate ring while rendering (click → **Cancel**
    popover), a brief checkmark on success.
  - `ExportMoodboardCommand` → **File ▸ Export Moodboard…** (⇧⌘E), reaching the
    focused board via `FocusedValues.exportMoodboard`; exports with default
    settings.
- **Result toast** (`ContentView`) — a confirmation on success (noting skipped
  media-less refs), an error on failure; a user-cancelled export is silent.

## Renderer change (package)

`MoodboardRenderer.renderPDF/renderPNG` gained an `onProgress: (Double) -> Void`
callback (per element, then `1`) so the ring shows real progress. Additive,
default no-op; 2 new package tests.

## Files changed

- **New**: `MoodboardExport.swift`, `ExportController.swift`,
  `MoodboardExportControls.swift`, `AtelierRefsTests/MoodboardExportTests.swift`.
- **Modified**: `project.pbxproj` (package link), `AtelierRefs.entitlements`
  (read-write), `ContentView.swift` (controller + report toast),
  `SpaceView.swift` (export controls in header + focused command action),
  `AtelierRefsApp.swift` (menu command),
  `AtelierExport/.../MoodboardRenderer.swift` + its tests (progress callback).

## Tests

- Package: 31 → still green (2 progress tests added).
- App: `MoodboardExportTests` — 20 pure tests across mapping (each kind →
  element/skip, geometry, counts), selection-or-board rows, config→page plan
  (png/single/letter/empty), the URL provider, and an end-to-end
  map→pages→render PDF. All passing.

## Migration notes

- Moodboard export is a **Space-board** feature; the grid contact-sheet + HTML
  export remain **B4**.
- The read-write entitlement change requires a re-sign on the next release build;
  no data migration.
- Manual live verification (save panel, on-disk PDF/PNG, cancel) still to be run
  in-app — the logic is unit-covered but the AppKit save-panel round-trip is not.
