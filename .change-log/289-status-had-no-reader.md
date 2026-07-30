# 289 — the status line had no reader

## Summary

A consistency audit of the whole app turned up a feedback channel that was writing
into nothing. `IngestionModel.status` had **18 write sites and zero readers**: it was
rendered by the toolbar, 006 removed the toolbar, and the writes stayed behind.

Everything that reported itself through it had been silent ever since:

| Message | What the user saw |
| --- | --- |
| "Couldn't read that drop — no image, file, or image URL." | nothing |
| "Deleted space “X.”" | nothing |
| "That collection has no items to seed a space." | nothing |
| "Imported 3, 1 failed." | nothing |
| "Restored 4 items." / "Restored space “X.”" | nothing |
| "Snapshot saved." / "Diagnostics exported." | nothing |
| "Capture token regenerated — re-pair the extension." | nothing |

`SpaceModel.importAndPlace` documented the consequence without noticing it: a board
drop that yields no assets "is a silent no-op (the ingest step already reported why
via `status`)". It hadn't.

This is 034's theme 2 (fragmented feedback) finally closed: every model event that
has something to say now goes through the one `ToastCenter`.

## Changes

### `status` → `lastNotice`

A `Notice` event (message + monotonic `seq`) replaces the `String?`. The `seq` is
load-bearing: `onChange` compares values, so two identical messages in a row — two
failed drops — would otherwise register as one event and the second toast would
never appear.

`notify(_:)` publishes one. Every notice shares the `"notice"` coalesce key, so a
sequence describing one operation ("Downloading image…" → "Imported 1.") refreshes a
single card rather than stacking — exactly the semantics the one-line status field
had.

### Every reversible verb now announces

`announceUndoable` was called by 3 of the 8 `registerReversible` sites. The five that
skipped it — **rename**, **move folder**, **reorder**, **move space**, **delete
space** — had a working `⌘Z` the user was never told about. Worst was delete space:
034 batch 1 made it recoverable *specifically* so it could be reversed, and then
showed no way to.

### Where the two overlapped, the notice lost

Delete, remove and move set `status = message` **and** called
`announceUndoable(message)` — the same sentence twice, which only went unnoticed
because one of the two channels was invisible. The undo toast wins (same text, plus
an Undo button), so:

- `applyRemove(assetIDs:from:message:)` → `applyRemove(assetIDs:from:)`
- `applyMoveAssets(_:from:to:message:)` → `applyMoveAssets(_:from:to:)`

Both parameters existed only to say it twice.

### Four messages dropped rather than routed

Not every write deserved a toast, and routing these would have been noise:

- **"Library ready — paste an image or drop a file."** and **"Library ready —
  capture endpoint on 127.0.0.1:N."** — launch state, not action feedback. A toast
  on every single launch. The capture endpoint's state is already shown in the
  Capture pane, and first-run guidance is `OnboardingSheet`'s job.
- **"Failed to open library."** — the `lastError` alert on the very next line already
  says "Failed to open library: \(error)", with the detail.
- **"Importing N…"** — `ImportProgressPill` shows live `completed / total` on both
  the grid and a board. Only the *outcome* is toasted, because it reports failure
  counts the pill never sees.

The endpoint FAILURE is kept and reworded ("Capture endpoint unavailable — port N is
in use."), because it means the extension silently stops working.

### `ModelToastRouting`

The shell's `body` was already at the type-checker's budget — adding one `.onChange`
broke the build with "unable to type-check this expression in reasonable time". The
four model→toast hops move into one `ViewModifier`, following the precedent
`ExportReportToast` set for the same reason.

## Files changed

- `IngestionModel.swift` — `status` → `lastNotice` + `notify(_:)`; 5 new
  `announceUndoable` calls; `message:` dropped from two apply-workers; stale
  `status` references in doc comments.
- `ContentView.swift` — new `ModelToastRouting` modifier; notice route.
- `SpaceModel.swift` — the doc comment that described the bug.

## Migration notes

`IngestionModel.status` no longer exists. Publish user-facing text with `notify(_:)`,
or `announceUndoable(_:)` when the action is reversible — never both for one action.
`IngestionModel.importStatus(imported:failures:undecoded:)` keeps its name (it builds
a sentence, and 4 tests call it).

## Verified

`xcodebuild build` succeeds; `-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`.

## Pre-existing failure, not from this change

`AtelierRefsUITests.testLaunchAndNavigateShell` fails at line 39, "Sweeps toolbar
entry missing". There is no app-level Sweeps button — Sweeps opens from the Capture
pane (`AppShellView.swift:264`). The test's own comment calls these "app-level
toolbar affordances (former tabs)", so it is asserting against the same toolbar whose
removal orphaned `status`. Left alone here; it wants its own fix.
