# 074 — The Sidebar Row Does Two Things At Once

**Status: shipped** — `2b5560d`. S1–S3. Open question 1 answered: Unsorted is
not renameable. Open question 2 answered: the chevron stays trailing. One
correction to the analysis below — Unsorted's context menu already excluded
"Rename…" via a `guard !node.isUnsorted`; only Enter and double-click needed the
new no-op.

> Two requests, both about the same row: **the disclosure chevron should be its
> own button**, separate from opening the collection; and **Enter / double-click
> should rename**. Today one click does both jobs, and rename is reachable only
> from a context menu.

## Current state (verified)

### The chevron is decoration

`SidebarCell`'s chevron is an `NSImageView`, and the code says so:

```swift
private let chevron = NSImageView()   // indicator only — the row handles toggle
```
`SidebarOutlineKit.swift:144`

It has no target, no action, no tracking area of its own. The toggle lives in the
row's click handler:

```swift
/// A click anywhere on a parent row toggles its children (leaves just select).
@objc private func rowClicked() {
    …
    if nav.sidebarSelection != .collection(node.id) { nav.selectSidebar(.collection(node.id)) }
    guard !children(of: node).isEmpty else { return }
    let willExpand = !outlineView.isItemExpanded(node)
    …
}
```
`CollectionsOutlineView.swift:527-544`

So **one click on a parent both navigates and toggles**, unconditionally and in
that order. There is no way to expand a folder without leaving the page you are
on, and no way to open a folder without collapsing the children you just opened.
The two verbs are also inverse-coupled: the click that opens *Refs* collapses
*Refs*' subfolders, so drilling in requires alternating clicks.

Note the outline view's built-in disclosure triangle is **not** in play — the
cell draws its own right-aligned glyph, so `NSOutlineView`'s normal
"triangle toggles, row selects" split was given up on purpose (`SidebarCell`'s
doc: "NO leading icon, and a right-aligned chevron"). That is a *visual*
decision worth keeping; the *interaction* it dropped is what needs restoring.

Spaces are unaffected — `SpacesOutlineView` is flat (`expandable: false`,
`:340,359`) and its `rowClicked` (`:389`) only navigates.

### Rename is context-menu-only

- `CollectionsOutlineView.swift:232` — `"Rename…"` opens a SwiftUI text-entry
  alert (`NameEntryAlert`).
- `SpacesOutlineView.swift:176` — same.
- The outline view has **no** `doubleAction`, and **no** `keyDown` override, so
  Enter on a selected row does nothing at all.
- Inline editing already exists and works — `SidebarDraftCell`
  (`SidebarOutlineKit.swift:193`) is a borderless editable field pixel-matched to
  the static label, with Enter-commits / Escape-cancels / focus-loss-commits and
  a double-commit guard. It is used for the **new item** draft only
  (`beginDraft`, `CollectionsOutlineView.swift:342`). **The hard part of rename-in-
  place is already built.**

## The design

### A — chevron becomes a button, row stops toggling

1. `SidebarCell.chevron` becomes an `NSButton` (bordered `false`, image-only,
   `Theme.NS.inkSecondary` tint) with a target/action, sized to a real hit area
   (the current 12×12 glyph is below the comfortable minimum — pad the button to
   ~20×20 while keeping the glyph at 12, the same trade the detail pager's
   chevrons make).
2. `rowClicked` drops its expand/collapse half entirely. A row click navigates.
   Full stop.
3. The button's action toggles expansion **without** touching `nav` — and it must
   not select the row either, so the click has to be consumed before
   `NSOutlineView`'s own row-click handling. Cell-subview buttons receive the
   mouse first, so the outline's `action` fires on `clickedRow == -1`; guard
   `rowClicked` on `clickedRow >= 0` (it already does, `:528`).
