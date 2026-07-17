# 033 — Production-Ship · Plan (execute 010 through public listing)

> Implementation plan for [010-production-ship](./feature-todo/010-production-ship.md).
> Scope confirmed **Full 010 → public listing** (user, 2026-07-17). Group 1's headline
> item — 008 H1–H3 backup/snapshot/restore/integrity — **already shipped** (changelogs
> 099–103; `SnapshotManager.swift`, `AppServices.snapshot(to:)`/`integrityCheck()`,
> pre-migration hook in `LibraryDatabase.swift`, `SnapshotsSheet` + `SnapshotCommands`).
> This plan covers everything 010 still leaves open, in the doc's own three tiers.

## Settled decisions (this plan)

- **Scope:** full public path — groups 2, 4, 5 are all in.
- **Undo v1 = the 5 destructive verbs only** (delete, remove-from-collection, move,
  reorder, rename). **Ingest/import is NOT undoable** (010 Q5). Snapshots remain the
  coarse net for un-import.
- **Updates: Sparkle 2 first** (010 Q2), direct-download channel; App Store deferred.
- **Crash reporting: MetricKit + user-initiated diagnostics export only** (010 Q4) —
  no third-party reporter (local-first ethos).
- **Deployment target: audit, don't guess** (010 Q3) — a `-target` build pass fixes the
  floor at the lowest OS whose APIs the code actually uses; 26.5 is a placeholder.
- **Undo-of-delete blob recovery:** reuse the restore flow's best-effort Trash recovery
  (see Phase 1 · Undo · "delete wrinkle"); the preDestructive snapshot is the guarantee.

## Current state delta (verified 2026-07-17)

| 010 gap | State now |
|---|---|
| Backup/snapshot/restore/integrity (G1) | **DONE** — full stack, well-tested |
| Commit hygiene / dirty tree (G15) | **Resolved** — working tree clean |
| App-level undo (5 verbs) | **Missing** — `UndoManager` only in `SpaceModel` (canvas placement) |
| CI | **Missing** — no `.github/` |
| App icon | **Missing** — `AppIcon.appiconset` = `Contents.json` only |
| Signing/notarize/release lane | **Missing** — dev signing only (team `L25247V6JG`, hardened runtime on) |
| Sparkle updates | **Missing** |
| Onboarding / first-run | **Missing** |
| Settings scene (⌘,) | **Missing** |
| Menu bar Edit/View + undo/redo | **Partial** — only `BackCommand` + `SnapshotCommands` |
| Extension icons + zip build | **Missing** |
| Extension↔app version handshake | **Missing** — `/health` returns `{status:"ok"}` only |
| Scale pass (10k+) / a11y / diagnostics export / localization | **Missing** |

---

## Phase 1 — Now (protects everything after) · effort **S–M**

### 1.1 App-level Undo for the 5 destructive verbs

**Seam.** One `AppUndo` coordinator owned by `IngestionModel`, holding a single
`UndoManager`. Each destructive verb, after its `AppServices` write succeeds, registers
an **id-based** inverse closure (never index-based — server ingests interleave, 010 risk).
Wire it to the menu with a standard `CommandGroup(.undoRedo)` reaching the model through
the existing `@FocusedValue(\.ingestionModel)` pattern (mirrors `SnapshotCommands` in
`AtelierRefsApp.swift`). Undo/redo therefore work from ⌘Z/⇧⌘Z and the Edit menu app-wide,
not just inside a space.

**The 5 verbs → inverses** (all in `IngestionModel.swift`):

| Verb | Method | Inverse |
|---|---|---|
| rename collection | `renameFolder(id:to:)` :589 | capture prior name → `renameFolder(id:to:old)` |
| move collection | `moveFolder(id:toParent:)` :603 | prior parent → re-move |
| reorder grid | `reorderItems(movingAssetIDs:toIndexOf:)` :766 | prior `setGridOrder` list → restore order |
| remove from collection | `removeFromFolder(assetIDs:)` :979 / `removeSelectedFromFolder()` :1019 | `addAssets(ids,to:)` + restore manual order |
| move to collection | `moveToCollection(assetIDs:to:)` :992 | remove from target, `addAssets` back to source(s), restore order |
| delete collection | `deleteFolder(id:)` :595 | recreate collection + re-add memberships/order |
| delete asset(s) | `deleteAssets(_:) -> [OrphanedBlob]` (Core :649) | **see wrinkle** |

