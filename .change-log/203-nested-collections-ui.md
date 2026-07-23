# 203 · Nested collections — UI surfacing

## Summary

Nested collections (a collection containing sub-collections) were already
supported end-to-end in the domain, persistence, and service layers, but the UI
barely exposed them: the sidebar was flat, the breadcrumb helper was never
rendered, and the built-and-tested `moveFolder` reparent had no trigger. This
change surfaces the existing capability so users can actually build, navigate,
and reorganize a collection hierarchy.

See `.docs/043-nested-collections-ui-plan.md` for the full plan.

## What changed

- **Sidebar disclosure tree.** The Collections section now renders the full
  root→leaf tree (Unsorted pinned first), descending only into expanded folders.
  The expand/collapse chevron sits on the RIGHT edge of each parent row; there is
  no depth indent — hierarchy reads through expand/collapse. Expansion state is
  in-memory; creating a subfolder auto-expands its parent. Each row's context
  menu gained New Subfolder… / Rename… / Move to… alongside Delete.
- **In-place subfolder management.** The collection screen has an always-present
  "New Subfolder" header action, and the subfolder chips gained a context menu
  (New Subfolder… / Rename… / Move to… / Delete).
- **Reparenting (drag + menu).** A collection can now be moved under another via
  a "Move to ▸" submenu (self, descendants, current parent, and Unsorted
  excluded) OR by dragging a collection card/row onto another (drop onto Unsorted
  refused; cycles refused, with the service guard as the backstop). Dragging a
  sidebar row onto the "Collections" header un-nests it to top level; "Move to ▸
  → Top Level" does the same from the menu.

## Revisions (post-review)

- Removed the collection-screen breadcrumb (UI **and** the now-unused pure
  `collectionBreadcrumb` helper in `NavModel`, plus its `NavBreadcrumbTests`).
- Sidebar disclosure arrow moved to the trailing (right) edge; child rows are no
  longer indented.
- Added the header un-nest drop zone (drag a nested collection onto "Collections"
  → top level).

## Files changed

- `AtelierRefs/AtelierRefs/CollectionDragPayload.swift` — **new.** The
  folder-reparent drag payload + `com.ref-atelier.collection-id` UTType.
- `AtelierRefs/AtelierRefs/CollectionMoveToMenu.swift` — **new.** The shared
  "Move to ▸" submenu used by all three collection surfaces.
- `AtelierRefs/Info.plist` — declared the new exported drag UTType.
- `AtelierRefs/AtelierRefs/CollectionTargets.swift` — `folderMoveTargets(for:…)`
  and `descendantIDs(of:in:)` (pure, cycle-safe).
- `AtelierRefs/AtelierRefs/SidebarView.swift` — flat rows → flattened disclosure
  tree; drag/drop reparent; unified new-folder + rename alerts.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — New Subfolder header action,
  subfolder chip context menus, create/rename alerts.
- `AtelierRefs/AtelierRefs/CollectionsGalleryView.swift` — card drag/drop
  reparent + drop ring; "Move to ▸" in the card menu.
- `AtelierRefs/AtelierRefs/NavModel.swift` — removed the retired
  `collectionBreadcrumb` helper.
- `AtelierRefs/AtelierRefsTests/CollectionTargetsTests.swift` — reparent-target
  and descendant-walk coverage (exclusions, ordering, cycle-safety).
- `AtelierRefs/AtelierRefsTests/NavModelTests.swift` — dropped the breadcrumb
  suite; route-intent tests retained.

## Notes / follow-ups

- Reparent drag-and-drop composes SwiftUI-native `.draggable` /
  `.dropDestination`; verify the drag interactions in-app (build + unit tests are
  green, but drag gestures aren't exercised by the headless test run).
- Sidebar expansion state is intentionally not persisted across launches yet.
- No migration; no data-model or service changes — this is UI wiring over the
  existing backend.