4. Keep `setExpanded` synchronous on press — the existing comment ("so it never
   lags", `:531`) is right and stays right.
5. `outlineViewItemDidExpand/DidCollapse` (`:521-522`) keep reporting height, so
   the SwiftUI-measured sidebar height still tracks. Any programmatic expand
   (`expandAncestors`, `beginDraft`) must refresh the visible cell's glyph — today
   `rowClicked` does that inline; move it into the expand/collapse delegate
   callbacks so *every* path updates the glyph, not just the click path.

Keyboard parity, free with the split: →/← on a selected row expand/collapse
(`NSOutlineView` gives this once the row isn't fighting the toggle). Worth adding
to [077]'s map.

### B — rename in place

Reuse `SidebarDraftCell`. Generalise the draft session from *"a new item under
parent P"* to *"an editing session on row R"*:

```
enum EditSession { case draft(parent: UUID?), rename(id: UUID) }
```

- `.draft` behaves exactly as today (phantom row appended via `children(of:)`).
- `.rename` swaps the **existing** row's cell for the editable one; commit calls
  `model.renameFolder(id:to:)` (`IngestionModel.swift:1714`) instead of
  `createFolder` (`:1699`); cancel restores the
  label. No phantom row, so none of the drop-index / reload machinery changes.

The existing suspend/restore, commit-once guard, and field-editor transparency
fix (`focusDraftField`, `:411-436` — the shared field editor keeps the last
client's background) all apply unchanged, which is the reason to reuse rather
than write a second editable cell.

Triggers:

- **Enter** on the selected row → `.rename`. Needs a `keyDown` override on the
  outline view (there is none today); Enter must be ignored while an edit session
  is open, so the commit path isn't re-entered.
- **Double-click** → `.rename`. `outlineView.doubleAction = #selector(rowDoubleClicked)`.
  AppKit sends the single-click action first, so a double-click will navigate
  *then* rename — acceptable (you renamed the thing you opened), and the
  alternative (deferring nav by the double-click interval) makes every single
  click feel laggy. Don't do that.
- Context menu "Rename…" keeps working, but switches from the alert to the same
  inline session — one rename affordance, three ways in. `NameEntryAlert` stays
  for surfaces that genuinely need a dialog.
- Escape cancels; focus loss commits (matching the draft cell's existing rule,
  and matching Finder).

Apply to **both** outlines — `CollectionsOutlineView` and `SpacesOutlineView` —
in the same change. They already mirror each other's `rowClicked` correction
(`SpacesOutlineView.swift:388`), and letting rename land on one first is how they
stop mirroring.

## Schema / migration impact

**None.** `renameFolder` / space rename already exist.

## Phased implementation

1. **S1 (S)** — chevron → button; `rowClicked` navigates only; glyph refresh
   moves to the expand/collapse delegates; →/← keyboard toggle.
2. **S2 (M)** — `EditSession` generalisation + `.rename` on both outlines.
3. **S3 (XS)** — Enter + double-click triggers; context menu re-points at the
   inline session; [077] map rows.

## Test strategy

The outline coordinators are AppKit, so this is mostly the repo's compile-only +
manual convention. What *can* be pinned:

- `EditSession` state machine as a pure type: draft→commit, draft→cancel,
  rename→commit, rename→cancel, and **rename→reload-mid-edit** (the case
  `update(folders:…)` already handles for drafts at `:285-296` — a rename must
  survive a refresh landing under it the same way).
- Rename to an empty / whitespace-only name → cancel, not a blank folder.
- Rename to an unchanged name → no write (no spurious undo entry).
- Manual pass: expand a parent without navigating; navigate to a parent without
  collapsing it; double-click a row that is already selected; Enter with no
  selection; Enter while a draft is open.

## Effort: **S1: S · S2: M · S3: XS**

## Risks & edge cases

- **The chevron button must not steal the row's drag.** Both outlines are drag
  sources (`pasteboardWriterForItem`, `:547` / `:398`); a button subview that
  swallows mouse-down could block a drag begun on the chevron. Accept that
  (dragging by the chevron is not a gesture anyone reaches for) but verify the
  rest of the row still drags.
- Drops are refused while a draft is open (`:583`); the same guard must cover a
  rename session, or a drop lands mid-edit.
- The committed-draft placeholder row (`:377-394`) draws with `forceSelected` and
  is non-selectable — a rename session must never target it.
- Double-click on the **Unsorted** row: it is protected from move and drag; is it
  protected from rename? Today the context menu offers Rename on it. Decide
  explicitly.
- Removing the row-toggle changes muscle memory for anyone used to it. It is
  strictly more capable (both verbs remain reachable, independently), so no
  migration affordance is warranted — but it *is* a behaviour change worth a
  changelog line.

## Open questions

1. Is **Unsorted** renameable? (Recommended: no — it is protected everywhere else.)
2. Should the chevron stay right-aligned once it is a button, or move to the
   leading edge where macOS users expect a disclosure control? (Recommended: keep
   it trailing — the visual identity is deliberate and documented.)
3. Does Enter-to-rename conflict with any future "Enter opens" convention in the
   sidebar? (The grid uses Return-to-open; the sidebar has no such binding, so no
   conflict today — but [077]'s collision test should carry the scope.)
