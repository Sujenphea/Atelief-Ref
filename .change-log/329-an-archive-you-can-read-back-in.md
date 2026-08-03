# 329 — An Archive You Can Read Back In (008 · H7)

H6 taught the app to write a portable archive. This is the other half, and the
last piece of 008: **reading one back in**. No schema change; the library is
still at v18.

The importer is deliberately **two pieces**, because the second one is what
[016]'s competitor importers (Eagle, Raindrop, Pinterest) will consume:

1. **A pure parse** — `archive on disk → [ImportPlan]`. Opens files, decodes
   JSON, touches nothing else. Archive-specific.
2. **The replay layer** — walks plans through the **existing public writers**.
   Every invariant, validation and 18A content-hash dedup comes free, because
   nothing bypasses the funnel.

## Summary

- **`ImportPlan.swift`** (new) — the vocabulary the replay layer speaks:
  `ImportPlan` / `ImportItem` / `ImportBytes` / `ImportBody` / `ImportTag`, plus
  the honest-report types `ImportSkip` / `ImportSkipReason` / `ImportFailure` /
  `ImportReport`. Plain values; no database, no filesystem, no AppKit.
- **`ImportReplay.swift`** (new) — `LibraryImporter.replay(_:into:…)`. The only
  thing in the feature that writes, and it writes exclusively through
  `createCollection`, `ingest`, `ingestContent`, `addAssets`, `applyTag`,
  `setName`, `setNote`, `setGridOrder` and `setCanvasPlacement`.
- **`LibraryArchiveReader.swift`** (new) — the archive's parse: `ArchiveParse`,
  `ArchiveReadError`, and the version refusal delegated to H6's
  `ArchiveManifest.refusal(for:schemaVersion:)`.
- **`ArchiveImportController.swift`** (new) — the `ExportController` shape for
  the sixth time, plus `ImportOutcome` / `ImportRunSummary` and
  `ArchiveImportCopy` (the prose, AppKit-free and fully tested).
- **`ArchiveFolderPanel.presentImport`** — an `NSOpenPanel` this time, choosing a
  directory: the archive is a folder the user already has.
- Settings' **Archive** section gains an "Import Archive…" row; `IngestionModel`
  gains `archiveImport` / `canImportArchive` / `importArchive()`.

## There is no private back door, and that is the design

The replay layer creates every row through the same writers the app itself uses.
The consequence is the point: **an importer cannot produce a library state the
app could not have produced.** Membership uniqueness, the Unsorted invariant,
name validation, canonical payloads and dedup keys, 18A dedup — none of it is
re-implemented here, so none of it can be re-broken here.

It is also why the second piece is a *layer* rather than a function inside the
archive reader. 016's three parsers will produce `[ImportPlan]` and get all of
the above for nothing. Built for the archive, with those three as the design
pressure test — not as unbuilt requirements.

## The destination is a new root collection, always

Named after the archive folder. Never a merge into existing collections, never a
clobber. `createCollection` already disambiguates a duplicate sibling name
Finder-style, so importing the same archive twice gives you "Studio Archive" and
"Studio Archive 2" — two containers, not one overwritten.

The source library's **Unsorted comes in as a plain folder** under that
destination. It is deliberately *not* special-cased: everything inside the
destination is an ordinary folder, and the alternatives — dropping those
untriaged assets, or merging them into *this* library's Unsorted — are precisely
the silent drop and the silent clobber the destination rule exists to prevent.

## Idempotency is a property of the manifest

`ingest`'s 18A dedup reuses an existing asset over the same bytes **only when its
source matches the incoming provenance** — same `original_url` when one exists,
else same `platform`. A source field the archive dropped or the reader normalized
would leave every asset *present* on a second import, as a **second copy**. So
the round-trip tests assert asset **count**, not presence, and provenance is
copied field for field with nothing touched in between.

Two rules fall out of the same reasoning:

- **Tags are applied however an asset resolved** — additive, idempotent, and new
  information about media you already had.
- **`name` and `note` are applied only to a NEWLY created asset.** Writing them
  over a dedup hit would silently discard an edit the user made in *this*
  library, which is the clobber the destination rule is there to prevent.

## The hash is computed, never trusted

The manifest declares a `blob_hash`; the reader ignores it and the replay layer
hashes the file it is about to store. The blob store is content-addressed, and
bytes filed under a hash nobody verified render as the **wrong image for every
future asset that hashes there** — a corruption with no recovery. An archive is a
browsable folder the user can rename, replace and edit files inside, so its
declared hash is a claim about a file, not a fact about bytes. The cost is one
streaming read of a file that was going to be copied anyway.

## Nesting comes from `parent_collection_id`, never from `path`

