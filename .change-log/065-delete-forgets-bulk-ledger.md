# 065 — Delete is forgotten: deleting an asset clears its bulk-import ledger row

Before this change, a bulk-swept asset was "sticky" against re-sweeps: `knownSourceIDs`
(the P14 download-skip set) reads `job_item` rows, which have **no FK to `asset`**, so
deleting the asset left the ledger row intact → a re-sweep skipped that pin/tweet and
never restored it. Requested behavior: **delete means forgotten** — a deleted item
should re-ingest on the next sweep.

## Change (`AtelierCore/Services/AppServices.swift` — `deleteAssets`)

When a delete leaves a blob **orphaned** (no remaining asset references its hash — the
existing reclaimable-blob computation), also delete the `job_item` rows carrying that
`blob_hash`, and recompute each touched job's denormalized `ingested_count` in the same
transaction.

- **Join key is `blob_hash`** — the only column `asset` and `job_item` share
  (`asset.blobHash` == `job_item.blob_hash`, populated on every `ingested`/`deduped`
  item by `recordJobItem`). There is no source-id linkage between the two tables.
- **Keyed on blob-orphaning, not per-asset delete** — deliberately. `knownSourceIDs`
  means "the bytes are in the store"; forgetting exactly when the blob leaves the store
  makes `known ⟺ blob present` an enforced invariant. Consequence: an asset that shares
  its blob with another (identical image, different provenance) stays "known" until the
  **last** copy is deleted — correct under that definition, and it avoids over-forgetting
  an unrelated source's ledger entry.
- **Counter stays drift-free** — `ingested_count` is recomputed from surviving
  `job_item` rows, preserving the same no-drift invariant `recordJobItem` maintains.

## Tests (`ServicesDeleteTests.swift`, +3)

- delete a bulk-ingested asset → its `job_item` is forgotten, `knownSourceIDs` no longer
  lists the source (a re-sweep re-ingests), and `ingested_count` recomputes to 0.
- per-blob semantics: deleting one of two assets sharing a blob leaves the source
  **known** (blob still referenced) and the counter intact.
- deleting a non-bulk asset (no ledger row, unrelated blob) leaves `job_item` untouched.

## Verified

`swift test` AtelierCore **187** (+3) green; `xcodebuild -scheme AtelierRefs` BUILD
SUCCEEDED. No schema/migration change (row deletes only); extension unaffected (it just
consumes `known-sources`).

## UI disclosure

The consent panel (`BulkSweepsView`) gains a bullet making the semantics explicit:
"Re-sweeps skip what you already have. Deleting a saved item forgets it, so a later
sweep can import it again." — so the dedup-skip AND the re-import-after-delete behaviour
are both surfaced before the user enables sweeps.
