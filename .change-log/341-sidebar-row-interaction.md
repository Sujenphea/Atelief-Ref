# 341 — The Sidebar Row Stops Doing Two Things At Once

Implements [074] in full (S1 · S2 · S3). Two verbs that were tangled into one
click are now two controls, and rename moved out of a dialog onto the row.

## The chevron is a button now (S1)

`SidebarCell`'s chevron was an `NSImageView` — the code said so: *"indicator only
— the row handles toggle"*. The toggle lived in `rowClicked`, which navigated
**and** expanded, unconditionally and in that order. So:

- you could not expand a folder without leaving the page you were on, and
- the click that opened *Refs* collapsed the subfolders you had just opened.

The chevron is now a real `NSButton` — image-only, borderless, `inkSecondary`
tint, a 12pt glyph padded to a 20×20 hit area (the trade the detail pager's
chevrons already make). It keeps its trailing position: the right-aligned chevron
with no leading icon is a deliberate, documented look for this sidebar, and only
the *interaction* changed.

`rowClicked` now navigates, full stop. A cell subview takes the mouse first, so
the outline's own action fires with `clickedRow == -1` and the chevron press
neither selects nor navigates. →/← on a selected row expand/collapse, native.

The glyph refresh moved out of the click path into
`outlineViewItemDidExpand` / `…DidCollapse`, so **every** expansion path updates
it — the button, the keyboard, and programmatic reveals (`expandAncestors`,
`beginDraft`) which used to leave a stale glyph behind.

## Rename happens on the row (S2 · S3)

The inline editable cell (`SidebarDraftCell`) already existed for new-item
drafts, with the hard parts solved: suspend/restore across a reload, a
commit-once guard, and the shared-field-editor transparency fix. Rename reuses it
rather than growing a second one. The draft session generalised from *"a new item
under parent P"* to *"an editing session on row R"*:

```swift
enum SidebarEditSession { case draft(parent: UUID?), rename(id: UUID) }
```

`.draft` behaves exactly as before (phantom row via `children(of:)`). `.rename`
swaps the existing row's cell — no phantom row, so none of the drop-index or
reload machinery changed. Three ways in, one affordance:

- **Enter** on the selected row (the outline had no `keyDown` at all before);
- **double-click** (`doubleAction`) — AppKit sends the single-click action first,
  so this navigates *then* renames, which is fine: you renamed what you opened.
  Deferring nav by the double-click interval would make every single click feel
  laggy, so we don't;
- **"Rename…"** in the row menu, which no longer opens `NameEntryAlert`.

Escape cancels, focus loss commits (Finder's rule, and the draft cell's already).
Landed on **both** outlines in one change — they mirror each other, and letting
rename land on one first is how they stop mirroring.

What a commit declines to write is in `SidebarEditState.outcome(committing:)`, a
pure type: an empty or whitespace-only name cancels rather than blanking a
folder, and a rename that ends on the name it started with writes **nothing** —
`IngestionModel.renameFolder` enqueues an undoable work item unconditionally, so
a no-op write there is a ⌘Z step the user has to press twice to get past.

## Guards

- **Unsorted is not renameable.** It is protected from move and drag already, and
  it is the folder every removal re-homes to. Its row menu already stopped at
  "New Subfolder…"; Enter and double-click on it are now no-ops too.
- Drops and drags are refused while **any** session is open — the existing draft
  guard now covers rename, so a drop can't land mid-edit.
- The committed-row placeholder is never a rename target.
- A model reload landing mid-rename restores the in-progress text, the same way
  it already did for drafts; if the row itself vanished under the edit, the
  session is dropped.
- `NameEntryAlert` stays wired as a fallback for a row the coordinator cannot
  resolve, and remains available to surfaces that genuinely need a dialog.

## Behaviour change worth knowing

**A click on a parent row no longer expands it.** Anyone with that muscle memory
now clicks the chevron instead. It is strictly more capable — both verbs remain
reachable, independently — so there is no migration affordance, but it is a
change you will feel on the first click.

## Files changed

- `AtelierRefs/AtelierRefs/SidebarOutlineKit.swift` — chevron → `NSButton` with a
  20×20 hit area and an `onToggle` action; `SidebarOutlineView.onKeyDown` hook;
  `SidebarEditSession` / `SidebarEditState` / `SidebarEditOutcome`; row view no
  longer double-draws a force-selected row that is also selected.
- `AtelierRefs/AtelierRefs/CollectionsOutlineView.swift` — `rowClicked`
  navigates only; `toggleExpansion` on the chevron; glyph refresh on the
  expand/collapse delegates; `DraftState` → `SidebarEditState` with
  `beginRename` / `endEdit`; Enter + double-click triggers; menu re-pointed at
  the inline session; drag/drop guards cover rename.
- `AtelierRefs/AtelierRefs/SpacesOutlineView.swift` — the same session
  generalisation and triggers (flat list, so no S1).
- `AtelierRefs/AtelierRefsTests/SidebarEditSessionTests.swift` (new) — 17 tests
  over the state machine: draft/rename × commit/cancel, empty and
  whitespace-only, unchanged-name, case-only change, trimming, and a reload
  landing mid-edit.

## Migration notes

None.
