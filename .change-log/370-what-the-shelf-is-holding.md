# 370 — What the Shelf Is Holding

[084](../.docs/084-archive-shelf-plan.md) phase **A4**, the last of phase A. The
Library pane now reports the shelf, and two guards make sure a future column
cannot slip out of the backup the way `archived_at` nearly did.

Smaller than 023 planned, because A1 had to pull the manifest field and the
orphan-sweep regression test forward — including archived rows in the export made
both load-bearing immediately.

## The stats row

`archivedUsage()` is the one read whose subject IS the shelf: it counts archived
rows and reports the bytes only archived assets hold.

**`exclusiveBytes` counts a blob only when every asset referencing it is
archived.** Blobs are shared — one file, many asset rows — so a plain
`SUM(file_size)` would double-count a picture saved into three collections, and
counting a blob a visible item still points at would promise space that
unarchiving nothing could release. A number in a "reclaim" row that overstates is
worse than no number.

Two figures rather than one, because they diverge in exactly the cases that
matter: a shelf of a thousand color swatches is a large count and zero bytes; one
archived video is the opposite. The row reads `12 items · 2.4 MB reclaimable`, or
`40 items · nothing to reclaim` — spelled out rather than hidden, because "there
is nothing to free" is a real answer and a bare count would leave the reader
guessing. Omitted entirely when nothing is archived, following the section's
existing rule that a library with no videos gets no Videos row.

The read-surface guard from A1 caught this one on the way in: `archivedUsage`
appeared as an unpinned `FROM asset` site and failed the test by name until its
reason was written down. Working as intended.

## The exhaustiveness guard, as a two-link chain

    asset TABLE  ⇄  `Asset` record        AssetColumnCoverageTests   (Core)
    `Asset` record ⇄  manifest AssetEntry  ArchiveManifestFieldTests  (app)

Split because the schema needs `PRAGMA` (Core) and the manifest type lives in the
app — and better for being split: a column added without a thought now fails
twice, and **the second failure is the one that matters**. A field can be added to
the schema and the record, work perfectly in the app, and be silently dropped
from every export; the symptom appears months later when someone restores a
backup and finds the value gone. `archived_at` is exactly that field.

Both compare what the types actually ENCODE rather than a hand-kept list of
names, which is the thing the guards exist to make unnecessary. The excluded list
carries a stated reason per field (`view_count` is local usage, `search_text` and
`dedup_key` are derived), and a second test fails if an exclusion names a field
that no longer exists — stale exclusions would otherwise mask a rename.

Mutation-verified: deleting `case archivedAt = "archived_at"` from the manifest's
`CodingKeys` — a change that still compiles and still passes every other test —
fails this one.

### The guard caught itself first

The first draft built its sample `Asset` with nil optionals. `JSONEncoder` omits
those, so both sets came back short and `everyFieldIsCarriedOrExcluded` passed by
comparing two incomplete lists — the precise failure mode the guard exists to
prevent. `scanIsNotVacuous` is what caught it, which is why it is there.

## Tests — 685 in Core (was 680), plus 8 app-side

- `ServicesShelfReadTests` (+3): a blob shared between an archived and a visible
  asset frees nothing; a media-less shelf counts items and no bytes; a blob under
  two archived assets is counted once.
- `AssetColumnCoverageTests` (+2, Core), `ArchiveManifestFieldTests` (+5, app),
  `LibraryStatsCopyTests` (+3).

## Files changed

- `AtelierCore`: `AppServices.swift` (`archivedUsage`), `ServiceTypes.swift`
  (`ArchivedUsage`), `MigrationTests.swift`, `ServicesShelfReadTests.swift`,
  `AssetReadSurfaceTests.swift`
- `AtelierRefs`: `LibraryStatsController.swift`, `LibraryStatsCopy.swift`,
  `SettingsView.swift`, and new `ArchiveManifestFieldTests.swift`
- Docs: `feature-todo/023` promoted to `.docs/084-archive-shelf-plan.md`;
  inbound references rewritten in `.docs/081`, `feature-todo/012` and
  `.change-log/366`–`369`.

## Migration notes

None — no schema change. `LibraryStatsSnapshot.archived` is defaulted, so a
snapshot built without it still compiles.
