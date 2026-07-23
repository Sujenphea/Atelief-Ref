# 205 · Reparent validity predicate — single source of truth (043 Phase B)

## Summary

Extracts the "can this folder be reparented under that one?" rule into ONE pure
predicate, `CollectionTargets.canReparent(...)`, and routes every drag surface
through it (043 · decision 5A). Before this, the self/descendant/cycle check was
reimplemented at each drop site (the sidebar rows, the sidebar un-nest header, the
Home gallery cards); with the coming NSOutlineView coordinator that would have
become a fourth copy. Now there's one rule, exhaustively tested.

Phase B of `.docs/043-nested-collections-ui-plan.md`.

## What changed

- **New predicate** (`CollectionTargets.swift`):
  `canReparent(_ dragged:into:folders:unsortedID:) -> Bool`. Validates STRUCTURE
  only (not no-op-ness): rejects moving the protected Unsorted folder, filing
  under Unsorted, a self-move, and any cycle (`newParent` is `dragged` or a
  descendant of it); `nil` (top level) and same-parent (a reorder) are allowed.
  Cycle-safe via the existing `descendantIDs` walk. The service's `moveCollection`
  keeps its own authoritative cycle check as the backstop; this mirrors it for the
  live drag cursor.
- **Routed through it**: `SidebarView.acceptReparent` (row drop) and the un-nest
  header drop, and `CollectionsGalleryView.CollectionReparentDnD` (now takes
  `unsortedID`). Each drop site's ad-hoc `dragged != target && !descendantIDs(...)`
  guard is replaced by the shared call.

## 7A correction (no change needed)

The review's Issue 7 assumed folder names were stored untrimmed. That was wrong:
`AppServices.createCollection` / `renameCollection` both call
`Validation.collectionName`, which trims whitespace and rejects an empty result.
Names are already trimmed at the service boundary, so 7A required no code change —
flagging the false positive rather than adding a redundant trim at the model layer.

## Tests

- `CollectionTargetsTests` — 9 new `canReparent` cases (10A): into self, into a
  direct child, into a deep descendant, corrupt-cycle termination, into Unsorted,
  moving Unsorted itself, top-level (nil), an unrelated destination, and the
  same-parent reorder (allowed). App build + suite green.

## Notes

No behavioural change to valid drops — this is a de-duplication + hardening pass
that makes the drag rule single-sourced ahead of the NSOutlineView work (Phase C).
