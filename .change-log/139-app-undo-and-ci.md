# 139 — App-level undo/redo + CI (010 · Phase 1)

Executes the "Now" tier of [010-production-ship](../.docs/feature-todo/010-production-ship.md)
(planned in [033-production-ship-plan](../.docs/033-production-ship-plan.md)): app-level
undo/redo for the reversible destructive verbs, and a GitHub Actions CI gate.

## Summary

- **App-level Undo/Redo** on `IngestionModel`, surfaced through the standard **Edit
  menu** (⌘Z / ⇧⌘Z) with live "Undo Rename" / "Redo Move" titles. Covers five
  reversible verbs with **id-based** inverses (never index-based, so a remote capture
  interleaving mid-stack can't corrupt them):
  - **Rename** folder
  - **Move** folder (reparent)
  - **Reorder** grid (restores the exact prior manual order)
  - **Remove** from collection (re-adds + restores prior positions)
  - **Move** to collection (moves back + restores source order)
- Reuses `SpaceModel`'s proven async-undo design verbatim: a serial write chain
  (`enqueueUndoable`) so undo can't reorder ahead of an in-flight write, plus the
  recursive ping-pong (`registerReversible` / `installUndo`) with
  `groupsByEvent = false`. `waitForWrites()` gives tests a settle point.
- **CI**: `.github/workflows/ci.yml` — 4× `swift test` (matrix over AtelierCore /
  AtelierIngestion / AtelierServer / CanvasRenderer), `node --test` + `drift-check` in
  `extension/`, and `xcodebuild test` of the app (`AtelierRefsTests`, UI tests excluded)
  as the SwiftUI compile-proof + unit gate. Runs on every push / PR.

## Not in scope (deliberate)

- **Asset DELETE undo** — deferred (033-plan open-Q1). Reversing the cascading
  `deleteAssets` (sources, memberships, tag links, covers, job ledger, trashed blobs)
  needs a core "undelete" primitive + deferred blob reaping. The **pre-destructive
  snapshot** (008 H3, taken at delete time) remains delete's safety net until then.
- Ingest / import ("un-import") is not undoable (matches the chosen v1 undo scope).

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — undo infrastructure (undoManager,
  undoToken, serial write chain, register/install ping-pong, canUndo/canRedo/undo/redo
  + action names), shared undoable workers, and rewired `renameFolder` / `moveFolder` /
  `reorderItems` / `removeFromFolder` / `moveToCollection`. Added an injectable
  `init(services:store:)` for tests and a `#if DEBUG setItemsForTesting`.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — `CommandGroup(replacing: .undoRedo)`
  with `UndoRedoCommands`, wired to the shared model via `@FocusedValue(\.ingestionModel)`.
- `AtelierRefs/AtelierRefsTests/AppUndoTests.swift` — 7 round-trip tests over a temp
  `AppServices` (rename, move-folder, reorder-exact-order, remove+order, move+order,
  id-based inverse under an interleaved add). Assert against the committed DB truth.
- `.github/workflows/ci.yml` — new CI workflow.

## Verification

- `xcodebuild test -only-testing:AtelierRefsTests` → **TEST SUCCEEDED** (incl. the 7
  new `AppUndoTests` + all pre-existing app tests).
- `xcodebuild build -scheme AtelierRefs` → **BUILD SUCCEEDED**.

## Migration notes

None. No schema, wire, or public-service change — the inverses are composed from
existing `AppServices` verbs (rename/move/add/remove/setGridOrder). The Swift
`CaptureRequest`/contract and DB migrations are untouched.

## Known interactions to watch

- A ⌘Z inside an open Space is still handled by `SpaceModel`'s own (in-view) undo; the
  app-level Edit-menu ⌘Z targets the library model. When both have pending actions the
  precedence is focus-driven — verify in the app during the Phase-2 menu pass.
- Undo/redo of an asset verb focuses the affected folder (sets `selectedFolderID`) so the
  change is visible; sidebar-selection sync for that jump is a Phase-2 shell-polish item.