**The delete wrinkle.** `deleteAssets` returns `[OrphanedBlob]` and `MediaReaper` moves
those blobs to **Trash**. Undoing a delete must re-insert the asset rows AND recover the
bytes. Approach:
- Re-insert rows from an in-memory pre-delete snapshot of the affected `Asset`/membership/
  order records (captured in the verb before the write).
- Recover blobs **best-effort from Trash**, reusing the exact recovery helper the restore
  flow already uses (`reconcileOrphanedKnownItems` neighborhood). If Trash was emptied,
  the row restores in a degraded/media-less state and a toast says so — the preDestructive
  snapshot (already taken at `IngestionModel.swift:1053`) is the hard guarantee.
- **Defer the reaper within the undo window** (recommended refinement): don't trash blobs
  until the undo entry is evicted from the stack, so an immediate undo is lossless. If this
  proves fiddly, ship best-effort-from-Trash first and add deferral as a follow-up.

**Files:** new `AppUndo.swift`; edits to `IngestionModel.swift` (register inverses in each
verb), `AtelierRefsApp.swift` (`.commands` += `CommandGroup(.undoRedo)`). `SpaceModel`'s
own `UndoManager` stays as-is (canvas placement is a separate focus context).

**Tests:** per-verb round-trip (do → undo → rows/order equal; do → undo → redo → equal),
id-based-inverse correctness under an interleaved ingest, delete-undo with Trash present
and Trash-emptied (degraded path), reorder-undo restores exact manual order. Effort **M**.

### 1.2 CI

