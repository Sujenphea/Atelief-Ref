# 236 — ⌘C Copy: assets to the pasteboard

## Summary

Export track (`.docs/052`, phase **B1**). Adds **Edit ▸ Copy (⌘C)** for the selected
assets across every surface — the collection grid, the search grid, the Spaces canvas,
and the item-detail overlay — writing the reference *out* to the general pasteboard so it
pastes into Finder, image editors, chat, or a text field.

### The pasteboard contract (8A, kind-aware)
One place, `AssetExport.pasteboardEntry`, decides what an asset copies as, keyed off the
`AssetContent` render seam so Copy and the grid's render never disagree:
- **image / video** → the on-disk original **file** (Finder + editors); a *single* image
  also writes the decoded `NSImage` so editors get pixels (multi-select stays URL-only to
  avoid N eager decodes).
- **link / tweet _with_ a captured image** (og:image / card image) → that **image file** —
  they render as image cards, so ⌘C yields the image, not a URL.
- **bare link / tweet** (no image) → the URL / rebuilt permalink text.
- **color** → the `#rrggbb` hex text.
- **missing-blob image, or unknown** → skipped, and the skip is **reported** (7A): a
  partial copy raises one "Copied N — M had no image" toast; a full copy is silent.

### Unified selection (4A / DRY)
All surfaces resolve their selection through one path — grid & search via
`IngestionModel.copySelectedToPasteboard(from:selection:)`, canvas & detail supply their
own ordered assets — funnelling into `copyToPasteboard(assets:)` →
`AssetExport.exportSelection` → `AssetPasteboardWriter`. `AssetExport.exportItem` was
widened to accept an optional `Source` so canvas rows (which may lack a source) reuse the
same assembly. No selection→payload logic is duplicated.

### Routing (R-A)
⌘C routes through the **AppKit responder chain** (`copy(_:)` on the grid's
`MasonryNSCollectionView` and the canvas's `CanvasHostView`, gated by
`NSUserInterfaceValidations`), and `.onCopyCommand` on the SwiftUI detail view — so the
system's unmodified Edit menu is used and **text-field Cut/Copy/Paste/Select All stay
intact** (no `CommandGroup(replacing: .pasteboard)`).

## Files changed

- **`AtelierRefs/AtelierRefs/AssetPasteboard.swift`** — new. `AssetPasteboardEntry`,
  `ExportSelection`, `AssetExport.pasteboardEntry` / `exportSelection`, and
  `AssetPasteboardWriter` (the 8A writer).
- **`AssetExport.swift`** — `exportItem` `source` widened to `Source?`.
- **`IngestionModel.swift`** — `copyToPasteboard(assets:)` (the one write+report path),
  `copySelectedToPasteboard(from:selection:)` (grid/search convenience), `lastCopyReport`.
- **`ContentView.swift`** — partial-copy toast on `lastCopyReport`.
- **`MasonryGridHost.swift`** — `copy(_:)` + `NSUserInterfaceValidations`; `gridCopyCommand`
  / `gridHasSelection` on the events protocol + coordinator; `onCopy` on the config.
- **`CollectionView.swift`**, **`LibrarySearch.swift`** — wire `onCopy` to the shared path.
- **`CanvasRenderer/.../CanvasHostView.swift`**, **`CanvasView.swift`** — `onCopyTiles`
  callback + `copy(_:)` + validation (mirrors the existing `onDeleteTiles` seam).
- **`SpaceView.swift`** — `onCopyTiles` maps selected tiles → z-ordered assets → copy.
- **`ItemDetailView.swift`** — `.onCopyCommand` reusing the drag-out provider.
- **`AtelierRefsTests/AssetPasteboardTests.swift`** — new. 11A coverage: kind-aware entry
  builder (incl. the **link/tweet-with-image → file** regression), order + skip counting,
  and the writer against a scratch `NSPasteboard`.

## Verification

- `xcodebuild build` — clean (incl. the `CanvasRenderer` cross-package change).
- Full B1 suite green (entry / selection / writer / exportItem / deployment-target guard).
- Live: the user confirmed image copy+paste works on the grid, and an image-backed tweet
  (the "viktoroddy" card image) now pastes as the JPEG rather than failing as URL text.

## Notes / deferred

- The `AtelierExport` SPM package (plan 3A) is **deferred to B2** (the rasterizer), where
  pure render/layout logic justifies it; B1's selection seam lives in the app target to
  avoid a one-type package (premature abstraction).
- Detail Copy uses `.onCopyCommand` (provider-based), so it copies the file for
  image-backed items and nothing for a media-less detail — a minor gap vs the grid's text
  fallback, acceptable because detail is overwhelmingly image-backed.
