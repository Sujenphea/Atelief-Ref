# 143 — Delete-undo: verbatim undelete + deferred blob GC (010)

Makes **asset delete undoable** — the gap 139 deferred (open-Q1) and the case the
user actually hit (delete → ⌘Z → disabled sound). Reverses the cascading
`deleteAssets` with a core capture/restore primitive, a deferred-reap blob lifecycle,
and a launch-time orphan GC. Design chosen via an interactive architecture/quality/
tests/performance review (all recommended options taken).

## Design (locked in review)

- **Blob lifecycle — defer + launch GC.** A recoverable delete does **not** reap blobs;
  undo re-inserts the rows with the bytes still on disk (lossless in-session). A delete
  that's never undone is reclaimed at the next launch — the undo history is
  session-scoped, so anything unreferenced then is unreachable. No Trash-recovery
  fragility.
- **Core primitive (verbatim, stable ids)**, mirroring `restoreSpaceItem`.
- **Restore the user-visible graph** (assets, sources, memberships + manual order, tag
  links, covers); the `job_item` ledger is not restored (it self-heals via ingest dedup).
- **Dedup-aware, best-effort restore**: idempotent (skip-if-exists), skips an asset whose
  dedup key a live capture recreated, skips a membership whose collection is gone,
  restores a cover only if still cover-less — never aborts the whole undo for one sub-part.

## What changed

**Core (`AtelierCore`)**
- `DeletedAssetsBackup` — arrays of domain records (`[Asset]`/`[Source]`/
  `[CollectionItem]`/`[AssetTag]`/cover refs); no bespoke DTO.
- Extracted the delete cascade into `performDelete(_:in:)`, now shared by:
  - `deleteAssets(_:)` (unchanged behavior) and
  - `deleteAssetsRecoverable(_:) -> DeletedAssetsBackup` — captures the graph with
    set-based `IN (…)` reads (no N+1) and deletes in **one transaction** (no TOCTOU);
    does **not** reap blobs.
- `restoreDeletedAssets(_:)` — one transaction, best-effort per row (see design).
- `referencedBlobHashes() -> Set<String>` — the GC "keep" set.

**Store (`AtelierIngestion`)**
- `MediaStore.enumerateBlobFiles()` — walks `blobs/ab/cd/<hash>.<ext>`.
- `MediaReaper.reapOrphanedBlobs(referenced:)` — Trashes every on-disk blob (+ thumbnail
  tiers) not referenced; returns the Trash URLs.

**Model (`IngestionModel`)**
- `confirmPendingDeletion` now captures a backup, deletes without reaping, and registers
  the undo (⌘Z → `restoreDeletedAssets`; redo → delete-again, still no reap). The
  pre-destructive snapshot stays.
- `runOrphanBlobGC` wired into bootstrap, off-main after launch; a failed read of the
  referenced set **skips** the sweep (never reaps on uncertainty).

## Tests

- **Core round-trip matrix** (`ServicesDeleteUndoTests`, 11): single, multi-collection +
  exact manual order, tags, cover, shared-source-not-doubled, media-less kinds, plus the
  failure suite — collection-gone, dedup-key recreated, idempotency, redo cycle, and
  `referencedBlobHashes`.
- **GC suite** (`OrphanGCTests`, 4): enumerate scope (ignores thumbnails/empty), reaps
  orphans + thumbnails, keeps referenced/shared, no-op when all referenced / empty store.
- **App wiring** (`AppUndoTests`, +2): delete→undo→redo restores membership + order, and
  **delete does not reap in-session** (a byte-backed blob is still present after delete,
  before undo, and after undo).

## Verification

- `swift test`: AtelierCore **342**, AtelierIngestion **133** — green.
- `xcodebuild test -only-testing:AtelierRefsTests` → **TEST SUCCEEDED**.

## Migration notes

None. No schema / wire / migration change — `deleteAssets` keeps its signature and
behavior; the new methods are additive; the backup holds records, not bytes.

## Supersedes

The "asset DELETE undo deferred" note in changelog 139 / 033-plan open-Q1 — delete is now
undoable. The pre-destructive snapshot remains the coarse net for anything outside the
in-session undo stack.