H6 relocates a folder that would overrun the 768-byte path budget to the top of
`Collections/`, so **two unrelated collections can legitimately share one
`path`**. Rebuilding nesting from directories would merge them. `parentKey` is
the whole structure, a plan naming a parent the archive didn't ship becomes a
root rather than disappearing, and a cycle — impossible from this app, possible
in a file — loses nesting but never a collection. All three are pinned by tests,
including a round trip whose two "Refs" folders share one path.

## Parse, then snapshot, then write

An unreadable or refused archive must cost **nothing** — no snapshot, no rows, no
partially applied contract. So the pre-destructive snapshot goes in *after* the
archive proves readable and *before* the first `createCollection`. It is injected
into the controller rather than reached for, which makes that ordering a tested
fact rather than a comment.

Version refusal is H6's, called and not re-derived: `manifest_version` and
`schema_version` refused when **newer than this build**, an *unparseable* version
on either side deliberately not a refusal. A refusal is its own outcome
(`.refused`), not a failure — nothing broke; this build declined to guess.

And the cancel flag is asked **before** any error is classified. H5b, H5c and H6
each paid for that ordering; this is the fourth job to inherit it. A stopped
import keeps what it already wrote — every row went in through the funnel, so the
result is a *smaller* library, not a damaged one.

## Honest reports

`N imported / N skipped with reasons / N failed`, never a bare success. Skips are
named at parse time (`unknownAsset`, `unknownSource`, `missingFile`, `unusable`);
failures are writers that threw, recorded per item with the run continuing —
one bad row must not cost a user the rest of their library. Anything short of
whole reports `.incomplete`, and the status line says which and how many.

## What the archive carries, and what it does not

Carried: collections with their real nesting and descriptions, memberships with
manual order and canvas placement, assets once each with kind, dimensions,
duration, download state, name, note and payload, tags as `(name, source)`, and
provenance verbatim.

Not carried, by decision:

- **`asset_analysis` / `asset_embedding`** — recomputable by definition, and
  including them would freeze an `analyzer_version` into a portability contract.
- **A tag attached to no asset** — no public writer can recreate one, and a 100%
  replayable contract is worth more than the edge case.
- **Spaces, saved searches and jobs** — a user decision (2026-08-03), not an
  oversight: they are not in this plan's graph and not representable in a
  collection tree.
- **Favourites** — they do not exist in schema v18. The plan lists them; there is
  no column, tag convention or flag to carry.

Server-authoritative fields are re-minted rather than restored: ids,
`created_at`, `view_count`, `last_viewed_at`, `dedup_key` and `search_text`. An
import is a new library's version of the same graph, not a row-for-row restore —
that is what H5c's backup restore is for.

## Files changed

**AtelierRefs**

- `ImportPlan.swift` (new) — `ImportPlan`, `ImportItem`, `ImportTag`,
  `ImportBytes`, `ImportBody`, `ImportSkipReason`, `ImportSkip`,
  `ImportFailure`, `ImportReport`.
- `ImportReplay.swift` (new) — `LibraryImporter.replay(_:into:isCancelled:onProgress:)`,
  `parentsFirst(_:)`.
- `LibraryArchiveReader.swift` (new) — `ArchiveReadError`, `ArchiveParse`,
  `LibraryArchiveReader.parse(_:schemaVersion:)`, `destinationName(for:)`,
  `unreferencedFiles(in:referenced:)`.
- `ArchiveImportController.swift` (new) — `ImportOutcome`, `ImportRunSummary`,
  `ArchiveImportCopy`, `ArchiveImportController`.
- `ArchiveFolderPanel.swift` — `presentImport(completion:)`, an `NSOpenPanel`.
- `IngestionModel.swift` — `archiveImport`, `canImportArchive`,
  `importArchive()`.
- `SettingsView.swift`, `AtelierRefsApp.swift` — the import row and its wiring.

**Tests**

- `LibraryArchiveReaderTests` (new) — the pure parse from a temp directory:
  well-formed, media-less, empty, missing manifest, malformed manifest, manifest
  missing keys, missing referenced file, unreferenced file, unknown asset,
  unknown source, unusable asset, shared-path nesting, `parentsFirst` ordering
  (including unknown parent and a cycle), the full refusal matrix with
  unparseable-is-not-a-refusal, and the prose.
- `LibraryArchiveRoundTripTests` (new) — real export → real import over two temp
  libraries: full round trip (nesting, order, tags, name, note, provenance, blob
  bytes), a multi-collection asset yielding N memberships and exactly 1 asset,
  import-twice idempotency, a media-less round trip, shared-path nesting end to
  end, a missing blob reported as incomplete, cancel-is-not-failure, a refusal
  taking no snapshot, snapshot-before-first-write, a missing manifest, and an
  unreachable folder.

## Migration notes

**None.** No schema change (still v18), no `UserDefaults` key added or renamed,
no on-disk format changed, no new entitlement — an open-panel grant is usable for
the life of the process, which is longer than the run. `Migrator.registeredIdentifiers`
is untouched.

The import **only adds**. It never deletes, never renames, and never writes into
a collection that existed before it ran.
