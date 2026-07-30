# 299 — Backup folder target (008 · H4)

The off-device backup destination: pick a folder, remember it across launches,
say plainly when it can't be reached. Plan: `.docs/068-backup-portability-plan.md`.
The copy engine that uses it is H5 — see "Deliberately not here" below.

## Summary

- **`BackupFolderPanel`** (new) — the `NSOpenPanel` directory picker, mirroring
  `ImportFilesPanel`: sheet on the key window, `runModal()` fallback, thin on
  purpose. `canCreateDirectories` is on, because "make a new folder for this" is
  the common first run and bouncing the user to Finder for it is silly.
- **`BackupTarget`** (new) — the rules and the words, AppKit- and SwiftUI-free so
  every bit is unit-testable. Same split as `CaptureCopy` (297), which the plan
  doc now names as the pattern for this section.
- **`IngestionModel`** owns the target: `backupFolder` (a `StoredFolderAccess`
  from F2), plus published `backupFolderURL` / `backupFolderMessage` and
  `setBackupFolder(_:)` / `clearBackupFolder()` / `refreshBackupFolder()`. On the
  model, not the view, because the Settings window can be closed and reopened at
  any time and view state would go with it.
- **Settings ▸ Backup** — folder row, "Choose Folder…" / "Change Folder…",
  "Clear", a warning line only when something is actually wrong, and the standing
  explainer. Re-resolves `.onAppear`: the window outlives any single visit and a
  drive can be unplugged between two of them.

## The containment guard

The one rule with teeth: a target that **is** the library, or sits inside it, is
rejected. Backing the library up into itself copies blobs into the tree being
enumerated, and defeats the entire point — an off-device copy exists to survive
losing this Mac.

The obvious implementation is wrong. `"/Volumes/Disk/Atelier2".hasPrefix("/Volumes/Disk/Atelier")`
is `true`, so a string-prefix check rejects a perfectly good sibling folder.
`isSelfOrDescendant` compares **path components**, after resolving symlinks and
standardizing (so `Atelier/blobs/..` and a symlinked volume path can't slip past
either). Case-insensitive, matching APFS's default — stricter than a
case-sensitive volume would require, which is the safe direction: the cost is
re-picking a folder, against a backup that eats itself.

Note the *parent* of the library is deliberately allowed. Backups land in
`<target>/<library-id>/`, so a parent directory never recurses.

## Deliberately not here

**No "Back Up Now" button and no last-run status**, though both appear in the
plan's H4 sketch. There is no copy engine until H5, and a button that does
nothing — or a status line reporting on runs that cannot happen — is worse than
an absent one. The section is shaped so both drop in without rework.

## Also

Pure value types marked `nonisolated`, matching the codebase convention
(`SpaceTargets`, `ExportDefaults`, `GridSelection`): `BackupTarget`,
`BackupTargetRejection`, `CaptureCopy`, and `FolderAccessError`. The last one
matters beyond tidiness — H5's engine throws it across actor boundaries, and the
app target's MainActor-by-default would have isolated it to the main actor.

## Files changed

- `AtelierRefs/AtelierRefs/BackupFolderPanel.swift` — new.
- `AtelierRefs/AtelierRefs/BackupTarget.swift` — new.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — target state + the three verbs.
- `AtelierRefs/AtelierRefs/SettingsView.swift` — Backup section; form height
  380 → 460.
- `AtelierRefs/AtelierRefs/CaptureTokenViews.swift`, `FolderAccess.swift` —
  `nonisolated`.
- Tests: `AtelierRefsTests/BackupTargetTests.swift` (new, 15 tests).

## Test results

`AtelierRefs` scheme — **TEST SUCCEEDED**, 934 test cases.

## Migration notes

No schema or on-disk change. The bookmark lives under
`AtelierBackupFolderBookmark` in `UserDefaults` (unchanged from F2); no target is
set until the user picks one, and nothing reads it yet beyond the Settings
display. The entitlement it depends on
(`com.apple.security.files.bookmarks.app-scope`) shipped with F2 and is asserted
by `scripts/verify-release.sh` check 5.
