# 323 — A Collection Becomes a Web Page (014 · S3)

The third and last of `014`'s outputs. A collection exports as a folder —

```
<chosen folder>/
  index.html      zero JS, no external requests
  assets/         the image files
```

— that opens from disk, survives an email attachment, and drops onto any static
host. S1 (space → PNG) and S2 (PDF / contact sheet) shipped earlier; this adds
no fourth way of doing any of it.

## Summary

- **`AtelierExport/Site/`** (new, in the package) — `SiteGallery` (the input
  model), `SiteLayout` (column grouping), `StaticSiteRenderer` (the `index.html`
  template) and `SiteExportWriter` (the folder). Pure and host-free like the
  rest of the package, so all of it runs under `swift test` in milliseconds.
- **`CollectionSiteExport`** (new, app) — the bridge, shaped after
  `ContactSheetExport`: `rows` is the same selection-or-whole-collection rule,
  and the caption is literally `ContactSheetExport.caption(for:)` so a ref reads
  the same whether it lands in a PDF or on a page.
- **`ExportNameAllocator`** (new, in `AssetExport.swift`) — the one thing a
  folder needs that a single drag-out never did. See below.
- **`ExportController.requestSiteExport`** — a second entry point on the
  existing controller, not a second controller. Same `isExporting` / `progress`
  / `lastReport`, so the progress ring, the cancel popover and the completion
  toast work unchanged.
- **Chrome** — `CollectionSiteExportButton` (a config popover in the selection
  bar, beside the contact sheet's) and `File ▸ Export Web Page…`.

## Self-contained is a property, not a slogan

The page loads no script, no stylesheet, no font and no remote image. Every URL
it emits is a relative path into the sibling `assets/` folder; the play glyph on
a video poster is inline SVG for exactly that reason. The only absolute URL the
page can contain is a source link, and only when the user asks for one.

Those invariants are asserted separately from the golden files, because a golden
would let them rot silently as long as both sides changed together. The single-
file data-URI variant stays rejected: base64 inflates the bytes by a third and
produces HTML most editors refuse to open.

## The collision that loses data quietly

`AssetExport.filename` names a file by content — `<base>-<shorthash>.<ext>` —
which is all a dropped file has ever needed. A folder is the first caller to
write many of those names side by side, and there the short hash stops being a
guarantee: it is 8 characters of a longer digest, and the base is a human title,
which repeats freely.

The trap is quieter than a plain duplicate. macOS volumes are
**case-insensitive**, so `Hero-ab12cd34.png` and `hero-ab12cd34.png` are one
path: writing the second name does not produce a second file, it lands on the
first. And the writer *must* refresh an existing destination, or re-exporting
into the same folder would fail with "file exists" — so the collision surfaces
as a silent overwrite, and the export ships one image twice while reporting two.
`ExportNameAllocator` therefore decides uniqueness case-**in**sensitively and
hands back `hero-ab12cd34-2.png`, with the suffix before the extension so the
file still says what it is. The name keeps the casing the asset's own title gave
it.

Two rows backed by the same blob are the opposite case and get the opposite
treatment: one name, one copy, two cells pointing at it.

## Neither layout engine fit, and that is the finding

`MoodboardLayout` converts world rects to page points for a fixed sheet; a web
page has neither. `MasonryLayout` computes absolute `CGRect`s for a known
viewport width — baking those into HTML would freeze the page at whatever width
the exporting Mac happened to have, which is the opposite of what a shareable
page should do.

What carries over is `MasonryLayout`'s placement *rule*: item `i` lives in
column `i % C`, so the exported page reads left-to-right exactly as the grid it
came from. `SiteLayout.columnGroups` is that rule and nothing else, and
`CollectionSiteExportTests` pins it against `MasonryLayout.layout` itself rather
than against a comment. The heights are still `columnWidth / aspect` — flexbox
just does that arithmetic in the browser instead of in Swift, which is why the
page reflows properly on a phone.

## Honest about what it wrote

Assets are copied **first**; `index.html` is rendered afterwards from only the
items whose bytes actually landed. A blob reaped between planning and writing
becomes a counted skip, not a broken `<img>` the recipient discovers a week
later. Nothing is ever held in memory: each ref is one `FileManager.copyItem`,
so a 4 GB collection costs the same resident bytes as a 4 MB one.

Videos are poster frames (settled in 014). The video file is not copied, the
still carries a play glyph, and the page's own footer says so — a recipient
should not have to guess why a video is a picture.

Cancelling asks the **flag** before it classifies the error, the lesson from
`301`: work already in flight throws on the way out, and a user who pressed Stop
must not be told their export failed. A run that cancels or fails removes the
folder only if this run created it; a folder that was already there is the
user's.

## Provenance is a row of its own

"Include source links" is a separate toggle from "Captions" and defaults to
**on**. A title is a label; a source is provenance, and deciding to strip the
second is not the same decision as tidying away the first. Captions off also
drops the words from `alt` — leaking them back through the accessibility text
would quietly undo the choice.

An empty collection disables the action in both places (the button, and the
File-menu command's focused value goes `nil`) rather than writing an empty
folder.

## Files changed

- `AtelierExport/Sources/AtelierExport/Site/SiteGallery.swift` — new (model).
- `AtelierExport/Sources/AtelierExport/Site/SiteLayout.swift` — new (columns).
- `AtelierExport/Sources/AtelierExport/Site/StaticSiteRenderer.swift` — new
  (the template).
- `AtelierExport/Sources/AtelierExport/Site/SiteExportWriter.swift` — new (the
  folder, the streaming copy, the skip report).
- `AtelierExport/Sources/AtelierExport/Render/ExportError.swift` — `noPages`
  now also covers an empty gallery (doc only).
- `AtelierExport/Package.swift` — golden fixtures as test resources.
- `AtelierRefs/AtelierRefs/CollectionSiteExport.swift` — new (the bridge).
- `AtelierRefs/AtelierRefs/CollectionSiteExportControls.swift` — new (popover +
  menu command).
- `AtelierRefs/AtelierRefs/AssetExport.swift` — `ExportNameAllocator`.
- `AtelierRefs/AtelierRefs/ExportController.swift` — `requestSiteExport` +
  `startSite`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — the selection-bar button and
  the focused File-menu action.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — `ExportWebPageCommand`.
- Tests (new, 63): `AtelierExport/Tests/AtelierExportTests/`
  `StaticSiteRendererTests.swift` (+ two committed golden pages under
  `Fixtures/`), `SiteLayoutTests.swift`, `SiteExportWriterTests.swift`;
  `AtelierRefs/AtelierRefsTests/CollectionSiteExportTests.swift`, and an
  `ExportNameAllocator` suite added to the existing `AssetExportTests.swift`.

## Test results

`swift test --package-path AtelierExport` — 67 tests in 6 suites, passed.
`AtelierRefs` scheme (`build-for-testing` + `test-without-building`,
`-destination 'platform=macOS'`) — TEST SUCCEEDED.

## Migration notes

**None.** Pure read + render: no schema change, no on-disk change, no new
entitlement. The save panel's grant covers writing the chosen folder, so the
sandbox posture is unchanged and nothing is remembered between runs.

Two things worth knowing about the output. Images are copied as **originals**,
not re-encoded — full fidelity, and a byte copy needs no decoder — so a
collection of 40-megapixel scans exports as a large folder. And re-exporting
over a previous run refreshes `index.html` and any same-named assets but does
not delete files it did not write; a folder that has drifted is better cleared
by hand than by an exporter deciding to erase a directory the user chose.
