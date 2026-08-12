# 385 — The Originals Were Always The Point

Three exports could compose a collection into something — a moodboard PNG, a
contact-sheet PDF, a self-contained web page — and none could simply hand over the
files. Out-flow had a per-item half (drag one ref into Figma, ⌘C) and no batch
half, so "give me these forty images" meant forty drags.

`AssetExport.swift:6` has pointed at this since 011 landed ("the future ⌘C / 008
export all"), and `ExportNameAllocator` was written for it specifically: its whole
docstring is about the case a single drag never has — many names side by side in
one destination folder, on a **case-insensitive** volume where `Hero-ab12cd34.png`
and `hero-ab12cd34.png` are the same path. That machinery existed with one caller.
It now has two.

## 1 · Export Assets…

Selection-or-whole-collection → a save dialog naming a new folder → the original
files copied into it under the names drag-out already gives them.

```
Desktop/Brand Refs/
├── nike-ad-3f2a91c4.jpg
├── poster-study-8b01de77.png
└── title-sequence-c40f9a2e.mp4
```

Reachable from the selection popover, the grid's right-click menu, and
`File ▸ Export Assets…` — the three paths the other exports each offer. No
keyboard shortcut, matching Contact Sheet and Web Page.

**And no config popover**, which is the one place this deliberately breaks the
pattern its three siblings share. The moodboard picks a format and a scale, the
contact sheet columns and captions, the web page columns and provenance. The files
are the files. A popover whose entire content is a summary line and an Export
button is a click tax, so the click goes straight to the save dialog.

## 2 · Two divergences from the web-page export, both on purpose

`CollectionSiteExport` is this export's closest sibling and disagrees with it
twice.

**Videos export as the video.** The web page copies a poster frame on the stated
reasoning that a page destined for email should not smuggle a 300 MB movie along.
Here the originals *are* the product, so a video contributes its own bytes; a
folder that silently substituted stills would answer a question nobody asked.
`webPageStillTakesPoster` pins both halves of the split against the same fixture
row, so neither can drift into the other.

**Nothing is invented for a byte-less ref.** A colour swatch, or a link/tweet
whose image was never captured, has no file — so it is counted in `skipped` and
reported in the completion toast, never written as a `.txt` sidecar or a 1×1 PNG.
`AssetExport.pasteboardEntry`'s text fallbacks stay a ⌘C affordance, where the
destination is usually a text field. They are right there and wrong here.

## 3 · Share ▸

The last third of 011's out-flow cluster, and it adds no export vocabulary at all:
`AssetExport.exportSelection` already resolves a selection to ordered entries plus
a skip count. `AssetShare` maps those to what AppKit's services take — file URLs
for originals, the kind's text for a byte-less ref, which is exactly the fallback
the folder export refuses.

Multi-select shares N items rather than the first one, so "AirDrop these twelve"
is one AirDrop of twelve files. It sits in the grid's right-click menu and in the
item detail page's overflow, beside the other verbs that hand a ref to something
outside the app.

Built on `NSSharingServicePicker.standardShareMenuItem` (which deprecated
`sharingServices(forItems:)` in macOS 13) rather than a hand-rolled service list —
the user's own services, their recent AirDrop targets and the current ordering are
not this app's to reproduce. The picker is parked in the menu item's
`representedObject` deliberately: it populates the submenu lazily, so a picker
released at the end of the builder leaves an item that opens an empty submenu.

## 4 · One vocabulary, not two

`SiteAsset` (a source URL + its name in the folder) and `SiteSkip` (missing source
/ copy failed) described exactly what a second folder writer needed. Rather than a
near-identical pair beside them, both became `ExportFile` / `ExportSkip` with the
`Site*` names kept as typealiases — no call site changed, and a partial export now
reads the same whichever writer produced it because it is the same type.

`AssetFolderWriter` keeps `SiteExportWriter`'s two load-bearing properties for the
same reasons that file already spells out: every file is a `FileManager.copyItem`,
so a 40 GB selection costs the same resident memory as a 40 MB one; and one bad
ref is a reported skip, never a throw that sinks the other N-1.

The scope rule was already duplicated between `ContactSheetExport.rows` and
`CollectionSiteExport.rows`. This export delegates rather than adding a third copy
of a one-line filter, and `rowsMatchSiblingExports` asserts the three agree.

## Files

**AtelierExport**
- `Assets/AssetFolderWriter.swift` — new; `ExportFile`, `ExportSkip`,
  `AssetFolderResult`, and the streaming copy loop
- `Site/SiteGallery.swift`, `Site/SiteExportWriter.swift` — `SiteAsset` / `SiteSkip`
  become typealiases
- `Render/ExportError.swift` — `noPages` doc now covers both folder writers

**AtelierRefs**
- `AssetFolderExport.swift` — new; the selection → `Plan` mapping
- `AssetFolderExportControls.swift` — new; the focused action + File-menu command
- `AssetShare.swift` — new; the share payload mapping and menu item
- `ExportController.swift` — `requestAssetExport` + `startAssets`, the fourth entry
  point on the same progress ring / cancel flag / toast
- `IngestionModel.swift` — `exportSelection(from:assetIDs:)`, shared by both new
  surfaces; selects by **asset** id, unlike ⌘C's membership-shaped path
- `MasonryGridHost.swift` — `onExportAssets` / `shareSelection` config hooks and
  `addOutFlowItems`
- `CollectionView.swift` — the runner (selection-or-all and right-click-targets
  forms), the focused value, the popover row, the two hooks
- `LibrarySearch.swift` — the same two hooks; the folder is named after the query
- `ItemDetailView.swift` — `shareEntry` + the overflow menu's `ShareLink`
- `AtelierRefsApp.swift` — `File ▸ Export Assets…`

**Tests** — `AssetFolderWriterTests` (12, package), `AssetFolderExportTests` (16),
`AssetShareTests` (9). Full app suite and all 79 package tests green.

## Migration notes

None — no schema change, no new permission, no network posture change. Exporting
is a read of the blob store plus a write to a folder the user picked, which is
what the archive and web-page exports already do.

A re-export into the same folder refreshes the names it wrote and touches nothing
else in there; a cancelled or failed run only removes the destination folder if
that run created it. Both rules are `SiteExportWriter`'s, and
`reExportRefreshesOnlyItsOwn` pins the bystander case.

## Not done

- **The archive shelf gets neither verb.** Its menu is three items on purpose — the
  shelf is where refs go to be out of the way, and a share sheet is not what "put
  this away" asks for.
- **No size estimate before the write.** Straight-to-save was chosen over a confirm
  panel, so a whole-collection export states its count only in the finished toast.
  If someone exports 40 GB by accident, the progress ring and Stop are the whole
  recovery. Worth revisiting only if it actually bites.
- **Space boards export moodboards, not originals.** A board's items are refs too,
  and the same plan would work there; nothing wires it, because the board's export
  button already means something else and 011's cluster is about the library
  surfaces.
- **No sidecar manifest.** A folder of originals carries no titles, tags or
  sources. That is [081](../.docs/081-backup-plan.md)'s archive, which exists and
  is the honest answer for "keep the metadata too".
- **`FileManager.copyItem` duplicates bytes where APFS could clone them.** On a
  same-volume export — Desktop being the common destination — `clonefile(2)` would
  be near-instant and cost zero extra space, since APFS shares blocks until one
  side is written. A 40 GB export currently writes 40 GB. Not taken: it needs
  `Darwin`'s `copyfile(3)` plus a cross-volume fallback, inside a package whose
  whole boundary is "zero product dependencies, pure Foundation", and typical
  exports are tens of files. Recorded as a known lever rather than a plan.
