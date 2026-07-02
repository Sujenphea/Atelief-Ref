# 019 — Ingestion: input adapters + app hook

**Chunk 5 (final)** of the ingestion build: the DIRECT-INPUT ADAPTERS that turn
pasteboard / drag content into `IngestInput`s with correct provenance (the
testable core), plus a THIN app hook — a drop target + Paste command wired to the
coordinator — that proves the capture loop end-to-end in the running app. LOCAL
paths only (007 §scope): paste-image, paste/drag-file, drag-browser-image. No
network URL resolution.

## Summary

### `DirectInputReader` (package, testable — `Input/DirectInputReader.swift`)
A stateless `public enum` over AppKit / UniformTypeIdentifiers.

Pure provenance factories (no AppKit global state, take the `Date` as a param so
tests are deterministic):

- `pasteInput(imageData:sourceURL:into:at:)` → `ByteSource.data`,
  `SourceDraft(platform: .localPaste, originalURL: sourceURL?.absoluteString)`.
- `fileInput(fileURL:into:at:)` → `ByteSource.fileURL`,
  `SourceDraft(platform: .localDrag, rawMetadata: .object(["original_path": .string(fileURL.path)]))`.
- `browserImageInput(imageData:pageURL:into:at:)` → `.data`,
  `SourceDraft(platform: .web, originalURL: pageURL.absoluteString)`.

`inputs(from: NSPasteboard, into:, now:)` picks the best interpretation:
1. **image data** (`.png` / `.tiff` / `public.jpeg`) → if a WEB url (`http`/`https`)
   is also present, browser-image (`.web`); else paste-image (`.localPaste`,
   attaching any URL carried); 2. **file URL(s)** (`NSURL` filtered to
   `isFileURL`) → one `.localDrag` per file; 3. empty/unsupported → `[]`.
Tests use a NAMED `NSPasteboard(name:)` — never `.general`, no GUI.

### `LibraryLocation` (package — `Media/LibraryLocation.swift`)
`public enum LibraryLocation { static func defaultRoot() throws -> URL }` →
`<Application Support>/ref-atelier/`, created if absent. In the sandboxed app this
resolves to the per-app container's Application Support (writable, no entitlement).

### App hook (`AtelierRefs`)
- `IngestionModel: ObservableObject` (`@MainActor`) — opens the Library at the
  default root (`LibraryLayout` + `MediaStore` + `AppServices` at
  `root/library.sqlite`), ensures a default **"Inbox"** collection, holds an
  `IngestCoordinator`, and `run(inputs:)` drives the coordinator OFF-MAIN (it's an
  actor), publishing `@Published` ingested items (asset id + a thumbnail `NSImage`
  loaded from the `MediaStore`) + progress + a status line.
- `ImportView` — a dashed drop target (`.onDrop(of: [.image, .fileURL, .url])`)
  converting `NSItemProvider`s into inputs (file URL → `fileInput`; image bytes →
  `pasteInput`) via async `withCheckedContinuation` loaders; a **Paste** button
  (⌘V) calling `DirectInputReader.inputs(from: .general, …)`; and a `LazyVGrid` of
  thumbnails with a count + progress bar. Minimal by design — a loop demo.
- `ContentView` now a `TabView`: **Canvas** (the existing `CanvasView` harness,
  moved verbatim into a `CanvasTab` subview — unchanged behavior) and **Import**.

## Provenance mapping (per input path)

| Path | platform | originalURL | raw_metadata |
| --- | --- | --- | --- |
| paste image | `local_paste` | clipboard URL if any, else nil | — |
| paste/drag file | `local_drag` | nil | `original_path` = file path |
| drag browser image | `web` | the source PAGE url | — |

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputReader.swift` *(new)*
- `AtelierIngestion/Sources/AtelierIngestion/Media/LibraryLocation.swift` *(new)*
- `AtelierIngestion/Tests/AtelierIngestionTests/DirectInputReaderTests.swift` *(new)*
- `AtelierRefs/AtelierRefs/IngestionModel.swift` *(new)*
- `AtelierRefs/AtelierRefs/ImportView.swift` *(new)*
- `AtelierRefs/AtelierRefs/ContentView.swift` *(edited)* — `TabView` + `CanvasTab`.

New app source files under `AtelierRefs/AtelierRefs/` are picked up automatically
(file-system-synchronized groups, `objectVersion 77`); the pbxproj was NOT touched.

## Verification

- `cd AtelierIngestion && swift test` — **58 tests in 8 suites passed** (~0.5s):
  the 50 chunk-1–4 tests plus 8 new `DirectInputReader` tests (4 pure factories,
  4 named-pasteboard interpretations incl. empty → []).
- `cd AtelierRefs && xcodebuild … build` — **BUILD SUCCEEDED** (ImportView +
  IngestionModel + TabView compile and link both packages).

## Entitlements

No change needed. The app was already sandboxed with `ENABLE_USER_SELECTED_FILES =
readonly`, so the generated `.xcent` already carries
`com.apple.security.files.user-selected.read-only` (verified) — dragged files are
readable. Application Support writes land inside the sandbox container (writable by
default), so `LibraryLocation.defaultRoot()` needs no extra entitlement.

## Manual runtime steps that prove the loop (GUI can't be auto-tested here)

1. Run the app → **Import** tab (status shows "Library ready").
2. Copy an image (e.g. ⌘C in Preview) → click **Paste** (or ⌘V): a thumbnail
   appears in the grid, count increments, status shows "Imported 1."
3. Drag an image file from Finder onto the drop zone: it ingests as `.localDrag`
   and a thumbnail appears.
4. Re-paste/re-drop the same image: it dedups (18A) — a repeat badge shows on the
   tile, no second blob is written.
On disk: `<Application Support>/ref-atelier/{blobs,thumbnails}/…` fill and
`library.sqlite` gains the asset + source + Inbox membership.

## Migration notes

Additive. New public surface in `AtelierIngestion` (`DirectInputReader`,
`LibraryLocation`); the app gains the Import tab. The Canvas spike is preserved
unchanged as its own tab. Nothing reverted.
