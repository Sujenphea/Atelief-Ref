# 211 · Shared name-entry alert (043 Phase E · 6A/8A)

## Summary

Collapses the eight near-identical "New / Rename" name prompts scattered across
the collection surfaces into one reusable modifier. No behavior change — a pure
DRY consolidation so the field, the blank-guard, and the dismiss-clear live in
ONE place instead of being hand-copied per call site.

## What changed

- **`View.nameEntryAlert(_:isPresented:text:confirmLabel:onConfirm:onCancel:)`**
  (new · `NameEntryAlert.swift`, 043 · 6A) — owns the `TextField("Name")`, the
  confirm button disabled while the trimmed text is blank, and clearing the field
  on both confirm and cancel. Each call site now passes only its title, confirm
  label, and confirm/cancel intents.
- Migrated all eight prompts to it:
  - `SidebarView` — New Collection/Subfolder, Rename Collection, New Space.
  - `CollectionView` — New Subfolder, Rename Collection.
  - `CollectionsGalleryView` — Rename Collection, New Subfolder, Rename Space.

## 8A — already satisfied (no change)

The "Move to ▸" reparent submenu was already unified: both SwiftUI call sites
(`CollectionsGalleryView`, `CollectionView`) render the shared
`CollectionMoveToMenu`, and the sidebar outline view's is a native `NSMenu`
(a different framework — it shares the target computation
`CollectionTargets.folderMoveTargets`, which is the part that matters). No
remaining duplication to remove.

## Notes

Rename pre-seeds the field (`renameText = folder.name`) at trigger time and
re-seeds on every open, so the modifier clearing the field on dismiss is safe.
The entered name is passed to `onConfirm` raw — trimming/validation stays the
service's job (`Validation.collectionName`). Verified by app build; the modifier
is a declarative `.alert` wrapper (not unit-testable without UI tests).
