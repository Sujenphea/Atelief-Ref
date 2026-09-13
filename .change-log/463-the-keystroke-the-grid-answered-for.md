# 463 — the keystroke the grid answered for

A production report: the item detail page's text fields cannot be pasted into. ⌘V in
Name, Note or Add-tag did not insert text — it imported the clipboard into the collection
behind the page.

## The button in front of the field editor

`CollectionView` carries ⌘V on a hidden shortcut-only `Button`, mounted in the background
of `content`. The detail page is a **sibling** of `content` in `body`'s `ZStack`, so the
button is still mounted while the page is up — and a key equivalent is dispatched before
the event reaches the first responder. The field editor never saw the keystroke. `paste()`
ran instead, found no `AssetDragPayload` on the board, took `.importExternal`, and handed
the clipboard to `DirectInputReader`.

This precedence is not news to this repository. It is written down four times already, in
prose, each time by something it had just broken:

| | |
| --- | --- |
| `SpaceView.undoRedoBar` | ⌘Z mid-sentence reverted the whole previous board operation |
| `SpaceView.duplicateButton` | ⌘D in a text field vanished into a duplicated box |
| `SpaceView.zOrderShortcuts` | ⌘⇧] restacked the board mid-sentence |
| [354](354-delete-on-the-page-reaches-the-page.md) | ⌘⌫ on the page destroyed the grid's picture |

Each was fixed where it was found. ⌘V is the fifth, and the one nobody went back for.

## Two rules, and neither is a new signal

**The binding is withdrawn while the page is up** — 354's rule, applied to ⌘V. That is the
whole of the reported bug: with no binding in front of it, the keystroke falls through to
Edit ▸ Paste and the responder chain, which is the page's field editor when one holds the
keyboard and nobody when one does not. ⌘V on the page with no field focused now does
nothing, rather than importing into a collection the user cannot see.

**A ⌘V that still reaches the button while a field editor holds first responder is handed
back**, via `NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)` — the
responder walk Edit ▸ Paste would have done. This is the half the report did not mention
and the grid screen needed: the toolbar search field and the sidebar's rename / draft cell
(`SidebarDraftCell`) are in the same window, share the same field editor, and were losing
⌘V to the same button.

The predicate is `isSearchFieldEditor`, which already existed and already draws the one
distinction that matters here — a *field editor* is the shared per-window editor a
`TextField` borrows, and the canvas's own `NSTextView` is not one, so a text box being
edited on a board is not swept up by this.

Withdrawing the binding rather than unmounting the button is deliberate, and `SpaceView`
documents the trap from the other side: a `keyboardShortcut` on a view that isn't rendered
never fires.

**Why not one rule.** The forward alone would leave ⌘V-with-nothing-focused importing
behind the page; the withdrawal alone would leave the search field and the sidebar cell
broken, since neither is on the detail page. They close different halves.

**Why not a focus signal per field.** The alternative shape — an editing flag plumbed from
each field up to `CollectionView` — needs `SidebarEditState` lifted out of both outline
coordinators into something SwiftUI observes, and leaves every future text field owing a
registration it will not remember. The field-editor question is one question, asked once.

## Files changed

- `AtelierRefs/AtelierRefs/CollectionView.swift`
  - `pasteShortcut(detailPresented:)` — **new**, `static`. `nil` withdraws the binding.
  - `PasteDispatch` + `resolvePasteDispatch(fieldEditorFocused:isReady:)` — **new**,
    `static`. The gate in front of `PasteRoute`, which only ever answers for the
    collection. The field editor is checked **before** readiness: typing in the search
    field is not the library's to gate, and a ⌘V swallowed because the model happened to
    still be opening is the same bug in a narrower window.
  - `paste()` — now the three-way switch. Its former body is `pasteIntoCollection()`,
    unchanged.
  - The hidden button takes its shortcut from `pasteShortcut`.
- `AtelierRefs/AtelierRefsTests/AssetPasteboardTests.swift` — `GridPasteDispatchTests`,
  **new**, 6 tests. `import SwiftUI` for `KeyboardShortcut`.

## Verification

- `xcodebuild test -scheme AtelierRefs -destination platform=macOS`,
  `-only-testing:AtelierRefsTests/GridPasteDispatchTests`
  `-only-testing:AtelierRefsTests/GridPasteRoutingTests`: **TEST SUCCEEDED**, 12 tests.
  The 6 pre-existing `GridPasteRoutingTests` are unchanged and still pass — the routing
  they cover moved into `pasteIntoCollection()` untouched.
- App target builds clean.

## What is still NOT covered

**No key event was dispatched.** Both rules are asserted as pure functions; that AppKit
dispatches a `keyboardShortcut` ahead of the field editor is taken from the four prose
records above — one of which calls it measured — and not re-measured here. What a test
could still not tell you is whether SwiftUI's toolbar hosting puts the search field in the
window's `performKeyEquivalent` path at all; the forward is correct either way, and is
belt to that brace.

**The sidebar cell was reasoned about, not driven.** `SidebarDraftCell` is an
`NSTextField` in the same window borrowing the same field editor, so `isSearchFieldEditor`
answers for it. That is a reading of the code, not an observation of a rename.

**Nothing else audited the other four.** ⌘Z, ⌘D, ⌘⇧[ and ⌘⌫ are fixed where they were
found and were not revisited. There is still no single place that says a sibling
`keyboardShortcut` outranks both the field editor and the responder chain.

## Migration notes

- **`paste()` is now a router.** A caller wanting the old behaviour unconditionally wants
  `pasteIntoCollection()`. Nothing outside `CollectionView` calls either.
- **⌘V on the detail page no longer imports.** If a picture was ever pasted into a
  collection *from* the open page, that route is gone, and deliberately — the page has no
  visible collection to paste into.
- **The button is still mounted while the page is up**, disabled state and all. Only its
  key binding is withdrawn.