GitHub Actions macOS runner on every push/PR: `swift test` (×4 packages: Core, Ingestion,
Server, +AtelierBackup if it lands) + `node --test` in `extension/` + `xcodebuild build`
for the SwiftUI app target (compile-proof — the app target isn't SPM-tested). Quarantine
a flake rather than un-gating (G5). **Files:** `.github/workflows/ci.yml`. Effort **S**.

---

## Phase 2 — Before first outside tester · effort **M** (many small tasks)

### 2.1 App icon
Produce the 10 mac slots (16–512 @1x/2x) the `Contents.json` already enumerates; drop PNGs
into `AppIcon.appiconset`. Design asset is the only real cost. Effort **S**.

### 2.2 Signing + notarization release lane
`scripts/release.sh`: Developer ID Application signing → hardened runtime (already
`ENABLE_HARDENED_RUNTIME=YES`) → `notarytool submit --wait` → `stapler staple`. Audit the
distribution entitlements vs the dev `AtelierRefs.entitlements` (sandbox + network
client/server + user-selected read-write for backup are the real ones). **Deployment-target
audit** here: `-target` build sweep to fix the floor. Effort **M**; budget a day of signing
friction. **Files:** `scripts/release.sh`, `ExportOptions.plist`, README release section.

### 2.3 Sparkle 2 auto-update
Add Sparkle 2 via SPM; sandbox requires the **XPC installer** path (`Downloader` +
`Installer` XPC services, well-trodden but fiddly). Generate an EdDSA key, host an
`appcast.xml`, sign updates in `release.sh`. **Files:** SPM dep, `SUFeedURL`/`SUPublicEDKey`
in Info.plist, XPC service targets, `appcast.xml`, release-script signing step. Effort **M**.

### 2.4 Onboarding / first-run sheet
First-launch sheet: install extension → pair token (flow exists, just undiscoverable) →
capture something → drop-zone tour. Gate on a `didCompleteOnboarding` flag in app storage;
reachable later from Settings. Empty states already exist. **Files:** `OnboardingSheet.swift`,
a flag read in `ContentView`/`AppShellView`. Effort **S–M**.

### 2.5 Settings scene (⌘,)
SwiftUI `Settings { }` scene: token regenerate/copy (`CaptureTokenStore`), library location
+ size, backup target + retention (008 H4/H5 when they land), onboarding replay, future
per-app toggles. Unblocks several docs' UI homes. **Files:** `SettingsView.swift`, add
`Settings { SettingsView() }` to `AtelierRefsApp.body`. Effort **S–M**.

### 2.6 Menu bar basics
Standard **Edit** (undo/redo from 1.1; cut/copy/paste/select-all wired to grid + 032
selection) and **View** (sort modes from 007 search-sort, if present) menus; window
restoration. **Files:** `AtelierRefsApp.swift` `.commands`, new `EditCommands`/`ViewCommands`
reaching the model via `@FocusedValue`. Effort **S**.

---

## Phase 3 — Before public listing · effort **M** (measurement-driven)

### 3.1 Extension icons + packaging
16/32/48/128 icons; `icons` key in `manifest.json`; `npm run build` → `zip` packaging step
in `package.json`. **Files:** `extension/icons/*`, `manifest.json`, `package.json` scripts.
Effort **S**.

### 3.2 Extension↔app version handshake
Extension sends its `manifest.json` version on requests; `/health` returns `{min,max}`
supported extension versions (`CaptureServer.swift:142` currently returns `{status:"ok"}`);
mismatch → explicit "update the extension/app" UI instead of silent drift. Pin the extension
ID in `CaptureAuth` once the Web Store ID is stable (G17). **Files:** `CaptureServer.swift`,
`endpoint.js`/`sw.js`, `CaptureAuth`, a small mismatch banner. Effort **S–M**.

### 3.3 Web Store policy + listing (G14)
Privacy policy page; **unlisted Web Store listing first** (real autoupdate, low review
surface). The bulk Instagram/X sweep is the one genuinely unpredictable review gate — the
unlisted channel de-risks timeline, not the policy question itself. Effort **S** (+ external
review latency).

### 3.4 Scale validation (10k–50k)
Scripted seeding of a large TempLibrary; measure grid scroll, FTS latency, gallery-cover
query, reaper sweep; run the long-deferred **canvas Instruments** pass. Fix what measurement
finds. **Files:** `scripts/seed-large-library.swift` (or a test-only seeder). Effort **M**.

### 3.5 Accessibility
VoiceOver labels on grid cells/cards/rail; keyboard-only operation audit (032's hover-circle
has a ⌘-click equivalent — verify VoiceOver exposes selection state); contrast pass. Effort
**M**.

### 3.6 Diagnostics + logging
Adopt `os.Logger` consistently (only 3 files log today); MetricKit subscriber; an **"Export
Diagnostics"** action (recent logs + DB stats + versions — **never library content**) living
in Settings. **Files:** logging sweep across app/services, `Diagnostics.swift`,
`MetricKitSubscriber.swift`, Settings button. Effort **M**.

### 3.7 Localization decision
Decide **English-only v1 explicitly** (recommended); keep user-facing strings in a String
Catalog so the door stays open. Effort **S** (mostly the catalog migration).

---

## Sequencing & dependencies

1. **1.1 Undo → 2.6 Edit menu** (menu surfaces undo/redo — do undo first).
2. **2.5 Settings → 3.6 Diagnostics export** and **onboarding replay** (Settings is their home).
3. **2.2 signing lane → 2.3 Sparkle** (Sparkle signs artifacts the release lane produces).
4. **3.2 handshake ID-pin waits on 3.3** (real Web Store ID before pinning `CaptureAuth`).
5. Phase 3 quality items (3.4/3.5) are measurement-gated — schedule after the app is
   installable so they run against a real build.

## Risks & edge cases

- **Undo × async captures:** inverses must be id-based; a server ingest mid-undo-stack must
  not corrupt an index-based inverse (covered by design + the interleave test).
- **Undo-of-delete after Trash empty:** degraded restore is honest, not silent — toast + the
  preDestructive snapshot as the real net.
- **Sparkle + sandbox** needs the XPC installer path — fiddly; budget the day.
- **Deployment-target lowering** may surface API-availability breaks — the `-target` sweep
  gates the promise.
- **Web Store review of the bulk sweep** — the one unpredictable external gate; unlisted
  channel de-risks timeline only.

## Test strategy

`node --test` + `swift test` green throughout; new suites: `AppUndoTests` (per-verb
round-trips + interleave + delete-Trash matrix), CI itself as the meta-guard, handshake
min/max compatibility table, seeded-library scale measurements recorded (not asserted, to
avoid flake), a11y audited manually against a checklist. CI (1.2) makes the ~866 Swift +
~382 JS existing tests non-optional on every push.

## Open questions (remaining)

1. Undo-of-delete: ship best-effort-Trash-recovery first, or invest in reaper-deferral within
   the undo window up front? (Recommend: best-effort first, deferral as follow-up.)
2. Sparkle appcast hosting location (same domain as privacy policy?).
3. String Catalog migration now (3.7) or defer until a second locale is actually planned?
