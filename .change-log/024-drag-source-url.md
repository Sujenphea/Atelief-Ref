# 024 — Drag captures the source page URL (paste/drag parity)

## Summary

Dragging a browser image into the Library now captures its **source page URL**
as provenance, the same as pasting does. Previously the drop handler passed
`sourceURL: nil` and never read an accompanying web URL, so a dragged browser
image lost its origin link even though `DirectInputReader` already supported it —
an inconsistency between the drag and paste paths. Drag and paste now agree.

Note on scope: the captured source is tagged platform **`web`** with the page URL
as `originalURL` (shown in the inspector + "Open Original Source"). Platform-
specific classification (`twitter`, etc.) and the canonical post permalink remain
the **Chrome extension's** job (build-order #6); a bare link with no image is
still the deferred link-resolution path (007 §scope).

## What changed

- `AtelierRefs/AtelierRefs/LibraryView.swift`
  - `handleDrop` now collects any web (`http`/`https`) URL across the whole drop
    FIRST — a browser drag delivers the page URL either on the image's own
    provider or as a separate URL provider — then attaches it to the image(s).
  - `input(from:pageURL:into:)` routes an image **with** a page URL to
    `DirectInputReader.browserImageInput` (`.web`, page URL as `originalURL`) and
    an image **without** one to `pasteInput` (`.localPaste`). File drops still
    take the file branch first and ignore `pageURL`.
  - New `firstWebURL(in:)` scans providers, skipping file-URL providers (a file
    URL also conforms to `public.url` but isn't provenance).
- `AtelierIngestion/.../Input/DirectInputReader.swift`
  - `isWebURL(_:)` promoted from `private` to `public` so the app's drop handler
    and the pasteboard path share ONE definition of "web URL" (DRY — they must
    agree on what counts as a source page).

## Verification

- `swift test` (AtelierIngestion): green (the browser-image + web-URL logic is
  already covered by `DirectInputReaderTests.pasteboardBrowserImage`; `isWebURL`
  visibility change is behavior-preserving).
- `xcodebuild -scheme AtelierRefs`: BUILD SUCCEEDED.
- The drop glue is app-side SwiftUI/AppKit → compile-verified only; the shared
  provenance factories it calls are unit-tested in the package. A manual
  drag-from-browser check remains pending.

## Migration notes

None. Additive behavior; no schema or data change. One package symbol widened
from `private` to `public` (`DirectInputReader.isWebURL`).
