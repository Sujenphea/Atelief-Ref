# 328 — A Library You Can Take With You (008 · H6)

H5 taught the app to copy itself off-device so a dead Mac isn't a dead library.
This is the other half of 008: a **portable archive** — a folder of images anyone
can open in Finder, beside one `manifest.json` that describes the whole graph
precisely enough for the app to read it back in. No schema change; the library is
still at v18.

```
<archive>/
  manifest.json                    ← the contract
  Collections/Design/Refs/Hero-ab12cd34.png
```

## Summary

- **`LibraryArchive.swift`** (new) — `ArchiveManifest` (the contract, golden-file
  pinned), `ArchiveLayout` (the folder rules and the path budget), and the
  version refusal.
- **`LibraryArchiveWriter.swift`** (new) — the streaming writer: one collection
  at a time, `FileManager.copyItem` for bytes, cancel checked per collection and
  per item, `manifest.json` written last.
- **`ArchiveExportController.swift`** (new) — the `ExportController` shape for
  the fifth time, plus `ArchiveRunSummary` and `ArchiveCopy` (the prose, AppKit-
  free and fully tested, per H4's split).
- **`ArchiveFolderPanel.swift`** (new) — an `NSSavePanel`, because the user is
  naming something new.
- **`AssetExport`'s naming members are now `nonisolated`** — they were always
  pure; the annotation says so to the compiler too, so a detached writer can name
  thousands of files. `dragProvider` stays main-actor.
- Settings gains an **Archive** section, and `IngestionModel` gains
  `archive` / `canArchiveLibrary` / `archiveLibrary()` / `revealArchive()`.

## The tree and the manifest are deliberately not symmetric

An asset in five collections is copied into **five folders** — browsability is
the archive's entire point, and a folder of aliases or a folder of one file with
four dangling references is not a folder anyone wants to open. The manifest
records that asset **once**, with five memberships.

That asymmetry is the whole reason the manifest exists. Re-importing the tree
alone would produce five assets over one blob; re-importing the manifest produces
one asset with five memberships, which is what the library actually held.

## The manifest is the contract, and provenance is the load-bearing part

`AppServices.ingest`'s 18A dedup reuses an existing asset sharing a blob hash
**only when its source matches the incoming provenance** — same `original_url`
when one is given, else same `platform`. So import idempotency is a property of
*this file*, not of the pipeline: an exporter that dropped, trimmed or normalized
a source field would fork a second asset over the same bytes on every re-import,
and the failure would look like a pipeline bug. `original_url`, `author_handle`,
`author_name`, `title`, `platform`, `captured_at` and the whole `raw_metadata`
document ride verbatim, and a test asserts it in those words.

What is **excluded**, and why:

- **`asset_analysis` and `asset_embedding`** — recomputable by definition.
  Writing them would freeze an `analyzer_version` into a portability contract,
  which is the one place a version should never be pinned by accident.
- **Tags with no asset.** Per-asset `tags: [{name, source}]` is exactly what
  `applyTag(_:to:source:)` finds-or-creates. A tag id would be data an importer
  must ignore, and an unattached tag has no public writer that could recreate it.
  Everything in this contract is replayable through the shipped funnel.
- **Spaces, saved searches and jobs.** Not in H6's graph and not representable in
  a collection tree. A gap, named here rather than discovered later.
- **Favourites**, which the plan lists — there is no favourite anywhere in schema
  v18. Nothing was dropped; there was nothing to drop.

Timestamps are ISO-8601 **whole seconds**, truncated on the way *in* as well as
out, so the in-memory manifest and the on-disk one are the same value —
`BackupManifest`'s reasoning, for the same reason.

## Two things a folder needs that a single drag-out never did

`AssetExport.filename(base:blobHash:ext:)` is reused verbatim — same sanitizer,
same 60-character cap, same `<title-or-source>-<shorthash>.<ext>`. There is one
export naming rule in this app, not two.

**Collisions.** The short hash is the first 8 characters of a longer digest, so
two different blobs can land on it, and human titles repeat freely. macOS volumes
are case-insensitive by default, so `Hero-ab12cd34.png` and `hero-ab12cd34.png`
are the *same path* — writing the second doesn't fail, it overwrites the first,
and the export ships one image twice while reporting two. `ExportNameAllocator`
(shipped with 014 · S3) already decides uniqueness case-insensitively; the
archive is its second caller, and the archive-scale cases are now in
`AssetExportTests` beside the rest of the matrix.

The allocator is keyed by **destination folder**, not by collection. That is what
makes the path rule below safe: if two collections ever resolve to one folder,
their filenames still cannot collide.

**Path length.** `PATH_MAX` is 1024 bytes, the archive root is the user's and can
be any length, and a 60-*character* name is up to 240 *bytes* of emoji. The
budget is therefore on the archive-relative path: 768 bytes, of which 256 are
reserved for the filename a directory will hold. A collection whose folder would
blow that budget is **relocated to the top of `Collections/`**, keeping its name
plus the first 8 characters of its id so two deep folders sharing a name can't
merge. Relocation cascades gently — a relocated folder is at depth 1, so its own
children nest under it again — and a pathological tree comes out as several
shallow trees rather than one flat pile.

Losing depth is safe because the folder tree is a *presentation* of the graph,
not the graph: `manifest.json` carries every collection's real
`parent_collection_id`, so an importer rebuilds the true nesting regardless of
where the bytes were browsable. A path the filesystem refuses to create is a
failed export; a shallower folder is a cosmetic cost.

## The manifest is the commit record

It is written **last** and atomically. A run that is cancelled or fails leaves a
folder of images with no manifest — visibly incomplete rather than plausibly
whole. That is the same role `BackupRunner`'s manifest plays for a backup, and
`BackupCatalog` already relies on it there.

And the cancel flag is asked **before** any error is classified. Cancelling tears
down in-flight work, which throws; a user who pressed Stop must never be told
their archive failed. H5b and H5c both paid for that ordering; this is the third
job to inherit it.

## Version refusal, in the shape H5c established

`manifest_version` and `schema_version`, both refused when **newer than this
build**. An *unparseable* version on either side is deliberately not a refusal —
the rule is "newer than me", and "I can't tell" is not evidence of that. Written
now, in H6, so H7's importer has the rule to call rather than to invent.

## Files changed

**AtelierRefs**

- `LibraryArchive.swift` (new) — `ArchiveLayout`, `ArchiveRefusal`,
  `ArchiveManifest` + its `SourceEntry` / `AssetEntry` / `TagEntry` /
  `CollectionEntry` / `MembershipEntry`.
- `LibraryArchiveWriter.swift` (new) — `write(to:isCancelled:onProgress:)`,
  `folderPlan()`, `folderName(for:)`, `fraction(...)`, `Result`.
- `ArchiveExportController.swift` (new) — `ArchiveOutcome`, `ArchiveRunSummary`,
  `ArchiveCopy`, `ArchiveExportController`.
- `ArchiveFolderPanel.swift` (new) — the save panel.
- `AssetExport.swift` — `baseName` / `sanitize` / `filename` / `exportItem` are
  `nonisolated`.
- `IngestionModel.swift` — `archive`, `canArchiveLibrary`, `archiveLibrary()`,
  `revealArchive()`.
- `SettingsView.swift`, `AtelierRefsApp.swift` — the Archive section and its
  wiring.

**Tests** — `LibraryArchiveTests` (golden manifest, refusal matrix, layout and
path budget, prose), `LibraryArchiveExportTests` (writer + controller against a
real temp library), and two archive-scale cases added to
`AssetExportTests`' allocator suite.

## Migration notes

**None.** No schema change (still v18), no `UserDefaults` key added or renamed,
no on-disk format changed, no new entitlement — a save-panel grant is usable for
the life of the process, which is longer than the run.

One source-level change outside the feature: four `AssetExport` statics gained
`nonisolated`. Existing main-actor callers are unaffected; the annotation only
widens where they may be called from.

The archive **reads only**. It never mutates the library, and it is deliberately
not blocked by a pending restore — a user one relaunch away from replacing their
library is exactly the user who might want a portable copy of what it holds now.
