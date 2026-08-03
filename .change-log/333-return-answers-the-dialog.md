# 333 — Return answers the confirmation dialog

## Summary

The delete confirmation could not be answered from the keyboard. Escape cancelled;
Return did nothing at all. Every confirmation dialog in the app had the same hole.

The cause is not a stolen keystroke, a focus problem, or the AppKit grid's `keyDown`
swallowing Return. macOS presents `.confirmationDialog` as an `_NSAlertPanel`, and
SwiftUI **deliberately refuses to make a `role: .destructive` button the default
one** — the panel comes up with `defaultButtonCell == nil`, so Return is bound to
nothing. Escape kept working because the `.cancel` role always takes it.

Measured on the exact button shape (a probe app that presents the dialog, then walks
the panel's `NSButton`s and prints each `keyEquivalent`):

| Buttons | Cancel | Delete | `window.defaultButtonCell` |
|---|---|---|---|
| `.destructive` + `.cancel` (as shipped) | `ESC` | **none** | **nil** |
| same, role dropped | `ESC` | `RETURN` | `"Delete"` |
| `.destructive` + `.keyboardShortcut(.defaultAction)` | `ESC` | `RETURN` | `"Delete"` |

Row two is the diagnostic one: the suppression belongs to the *role*, not to
`confirmationDialog`. A dialog whose primary button had no role already answered
Return; only the destructive ones were mute.

The fix is `.keyboardShortcut(.defaultAction)` on each dialog's primary button,
which restores the binding without touching the destructive styling or Escape.

Apple's reason for the suppression — a stray Return shouldn't destroy data — is
weighed against what these particular actions do. The asset and space deletes move
files to the Trash, leave the blobs on disk for the launch orphan-GC, and register a
⌘Z undo, so the keypress it guards against is recoverable, while a dialog nobody can
dismiss from the keyboard is a cost paid on every single delete. That trade is
recorded at ``ContentView``'s delete dialog; the other sites point back to it.

Two notes on scope:

- `SettingsView`'s library-job dialog passes `role: job.isDestructive ? .destructive
  : nil`, so it answered Return for a *cleanup* job and ignored it for a
  *destructive* one — one dialog, two keyboard behaviours depending on which job
  opened it. It now states `.defaultAction` unconditionally.
- Trigger buttons ("Delete…", "Regenerate Token…") and context-menu items keep their
  roles untouched. They open a dialog rather than commit anything, and they are not
  what Return was reaching for.

## Files changed

- `AtelierRefs/AtelierRefs/ContentView.swift` — asset delete + space delete; the
  mechanism and the trade-off are documented here as the canonical site.
- `AtelierRefs/AtelierRefs/SettingsView.swift` — regenerate pairing token, library
  job, delete largest item.
- `AtelierRefs/AtelierRefs/CollectionsGalleryView.swift` — Home batch delete.
- `AtelierRefs/AtelierRefs/DuplicateReviewSheet.swift` — delete this copy. Worth the
  most here: reviewing near-duplicates is a long run of identical confirmations, and
  reaching for the mouse on each one was the whole cost of the sweep.
- `AtelierRefs/AtelierRefs/SnapshotsSheet.swift` — restore snapshot, delete snapshot.
- `AtelierRefs/AtelierRefs/RestoreBackupSheet.swift` — restore backup.
- `AtelierRefs/AtelierRefs/BulkSweepsView.swift` — turn off bulk import, cancel
  sweep.

## Migration notes

None. Behavioural change only, and only additive: Return now commits the dialog's
primary action where it previously did nothing. Escape and the mouse are unchanged.

Worth knowing when adding a dialog: a `role: .destructive` primary button needs
`.keyboardShortcut(.defaultAction)` or it will silently ship keyboard-unanswerable.
Nothing in the type system or the build catches it.
