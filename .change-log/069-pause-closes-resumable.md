# 069 — Pause closes a sweep RESUMABLE (not a dead "Stopped" job)

Phase 9 T6 live testing exposed a bug: pressing **Pause** in the app mid-sweep left a
job the UI showed as **"Stopped"** with **no Resume button** — Pause was un-resumable.

## Root cause

The app writes `job.status = paused` when you hit Pause; the sweep loop reads that off
the per-item relay reply (7A) and halts. But the content-script controller then always
POSTed `/jobs/{id}/complete` with **`status: "halted"`** — clobbering the `paused` the
app had just set. `BulkSweepsView` groups `.halted` with `.complete` as terminal
("Stopped"), so no Resume control renders. The controller's own comment already said
*"a halt pauses the job (resumable)"*, and the server's `/complete` decoder already
accepted `"paused"` — the resumable path was designed end-to-end but never sent.

A single static status can't be right: the correct close depends on **why** it halted —
a **Pause** must stay resumable, an explicit **Cancel** must stay terminal, and a
**wall/unreachable** self-halt should be resumable too.

## Fix

Thread the halt reason through:
- **`bulk-engine.js`** — `classifyIngestResult` surfaces the observed app intent as
  `appStatus` (`"paused"` | `"halted"`) on the `saved`+halt case; `runSweep` remembers
  it and returns it as **`result.haltStatus`** (`null` for a wall/unreachable self-halt).
- **`bulk-controller.js`** — maps the close status: clean → `complete`;
  `haltStatus === "halted"` (Cancel) → `halted`; otherwise (Pause **or** wall) →
  **`paused`** (resumable). Checkpoint handling follows: cleared on a TERMINAL close
  (clean finish **or** Cancel — a re-sweep starts fresh from page 1), kept only for a
  RESUMABLE halt so the next run continues from the cursor.

## Tests (extension, node --test → 175 pass)

- Engine: `classifyIngestResult` returns `appStatus` (null / paused / halted);
  `runSweep` surfaces `haltStatus` (null on self-halt, `"paused"` on app pause).
- Controller: an app **Pause** closes `paused` (the load-bearing fix) and KEEPS the
  checkpoint; an app **Cancel** closes `halted` and CLEARS the checkpoint; a
  wall/unreachable self-halt closes `paused` (resumable).

## Verified

`node --test` **175 pass / 0 fail**. Requires an **extension reload** in
`chrome://extensions` to take effect (content-script change). Live T6 re-test pending.
