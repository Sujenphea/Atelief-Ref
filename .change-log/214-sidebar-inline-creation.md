# 214 — Sidebar inline creation (collections, spaces) + ⌘N

## Summary

Replaced the popup name-entry alert for **creating** collections, subfolders, and spaces
with Finder-style **inline** creation: a focused, empty text-field row appears at the
bottom of the relevant list. Enter commits, Escape or an empty commit cancels, and losing
focus commits a non-empty name (else cancels). Added a **⌘N** command that starts the
inline draft for whichever item is active in the sidebar — "New Collection" when a
collection is selected, "New Space" when a space is selected, disabled otherwise.

The shared `nameEntryAlert` (211) is retained for **rename** only.

## How it works

- `NavModel.sidebarDraft: SidebarDraft?` is the single request funnel. The section "+"
  buttons and the ⌘N command set it; `SidebarView.onChange` consumes it — routing a
  `.collection` request to the AppKit outline via a fresh `CollectionDraftRequest` token,
  and a `.space` request to the SwiftUI draft row — then clears it back to `nil`.
- **Spaces** (SwiftUI): a `TextField` draft row styled like the normal rows, driven by
  local `spaceDraftActive` / `spaceDraftText` state and `@FocusState`.
- **Collections** (AppKit `NSOutlineView`): the coordinator injects one sentinel
  `draftNode` in `children(of:)` (the funnel every data-source call passes through), so the
  draft survives every `reloadData()` / memoized rebuild without touching the immutable
  `CollectionNode` tree. A new `SidebarDraftCell` (editable `NSTextField`, pixel-matched to
  `SidebarCell`) handles Enter/Escape via `control(_:textView:doCommandBy:)` and focus-loss
  via `controlTextDidEndEditing`, with a one-shot `finished` guard against double-commit and
  an `isSuspended` guard so a mid-edit background reload can't fire a spurious commit. On
  commit the row stays as a static label until the async folders refresh lands (jump-free
  swap; a 3s fallback clears it if creation fails silently). The draft row is inert — not
  selectable, draggable, droppable, or context-menuable. Because it can't be "selected",
  its `SidebarRowView` draws the selection fill via a `forceSelected` flag (from
  `drawBackground`, since `drawSelection` isn't called for unselected rows) so it matches
  the active/selected row's colour and inset exactly. The SwiftUI spaces draft row reuses
  the same `rowHighlight(selected:)` fill + padding for the same reason.
- The row context menu's "New Subfolder…" now calls `beginDraft(parentID:)` directly in the
  coordinator instead of opening the alert.
- `AppShellView` publishes `NavModel` as a `.focusedSceneObject` so `NewItemCommand`'s title
  and enabled state track `sidebarSelection` (a `@FocusedValue` wouldn't re-render).

## Files changed

- `AtelierRefs/AtelierRefs/NavModel.swift` — `SidebarDraft` enum + `@Published sidebarDraft`.
- `AtelierRefs/AtelierRefs/CollectionsOutlineView.swift` — draft session, `SidebarDraftCell`,
  `children(of:)` injection, `beginDraft`/`endDraft`/`handleDraftRequest`, inert-row guards;
  dropped the `onNewSubfolder` callback (context menu drives the draft directly).
- `AtelierRefs/AtelierRefs/SidebarView.swift` — removed the create alerts + their state;
  added the spaces draft row, the collection draft-request plumbing, and the draft router.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — `NewItemCommand` (⌘N) replacing `.newItem`.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — `.focusedSceneObject(nav)`.

## Migration notes

None. Behavioral change only; the rename alert and non-sidebar `nameEntryAlert` uses are
unchanged. ⌘N no longer opens a new window (it was previously the default "New Window").
