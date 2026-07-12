# Item Detail Page — Design

Kind: `design` (spec). Replaces the Library tab's trailing `.inspector()` panel with
a full-window detail page for a single item.

## Problem

The Library tab (`AtelierRefs/AtelierRefs/LibraryView.swift`) shows a thumbnail grid
with a trailing SwiftUI `.inspector()` panel (`InspectorView`) that renders the selected
item's details: a small 240pt preview, metadata, provenance, and source actions. The
panel is:

- **Cramped** — 260–420pt wide, so the media preview is only 240pt tall.
- **Low-resolution** — it shows the 1280px "large" thumbnail tier, not the original.
- **Silent for video** — a video asset shows its poster thumbnail only; playback is
  delegated out of the app (QuickLook window / Preview.app).

## Goal

Remove the inspector entirely. Clicking a grid cell opens a **full-window detail page**
that gives the media most of the screen, with the old inspector's details docked on the
right.

## Confirmed decisions

1. **Presentation** — full-window overlay inside the Library tab (covers the folder tree
   + grid). Escape or a Back button returns to the grid. Stays within the Library tab
   (no new window, no `NavigationStack` — the app has none today).
2. **Video** — inline AVKit `VideoPlayer` with standard transport controls (introduces
   `import AVKit`, not used in the app target before).
3. **Image** — full-resolution original blob via `model.blobURL(for:)`, decoded off-main.
   The already-loaded 1280 preview (`model.previewImage`) shows instantly as a placeholder
   and is swapped for the full-res decode when ready.
4. **Item navigation** — ← / → arrows step prev/next through the folder's items in place,
   updating both the media and the details.

## Design

### New view — `ItemDetailView`

`struct ItemDetailView: View` with `@ObservedObject var model: IngestionModel` and an
`onClose: () -> Void` callback. The current item is read from `model.selectedItem`, so
prev/next simply call `model.select(_:)` and reuse the app's centralized selection.

Layout — a `VStack` of a top bar over an `HStack`:

- **Top bar:** `Back` button (`onClose`, `.keyboardShortcut(.cancelAction)` = Escape);
  a `‹ prev` / `next ›` pair with an "N / total" counter (disabled at the ends); the
  item's source title, trailing.
- **Media area (fills most of the width):** branch on `detail.asset.kind` —
  - `.image` → `Image(nsImage:)` `.resizable().aspectRatio(contentMode: .fit)`, from the
    full-res `NSImage` (falls back to `model.previewImage`, then a `ProgressView`).
  - `.video` → `VideoPlayer(player:)` fed an `AVPlayer(url:)` built from
    `model.blobURL(for: detail)`.
- **Details sidebar (right, fixed ~300pt):** metadata + provenance + actions, a private
  `DetailSidebar` subview ported from `InspectorView` (minus the small preview and empty
  state). Adds a **Duration** row (`m:ss`) for videos — `asset.duration` is currently
  unused by the inspector.

### Media loading & lifecycle

- A `.task(id: model.selectedItemID)` reloads media on open and on every prev/next:
  reset `fullImage`/`player`, then for an image decode `NSImage(contentsOf: blobURL)` in a
  detached `.userInitiated` task and publish back only if the item is still current
  (mirrors `IngestionModel.loadPreview`, `IngestionModel.swift:572`); for a video build a
  fresh `AVPlayer(url:)`.
- **No caching** for full-res images — they are large; decode on demand and drop the
  previous one on navigation.
- `.onDisappear` pauses and releases the player so a video does not keep playing after
  Back.

### Prev / next

`currentIndex` = index of `selectedItemID` in `model.items`; `step(±1)` clamps to the
folder and calls `model.select(model.items[target])`. Wired to `Button`s with
`.keyboardShortcut(.leftArrow/.rightArrow, modifiers: [])` — command-based shortcuts win
over the grid's focus-based `.onKeyPress` while the overlay is up.

### `LibraryView` changes

- Remove `@State showInspector`, the `.inspector(...)` modifier, and the "Toggle
  Inspector" toolbar item. Keep the Browser Capture toolbar item + popover.
- Add `@State showDetail`. Wrap the `NavigationSplitView` (and its `.alert` / `.toolbar`)
  in a `ZStack`; overlay `ItemDetailView` when `showDetail && model.selectedItem != nil`.
- Grid cell tap keeps `model.select(detail)` and also sets `showDetail = true`
  (with animation).
- **Auto-dismiss:** removing/deleting the item from the detail page clears
  `model.selectedItem` on the model's reload, and the `model.selectedItem != nil` guard
  drops the overlay back to the grid.

### `InspectorView`

Deleted — its metadata / provenance / actions sections and helpers (`section`, `row`,
`formattedSize`, `formattedDate`, `platformLabel`) move into `DetailSidebar`. The Xcode
project uses file-system synchronized groups, so adding/deleting a `.swift` file needs no
`.pbxproj` edits.

## Reused `IngestionModel` surface (no model changes)

`selectedItem` (`:149`), `selectedItemID`, `items`, `select(_:)` (`:563`),
`previewImage` / `loadPreview` (`:572`), `blobURL(for:)` (`:589`), and the action methods
`openSource` / `openBlob` / `revealInFinder` / `copySourceLink` / `removeFromFolder` /
`requestDelete` (`:597`–`:676`). Precedent for the video-URL branch: `CanvasContent`
`videoURL(forTileID:)` (`CanvasContent.swift:70`).

## Verification

1. Build (`AtelierRefs` scheme, Xcode 26); no `InspectorView`/`showInspector` references
   remain; new file compiles with `import AVKit`.
2. Library tab: inspector panel and its toolbar toggle are gone.
3. Click an image → full-window page; image fills most of the view at full resolution;
   details on the right.
4. Click a video → inline player plays; Back/Escape stops playback and returns.
5. ← / → step prev/next in place; disabled at first/last item.
6. Remove/Delete from the page → dismisses back to the grid without a crash.
7. Escape and Back both return; grid arrow-nav and drag-reorder still work afterward.
