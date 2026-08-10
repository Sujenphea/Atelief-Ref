# 016 — Library Management: Storage Stats, Cleanup, Competitor Importers

> Housekeeping + adoption. Settled scope (user, 2026-07-13): storage stats,
> cleanup surface, and competitor importers are in; **multiple libraries is
> DEFERRED** — this doc records the seams so nothing new hard-codes
> single-library assumptions.

## Status (re-verified against the tree 2026-08-10)

| Phase | State | Where |
|---|---|---|
| L1 stats + cleanup surface | **shipped** | `LibraryStatsController.swift`, `LibraryStatsCopy.swift`, `ServicesLibraryStatsTests`, `LibraryStatsControllerTests`, `LibraryStatsCopyTests` |
| L2 replay layer | **shipped, via [081](../081-backup-plan.md) H7** | `ImportPlan.swift` (the parse↔replay vocabulary) + `ImportReplay.swift` (`LibraryImporter`), exactly as this doc's DRY move specified |
| L3 competitor parsers | **not started** | no Eagle, Raindrop or Pinterest-export parser anywhere |

So the shared dependency L3 was waiting on **exists and is tested**. Writing an
Eagle parser now means writing a pure `parse(export) → [ImportPlan]` and nothing
else — no pipeline, no ingest logic, no validation, no dedup.

### Where the parsers live (settled 2026-08-10)

`ImportPlan` and `ImportReplay` sit in the **app target**, per
[081](../081-backup-plan.md)'s as-built §1 ("no `AtelierBackup` package… revisit
only if importers ever ship outside the app"). `ImportPlan` is pure by
construction — *"no database, no filesystem, no AppKit"* — so it is genuinely
package-shaped code in an app target, and each parser adds committed fixtures on
top.

**Decision: keep it there for parser #1; extract at parser #2.** One parser does
not justify re-opening a boundary the 081 review deliberately settled; three
would. The trigger is written down here so the boundary moves by decision rather
than by drift — if a second parser is scheduled, `ImportPlan` + the parsers go to
a package (`LibraryImporter` stays in the app, since it needs `AppServices` and
`MediaStore`) *before* that parser is written, not after.

## Current state at the time of writing (historical — see Status above)

- No storage visibility of any kind: library size, per-kind/per-platform
  breakdown, largest items — all unknowable without Finder spelunking into the
  container.
- Cleanup machinery exists but is headless: `MediaReaper` (orphan
  blobs → Trash), `reconcileOrphanedKnownItems`, [081](../081-backup-plan.md)'s planned
  `integrityCheck()` — none user-invokable.
- No importers: a user arriving from Eagle/Raindrop (or holding a Pinterest data
  export) starts from zero.

## A — Storage stats + cleanup surface

A "Library" section in Settings ([010]) or an About-Library sheet:

- **Stats**: total size (DB + blobs + thumbnails measured separately), asset
  count by kind/platform, **largest-items list** (top N by blob size — one query
  joining `asset` to on-disk sizes; sizes cached in a lightweight scan, not
  stat-ed per render). Largest-items rows offer Reveal / open detail / Delete
  (existing paths — no new destructive machinery).
- **Cleanup actions**, each explicit and confirmable: Run orphan sweep
  (MediaReaper), Regenerate missing thumbnails, Verify integrity ([081]),
  Snapshot now ([081]). All existing seams getting buttons — deliberately no new
  engine.
- Thumbnail-tier sizes surface the [081] TM-exclusion win ("regenerable: X GB").

**Effort: S–M.** Pure read layer + buttons on existing services.

## B — Competitor importers (adoption lever)

Import from the tools a switcher actually leaves: **Eagle** (folder-per-item with
`metadata.json` — richest mapping: folders, tags, source URLs, originals),
**Raindrop** (CSV/HTML export — links + tags + collections; items become [003]
link-kind or [001]-resolved images), **Pinterest data export** (the [002]
secondary path — one importer family, shared shape).

- **Architecture (the DRY move):** every importer is a pure
  `parse(export) → [ImportPlan]` step + ONE shared **replay layer** that walks
  plans through existing `AppServices` writers (`createCollection`, `ingest`,
  `applyTag`, `addAssets`) — **the same replay layer [081]'s manifest import
  builds.** Build it once there; importers are then parsers, not pipelines.
  Validation, provenance, and 18A dedup come free; re-running an import is
  idempotent by content hash.
- Fixtures: committed real-shape exports (anonymized) per source; parsers are
  pure over them.
- Rejected: bespoke per-source pipelines (three copies of ingest logic);
  network-fetching importers for link-only sources beyond [001]'s existing
  resolver (scope creep into a crawler).

**Effort: M per source** (parser + fixtures + mapping decisions), on top of
[081] H7's replay layer.

## C — Multi-library: deferred, seams recorded

Not building now. What it WOULD touch — keep these clean meanwhile:

1. `LibraryLayout` root is already injected (good); never let new code reach the
   container path directly.
2. The capture token + server port are per-app, not per-library — a second
   library must not mint a second server. Decision then: one server, library
   routing by id.
3. UserDefaults keys (`AtelierLastCollectionID`, density, [013] watcher toggle)
   would need library-scoping — namespace new keys under a `library.<id>.` prefix
   *from now on* (cheap discipline today, migration avoided later).
4. [081] backup targets and snapshots namespace by library id (already specced).
5. [011]'s palette window state references collection/space ids — ids are
   per-library; fine if (3) is followed.

## Schema / migration impact

**None.** Stats are reads + filesystem scan; importers ride existing writers.

## Phased implementation

1. ~~**L1 (S–M)** — stats reads + Library pane + cleanup buttons.~~ **Shipped.**
2. ~~**L2 (M)** — replay layer lands via [081] H7.~~ **Shipped.**
3. **L3 (M each)** — Eagle → Raindrop → Pinterest-export parsers, demand-ordered.
   The only outstanding phase. Parser #1 lands beside `ImportPlan.swift` in the
   app target; **parser #2 triggers the package extraction** (see Status above).

## Test strategy

- Stats reads: TempLibrary with known blob sizes → exact totals/top-N; missing
  file (blob trashed mid-scan) → skip, not crash.
- Parsers: pure over committed fixtures — happy path, malformed rows, missing
  fields, duplicate entries, unicode/emoji names, huge exports (streaming parse
  for Raindrop CSV).
- Replay idempotency: import twice → identical library (008's round-trip suite
  extended).
- Cleanup buttons: invoke-existing-service assertions only (services already
  tested).

## Effort: **A: S–M · B: M per source (after 008 H7) · C: 0 (discipline only)**

## Risks & edge cases

- Eagle metadata quality varies by version — parser must treat every field as
  optional except the image file itself.
- Raindrop exports links, not bytes: importing before [003]/[001] land means
  flattening to resolved images or skipping — sequence importers after the link
  kind exists, or import degraded with a report.
- Import reports must be honest: N imported / N skipped (with reasons) / N
  failed — never a silent partial ([004]'s batch-outcome lesson).
- The filesystem size scan must tolerate the user's Trash-restore of reaped blobs
  (files reappearing mid-scan).

## Settled decisions

- Multi-library deferred with seams recorded (user, 2026-07-13); importers share
  [081]'s replay layer; cleanup = buttons on existing services only.

## Open questions

1. Importer priority order — Eagle first (recommended: richest data, likeliest
   switcher) — confirm.
2. Import destination: always a new root collection named after the source
   (recommended) vs merging into existing structure?
3. Stats pane home: Settings ([010]) or a gallery-toolbar About-Library sheet?
