# 287 — the floating "+", per pane

## Summary

The floating "+" was, in the user's words, "pretty useless": picking **Add Color…**
showed no picker and dropped a fixed dark-grey swatch into the grid, and nothing it
offered could reach a Space. Five separate defects sat behind that.

1. **Pickers built, never wired.** `AddColorButton.swift` and `AddLinkButton.swift`
   were complete — `ColorPicker` + hex field + live swatch, URL field + validation —
   and referenced from nowhere. They were toolbar buttons, and 006 removed the
   toolbar. So the menu shipped `model.addColor(hex: "#2C2C30")`, a hardcoded
   placeholder standing in for the picker that already existed.
2. **The wrong target.** `addColor` / `addLink` wrote to `selectedFolderID` — the
   last collection whose contents were LOADED, not the one on screen. Triggered from
   Home or a Space, the swatch landed in an off-screen folder and read as a no-op.
   `CollectionView.importTargetID` had solved this for drop and ⌘V; the "+" ignored it.
3. **Spaces were structurally unreachable.** The button lived in `AppShellView`,
   OUTSIDE `SpaceView` — and `SpaceModel`, the only writer that reloads an open board,
   lives inside it. (`IngestionModel.addAssetsToSpace` writes the rows but refreshes
   the spaces LIST, so a board open at the time never shows them.)
4. **No file import anywhere in the app.** Not one `NSOpenPanel`. Images could only
   arrive by drag-and-drop or the Chrome extension, though the sandbox has carried
   `files.user-selected.read-write` from the start and `DirectInputReader.fileInput`
   was already written and waiting.
5. **Bad visibility.** It showed on Settings and Capture, which have nothing to add,
   and floated on top of the full-window item detail.

The fix is one structural move: **the "+" is now owned by the pane, not the shell.**
A single shell-level button is forced to guess one menu for every pane, which is why
(1), (3) and (5) all happened. Panes opt in with `.floatingAdd(...)`.

| Pane | "+" |
| --- | --- |
| Collection | Import Images… / Add Link… / Add Color… — rule — New Space from Collection |
| Space | direct click → file panel → imported onto the board |
| Home, Capture, Settings | absent |
| item detail open | hidden |

## Changes

### `FloatingAddItem` grew two shapes

It was a title and a closure. It now also carries an SF Symbol, a `separator` case,
and a **popover** case, so a pane can state its whole menu as one array literal.

A popover entry names a body rather than running one, because an `NSMenu` cannot host
SwiftUI. `FloatingAddControl` owns the presentation and hands the body a `dismiss`
closure. It looks the body up by **title** — deliberately not a per-instance `UUID`,
which would change on every body rebuild and leave the lookup empty under a form that
is currently open.

`FloatingAddButton` also gained `directAction`, which suppresses the menu entirely: a
pane with one thing to add shouldn't make the user pick it out of a menu of one.

### New: `FloatingAddControl.swift`

The pane-level "+": the disc, its menu, the popover host, and `.floatingAdd(...)` in
both menu and single-action forms.

Raising a popover is deferred one runloop turn — the menu action fires from inside
the menu's modal tracking loop, and presenting while that loop is unwinding leaves
the popover with no window to attach to.

### `AddColorButton` → `AddColorForm`, `AddLinkButton` → `AddLinkForm`

Same fields, same validation, same funnel. The dead trigger and self-owned popover
are gone; `onDismiss` now arrives from outside.

### New: `ImportFilesPanel.swift`

`NSOpenPanel`, multi-select, `.image` + `.movie` (video is dropped in the same
pipeline, so restricting to images would refuse files the app can otherwise hold).
Presented as a sheet on the key window, with `runModal()` as the window-less fallback.

It only picks URLs — `IngestionModel.fileInputs` turns them into inputs through the
same `DirectInputReader.fileInput` factory a Finder drop uses, so a chosen file and a
dropped file cannot diverge.

### `IngestionModel`

- `addColor(hex:)` → `addColor(hex:into:)`, `addLink(url:)` → `addLink(url:into:)`.
  The target is a parameter now; callers pass the same resolved target their drop /
  ⌘V paths use.
- New private `perform(reloading:)` — `perform`'s sibling for a write whose target is
  known, reloading THAT folder instead of `selectedFolderID`. The two differ exactly
  when reloading the selection would show the user nothing.
- New `static fileInputs(_:into:)`. Static and input-returning rather than a whole
  import method, so each caller keeps the completion it needs: the grid hands these to
  `run(inputs:)` (which reloads the folder), the board to `importInputs(_:)` (which
  returns the assets to place).

### `CollectionView`

Attaches the four-entry menu, hidden while `nav.presentedItemID != nil`.

Every entry resolves its target **at invocation**, not at menu-build time — the
reason `importTargetID` documents at length: this screen keeps one view identity
across every collection, so a captured `collectionID` can outlive the collection it
was captured for. `nav` is a reference type, so reading it inside the closure is
always current.

### `SpaceView`

Single-action "+", tooltip "Import images onto this board". Files land in **Unsorted**
— matching the canvas's drop and ⌘V paths, since a board is not a collection and
inventing one would file the user's images somewhere they never chose. Placement goes
through `SpaceModel.addAssets`, which is what makes them appear without a reopen.

### `AppShellView`

`floatingAdd` and `addMenuItems` deleted, along with the panel-level overlay.

## Pixel changes

The "+" sits **16pt** from the panel's bottom and trailing edges, sharing
`selectionBarChrome()`'s baseline. It previously read `.padding(.trailing, 24)` /
`.padding(.bottom, 26)` on an overlay applied AFTER the panel's own 12pt margins —
so it actually sat 12pt and 14pt from the panel edge, near the action bar's baseline
but never on it. Changelog 228 claimed the two matched; they did not.

## Files changed

- `AtelierRefs/AtelierRefs/FloatingAddButton.swift` — item shapes, glyphs,
  separators, `directAction`, tooltip
- `AtelierRefs/AtelierRefs/FloatingAddControl.swift` — **new**
- `AtelierRefs/AtelierRefs/ImportFilesPanel.swift` — **new**
- `AtelierRefs/AtelierRefs/AddColorForm.swift` — **new** (was `AddColorButton.swift`)
- `AtelierRefs/AtelierRefs/AddLinkForm.swift` — **new** (was `AddLinkButton.swift`)
- `AtelierRefs/AtelierRefs/AddFromLibrarySheet.swift` — **deleted**
- `AtelierRefs/AtelierRefs/IngestionModel.swift`
- `AtelierRefs/AtelierRefs/CollectionView.swift`
- `AtelierRefs/AtelierRefs/SpaceView.swift`
- `AtelierRefs/AtelierRefs/AppShellView.swift`

## Migration notes

`addColor(hex:)` and `addLink(url:)` no longer exist — both need an explicit target
collection. `AddColorButton`, `AddLinkButton` and `AddFromLibrarySheet` are gone; the
first two are the `*Form` views, which are popover BODIES and carry no trigger of
their own. No `.pbxproj` edits: the app target uses file-system-synchronized groups.

## Known gap (not in this change)

Dragging items from the sidebar onto an **open** space
(`SpacesOutlineView.swift:445` → `IngestionModel.addAssetsToSpace`) has the same
staleness this change fixed for the "+": it writes the rows but refreshes the spaces
list, so a board open at the time doesn't reload. Same root cause, different entry
point — left alone deliberately.
