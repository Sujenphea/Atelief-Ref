# 066 — Bulk import: stable checkpoint key (cross-run resume) + cleanup

Phase 9 live testing ([.docs/019](../.docs/019-bulk-import-verification.md) §T4)
found that kill-mid-sweep + re-run did **not** resume from the saved checkpoint. The
engine's resume logic was correct (`runSweep` reads `storage.load(checkpointKey)` at
startup), but the key was job-scoped:

```
checkpointKey = `atelier:bulk:${jobId}`     // and every run opens a NEW job
```

So a killed run saved its cursor under jobId-A, but the re-run opened jobId-B and read
`…:jobId-B` → nothing → it re-enumerated from page 1 (still correct via known-sources
dedup-skip, just wasteful — re-fetches every prior page, more rate-limit exposure). It
also **leaked** an orphaned checkpoint per run (7 had accumulated).

## Fix (`extension/src/bulk-controller.js`)

- **`sweepCheckpointKey({platform, scope, input})`** → `atelier:bulk:${platform}:${target}`
  where `target` = the board id (`input.boardId`), else the `scope`, else `default`. A
  board / bookmarks-set now resumes across runs because the key is stable.
- **Cleanup on completion** — a clean finish `storage.remove(checkpointKey)`s the
  checkpoint (so a later re-sweep starts fresh and picks up items added since); a
  **halt KEEPS it** (resumable). Added `remove` to `makeChromeStorage`.
- The engine is unchanged — it resumes from whatever key it's handed.

## Tests (`bulk-controller.test.js`, +4)

- `sweepCheckpointKey` precedence (boardId > scope > default).
- Checkpoints save under the stable key (never the jobId) and are removed on complete.
- A pre-seeded checkpoint's cursor is read back into `enumerate({cursor})` (resume).
- A halt keeps the checkpoint (not removed).

## Verified

- **Live (T4):** kill test3 mid-sweep → storage held exactly
  `atelier:bulk:pinterest:1084663960195879466` (the stable key); re-run resumed and
  completed → key gone. No jobId-keyed entries.
- **Unit:** `npm test` **172** (+4).

## Note

The 7 pre-existing jobId-keyed checkpoints from the old scheme are inert under the new
keying; they were cleared from `chrome.storage.local` during the T4 run.
