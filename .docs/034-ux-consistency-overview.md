# 034 — UX consistency & safety pass (overview)

Synthesis + decisions for a cross-cutting UX review of AtelierRefs. Kicked off by
one reported bug (Back showed the wrong collection's items) and widened into a
survey of every interaction surface. This doc is the index: the systemic themes,
what shipped in the first batch, and the backlog with priorities.

## Systemic themes

Three gaps recur across the app; fixing each once removes many symptoms.

1. **Inconsistent destructive-action protection.** Asset delete is the gold
   standard — a shared confirmation dialog (`ContentView`) plus a recoverable,
   `⌘Z`-undoable delete (`IngestionModel.confirmPendingDeletion`). Several other
   destructive actions had neither: **space delete** (instant *and* unrecoverable),
   bulk-sweep cancel, and element delete.
2. **Fragmented feedback.** Success/'error signals scatter across three channels —
   a blocking `.alert` (errors), a transient toolbar `status` string (most
   successes), and toasts (capture batches only, one action type: `.jump`). There
   is no unified "action → toast with **Undo**" surface even though undo is broadly
   implemented, so the safety net is invisible at the moment it matters.
3. **Keyboard/mouse parity holes** in the three highest-traffic surfaces: no tool
   shortcuts on the Space board, no keyboard/mouse zoom in Item Detail (pinch-only),
   and no keyboard scattered multi-select in the grid.

A fourth, smaller pattern: **failure states silently collapse into empty/normal
states** — Search's `catch { results = [] }` and the library picker discarding
picks — hiding errors and data loss from the user.

## Batch 1 — shipped (changelog 146)

Focused on the data-loss risks + cheap consistency guards:

| Area | Change |
|------|--------|
| **Space delete** | Now confirmed *and* undoable. New `DeletedSpaceBackup` + `deleteSpaceRecoverable`/`restoreDeletedSpace` in `AppServices` (mirrors the asset-delete backup); `IngestionModel` gains `pendingSpaceDeletion` + `confirm/cancelSpaceDeletion` registering a reversible undo; `ContentView` hosts the shared confirmation dialog. |
| **Search errors** | `LibrarySearchModel.queryFailed` distinguishes a failed query from a genuine "no results" — the results view shows a distinct error state instead of a false empty. |
| **Add from Library** | Picks now **accumulate across collection switches** (`picked: [UUID: Asset]`) instead of being silently cleared; added a per-collection **Select All**. |
| **Element inspector** | Commits pending edits on outside-click dismiss (was: discarded silently), guarded so Done/Delete don't double-write. |
| **Bulk sweeps** | Sweep **Cancel** and **Turn Off Bulk Import** now confirm before acting. |
| **Name guards** | New/Rename for spaces, collections, and subfolders disable their commit button on an empty/whitespace name. |

Prior fix (changelog 145): Back button reloads collection items via the nav path
(the reported bug) — the nav path is now the single owner of "which collection is
live," so push *and* pop reload.

## Batch 2 — shipped (changelog 147)

Closes theme 3 (keyboard/mouse parity) for two of the three high-traffic surfaces:

| Area | Change |
|------|--------|
| **Item Detail zoom** | Zoom/pan lifted out of `ZoomableImage` into `ItemDetailView`; top-bar zoom-out/percentage/zoom-in controls (image only) + `⌘−`/`⌘+`/`⌘=`/`⌘0`. Pinch + double-click-to-fit still work and share the state; resets to fit on prev/next. |
| **Space tool shortcuts** | **V** Select / **F** Frame / **T** Text via hidden shortcut buttons behind the picker; a focused text field still takes plain keys first. |

## Batch 3 — shipped (changelog 150)

Closes theme 2 (fragmented feedback): the unified action+Undo toast.

| Area | Change |
|------|--------|
| **Unified "action + Undo" toast** | `ToastAction` gains `.undo(undoToken:)`; delete / remove / move publish a `lastUndoableAction` event that the shell posts as a coalesced "…— Undo" toast. The button is guarded by the monotonic `undoToken` (LIFO-safe): a superseded toast no-ops instead of reversing the wrong action. This also delivers the **Remove-from-Folder** feedback the backlog wanted (it flows through the same toast). |
| **Keyboard scattered multi-select** | New `GridSelectionAction.toggleLead`, bound to **X** on the focused grid: toggles the cursor cell in place. Arrows move the cursor without touching the set, so X builds a discontiguous selection keyboard-only. |

With batch 3 the **P1 backlog is clear** — all three systemic themes (destructive-action
safety, unified feedback, keyboard/mouse parity) are closed. What remains is P2 polish.

## Backlog (priority order)

**P2 — discoverability & polish**
- ~~Search results grid lacks the main grid's selection/keyboard/context-menu
  model~~ — **shipped (changelog 153):** multi-select (`GridSelection` reuse) +
  batch context menu (Add to Collection / Delete / Reveal), `⌘A`/`Esc`/`Return`/
  `Delete` keys. Arrow-cursor + marquee deferred (adaptive grid, no analytic frames).
- Bulk "Failed N" is a dead-end — no list/reason/retry.
- ~~Onboarding: no live pairing confirmation; "three steps" copy over four steps~~
  — **shipped (changelog 154):** step 4 → non-numbered outro (copy now truthful),
  live endpoint dot + first-capture confirmation, redacted token placeholder.
- Space tiles: no z-order (bring-to-front / send-back) controls.
- "Snapshot Now" has no in-progress feedback; snapshot list is read-only (no size,
  no manual prune).
- ~~Loading flashes empty states (Spaces list, onboarding token row)~~ — **shipped
  (changelog 154 + 155):** onboarding token redacts; Spaces list shows a skeleton
  until the first load, not a false "No spaces yet".

## Notes

- Blobs/assets are never touched by space delete — only placements — so restore is
  a verbatim re-insert of the `Space` row + its `SpaceItem`s, tolerant of a cover
  asset or placed asset deleted in the meantime.
- Undo for space delete uses the same `registerReversible` ping-pong +
  `enqueueUndoable` serial write chain as asset delete, so it interleaves correctly
  with live edits.
