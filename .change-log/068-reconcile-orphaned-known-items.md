# 068 — Reconcile orphaned known items (enforce known ⟺ blob present)

Phase 9 live testing surfaced a latent drift: a full library clear-all left **2
`job_item` rows still marked `ingested`** whose `blob_hash` had **zero backing assets**.
They dated to before the delete-forget feature ([065](./065-delete-forgets-ledger.md))
shipped — their assets were deleted when no forget existed, so the ledger never
un-marked them.

## The gap

`deleteAssets`'s forget is **reactive** — it drops a blob's ledger rows only inside the
same transaction that orphans the blob. Any asset removed by **another path** (a delete
predating 065, or any future non-`deleteAssets` caller) strands its `job_item` as
stale-"known". Because known-sources means "the bytes are in the store", a later sweep
then **dedup-skips that source forever** despite the bytes being gone — so it never
re-imports. Same class of gap [067](./067-reconcile-abandoned-sweeps.md) closed for
zombie `open` jobs.

## Fix

**`AppServices.reconcileOrphanedKnownItems()`** (AtelierCore) — a proactive GC sweep:
forgets every `job_item` whose `blob_hash` has no backing `asset`, then recomputes the
`ingested_count` of each job that lost rows. Reads first; only opens a write when
something is actually stale. Returns the job ids reconciled. Wired into
`IngestionModel.bootstrap()` right after the [067](./067-reconcile-abandoned-sweeps.md)
open-job reconcile.

The forget + count-recompute body is now a shared private helper
**`forgetOrphanedKnownItems(_:in:)`** that both `deleteAssets` (reactive) and the new
reconcile (proactive) call — removing the duplication that would otherwise let the two
paths drift.

## Tests (`ServicesDeleteTests.swift`, +4)

- Forgets a known item whose blob has no backing asset; recomputes count 1 → 0.
- Spares a known item still backed by a live asset (nothing orphaned).
- Repairs an asset removed OUTSIDE `deleteAssets`, **per-job scoped**: a job with one
  live + one orphan item drops only the orphan (count 2 → 1); an unrelated job is
  untouched.
- No-op (empty result) when every known item is backed.

## Verified

`swift test` AtelierCore **194** (+4); `xcodebuild -scheme AtelierRefs` BUILD SUCCEEDED.
The live 2-row straggler that surfaced this was cleaned in the same session (the
sandbox library is now fully empty — every previously-swept board re-imports fresh).
