# 226 · spaces — AppKit outline list with drag reorder + shared skeleton

## Summary

Brought the Collections sidebar's add + arrange functionality to Spaces, and
unified how the two are built. Spaces were pure SwiftUI (`ForEach` of buttons,
fixed `created_at DESC` order, no reordering); they are now an AppKit
`NSOutlineView` — a flat sibling of the Collections tree — with **live drag
reorder**, inline draft creation, and asset drops onto rows.

Both trees now render through ONE shared set of AppKit primitives, so a
row/cell/draft/selection change lands in both at once.

- **New order**: spaces gain a persisted `sort_index` (manual order). A newly
  created space **appends at the bottom** (parity with collections). The manual
  order applies **everywhere** — the sidebar AND the Home "Spaces" cards share
  one order (`listSpaces` + `spaceStackPreviews`).
- **Shared skeleton**: `SidebarOutlineView`, `SidebarRowView`, `SidebarCell`,
  `SidebarDraftCell`, and a renamed `SidebarBlockMenuItem` were extracted from
  `CollectionsOutlineView.swift` into `SidebarOutlineKit.swift`. The
  collections coordinator keeps its tree machinery; spaces get a thin flat
  coordinator. No behavior change for collections.

## Files changed

### Data / persistence (AtelierCore)
- `Domain/Space.swift` — add `sortIndex: Int` (+ `sort_index` CodingKey, default 0).
- `Persistence/Migrator.swift` — new **v15**: `ALTER TABLE space ADD sort_index`,
  dense back-fill reproducing the prior `created_at DESC, id` order, `+` index.
- `Services/AppServices.swift` — `createSpace` appends; new `moveSpace(id:index:)`;
  `deleteSpace` / `deleteSpaceRecoverable` close the gap; `restoreDeletedSpace`
  reinstates the former slot; `listSpaces` + `spaceStackPreviews` order by
  `sort_index`; new `spaceIDsOrdered` / `applyDenseSpaceOrder` helpers.

### Model (AtelierRefs)
- `IngestionModel.swift` — undoable `moveSpace(id:index:)` + `applyMoveSpace`
  (inverse restores the old slot); `applySpaceDrop`.

### Drag / routing / view (AtelierRefs)
- `SpaceDragPayload.swift` (new) — `com.ref-atelier.space-id` payload + `SpaceDrop`.
- `SpaceTargets.swift` (new) — pure flat reorder router + manual-order comparator.
- `SidebarOutlineKit.swift` (new) — the shared AppKit primitives.
- `SpacesOutlineView.swift` (new) — flat `NSViewRepresentable` + coordinator.
- `CollectionsOutlineView.swift` — primitives moved out; menu items use
  `SidebarBlockMenuItem`.
- `SidebarView.swift` — spaces section now hosts `SpacesOutlineView`; removed the
  SwiftUI draft row / `treeRow` / `RowDropModifier`; added a Space rename alert.
- `Info.plist` — declare the `com.ref-atelier.space-id` exported UTType.

### Tests
- `SpaceDropRoutingTests.swift` (new), `ServicesSpaceOrderTests.swift` (new),
  `MigrationTests.swift` (v15 back-fill + committed-identifier list),
  `ServicesSpaceTests.swift` (`listSpaces` now asserts append order).

## Migration notes

- **v15 is additive + back-filled**; existing installs keep their current
  newest-first arrangement (newest → `sort_index` 0). No data loss.
- **Behavior change**: a newly created space now appears at the **bottom** of the
  list (was top). Existing spaces are unaffected until reordered.
- `MigrationAppendOnlyTests.committedIdentifiers` now includes `"v15"` — do not
  edit the v15 body once shipped (append-only migrations).
