# 365 — The Backlog Says What Is True

Docs only. No code changed.

A pass over `.docs/feature-todo/` to answer "what do we pick up next" found that
the backlog could not be trusted to answer it: **seven of eleven docs misstated
their own status**, several by whole phases. [081](../.docs/081-backup-plan.md)
declared H4–H7 "not started" while `BackupController`, `LibraryArchiveWriter` and
`ImportReplay` all ship with test suites. [018] asserted "no snapping of any
kind" and "schema is at v15" against a tree with `CanvasSnapping.swift`,
`ResizeHandles.swift` and nineteen migrations. Answering the question at all
required auditing the whole tree, which is a tax that recurs every time the
question is asked.

So every doc was re-verified against the code and rewritten to match.

## Three docs shipped and were promoted

Following the ritual of `.change-log/347` and `349`.

| Was | Is | Shipped in |
|---|---|---|
| `feature-todo/008-backup.md` | `.docs/081-backup-plan.md` | `cfd94eb`, `5ff8d24` (H4/H5), `e37282c` (H6), `00500b2` (H7), `962aca5` |
| `feature-todo/014-sharing-out.md` | `.docs/082-sharing-out-plan.md` | `8162c58` (S1), `eda306c` (S2), `87eb2e7` (S3) |
| `feature-todo/019-clipboard-fidelity.md` | `.docs/083-clipboard-fidelity-plan.md` | `c672373`, on `4be6f88` |

Each gained a Status block recording the commits and answering its open questions
from what actually shipped rather than from what was recommended:

- **[081]** — multi-collection assets duplicate per folder; **no** zip wrapper;
  cadence is manual + on-launch-if-stale (`BackupCadence`, H5d).
- **[082]** — PNG scale and captions became **controls**, not defaults, so neither
  open question's options were the answer. The composer also landed as its own
  `AtelierExport` package rather than a seam inside `CanvasRenderer`.
- **[083]** — same-collection ⌘V is a no-op with a notice (`resolvePaste` →
  `.alreadyMembers`); the copy report stays about the external copy; ⌘⌥V was
  deliberately never built.

References were rewritten rather than left to rot, as 347 established: `[008]` →
`[081]` across `.docs/030`, `056`, `057`, `068`, five `.change-log` entries from
the backup line, and every remaining backlog doc. `.docs/056` had already been
carrying a broken `./008-backup.md` path and now resolves.

## Six docs were partly shipped and are now trimmed to their remainder

| Doc | Shipped | Actually left |
|---|---|---|
| [011] UX | U1, U2 (as masonry), U3, U5 (v19), U7 (v10) | **⌘K switcher**, **floating palette** |
| [012] intelligence | I1 (v7), I2, I5, **I6** (v14 — the phase marked "deliberately v2") | agent-tag **accept/dismiss/suppress**, **color swatches + filter** |
| [013] capture breadth | K3 clipboard watcher | K1 restructure, K2 Safari |
| [016] library mgmt | L1 stats, L2 replay layer | L3 competitor parsers |
| [018] canvas | C1–C6 — snapping, resize, camera (v17), paste, format bubble, cursors | C7 **pinch smoothing** only |
| [020] rednote | K1 stopgap, K2 platform + v18 re-tag | K3 sweep (**blocked**), K4 video |

Each keeps its original body under a "Current state at the time of writing
(historical)" heading — the reconnaissance is still worth reading, it just is not
the present tense any more.

[017] was the one doc that had not drifted: still not started, still blocked on a
fresh Meta export.

## What this makes visible

Only [023] is both unstarted and unblocked. [020] K3 waits on a pagination
fixture that can only be captured from a logged-in session; [017] waits on a Meta
export; [013] K2 waits on App Store appetite; the rest are smaller. That is the
selection [023] now records.

## [023] rewritten as a buildable spec

Sixteen review decisions were inlined rather than left as prose to rediscover.
The load-bearing ones:

- **`Shelf` in Swift, `archived_at` in SQL, "Archived" in the UI** — the naming
  collision this doc called its likeliest source of confusion, now decided.
- **`includeArchived` is not defaulted.** A default is the shape that leaks; a
  non-defaulted parameter turns the next unconsidered read into a compile error.
- **A0 extracts the duplicated queries first.** `collectionCovers`/`spaceCovers`
  and `collectionStackPreviews`/`spaceStackPreviews` are two structurally
  identical pairs; the naive route adds the predicate in 8 places that must agree
  pairwise, and one missed edit is the "12 items, shows 9" bug the doc already
  feared. Home's unfiltered count aggregate gets scoped to its roots at the same
  time.
- **The predicate is a WHERE conjunct in search**, never a post-filter — a
  post-filter silently shortens pages.
- **The partial index ships with v20.** The original reasoning (a null check on a
  column null for ~everything gains nothing from an index) is right for the hot
  path and wrong for the shelf, which is a library-wide `IS NOT NULL` scan and
  sort with no index behind it, on the one surface that only grows.
- **One doc claim was simply wrong and is corrected**: the orphan sweep does *not*
  need to skip archived assets. `referencedBlobHashes()` selects every `asset`
  row, so archived blobs are in the keep set by construction. That needs a
  regression test, not a code change.

The remaining open questions closed: assets only in v1 (archiving a container
makes a multi-collection asset ambiguous), Space tiles vanish and return, and
archived items are **never** auto-purged.

## Files changed

- `.docs/081-backup-plan.md`, `082-sharing-out-plan.md`,
  `083-clipboard-fidelity-plan.md` (moved from `feature-todo/`, renumbered,
  stamped)
- `.docs/feature-todo/011`, `012`, `013`, `016`, `017`, `018`, `020` (status
  blocks, phases marked, open questions closed)
- `.docs/feature-todo/023` (substantially rewritten)
- `.docs/030`, `056`, `057`, `068` (references only)
- `.change-log/099`–`103`, `290` (references only)

## Migration notes

None — documentation only. Nothing in the build or the app reads these files.
Anything holding a link to a `feature-todo/008`, `014` or `019` path needs
updating.
