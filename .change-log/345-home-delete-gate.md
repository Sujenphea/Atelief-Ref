# 345 — Home Stops Deleting on ⌫

[073], finishing the surface it missed. **A bare ⌫ on Home no longer deletes
collections or spaces. ⌘⌫ does**, through the same confirmation, the same
`deleteCards`, the same per-space undo. Nothing about the deletion changed; only the
key that reaches it.

`ef5201d` made the pair mean one thing everywhere —

> **⌫ removes the item from where you are looking. ⌘⌫ removes it from the app.**

— on the grid, the board, the item detail page and search. It did not reach the Home
gallery, and Home was the highest-stakes surface in the app to leave behind: the
softest key on the keyboard, over a selection that ⌘A fills with every collection and
every space you own. [344]'s key map recorded it as a known violation rather than
fixing it; this is the fix.

## Why ⌫ became nothing rather than something

Every other surface has a container to remove from — a collection's membership, a
board's placement. **Home has none.** A collection card is not *in* anything you could
take it out of, so the remove half of the rule has no meaning here. That is the same
answer [073] already gave search results, for the same reason, and the decision was
the user's: the plain ⌘⌫ gate, no extra confirmation dialog on top.

It is not silent. Bare ⌫ over a selection posts the existing toast —

> Home has nothing to remove from — press ⌘⌫ to delete.

— in the shape of the grid's Unsorted branch (`removeFromCurrentFolder`), which says
the same sentence for the same reason. **No new toast mechanism**; `notify` already
existed and `IngestionModel.explainHomeDeleteKey()` is the one-line verb behind it. A
key that used to delete your collections going quietly dead is worse than a key that
says who took the verb over, and muscle memory trained on the old binding is exactly
the population that will press it. With nothing selected it stays silent — nothing was
asked for.

## Why `.onDeleteCommand` had to go rather than be patched

`CollectionsGalleryView` read its Delete key through SwiftUI's `.onDeleteCommand`,
which is handed **no modifier flags at all**. There is no seam in it where ⌘ could be
read, so it could only ever mean one thing — and the one thing it meant was "delete".
It could not route through `deleteIntent`, which is why Home was the only surface
outside the rule: not an oversight in the wiring, a property of the hook.

It is replaced by `.onKeyPress(keys: [.delete, .deleteForward])`, the mechanism this
same view already uses for ⌘A, decoding through the app-wide `deleteIntent` by way of
a thin `galleryDeleteIntent` adapter. ⌥⌫ and ⌃⌫ therefore fall through here as they do
everywhere else — they are word and line deletes, not verbs this app owns.

### The bug the tests caught: SwiftUI's ⌫ is not AppKit's ⌫

**`KeyEquivalent.delete` is BACKSPACE, `U+0008`. The same physical key read off an
`NSEvent` is DEL, `U+007F`** — and `U+007F` is what `gridIsDeleteKey`, and therefore
every delete decoder in the app, recognises. `.deleteForward` needs no translation
(both frameworks call it `U+F728`); Backspace does.

The first cut of the adapter handed the raw character straight to `deleteIntent`, which
answered `nil`, which meant a live ⌫ on Home did **nothing at all** — no crash, no
warning, and a gallery that looked exactly as it would if the wiring were correct.
`HomeDeleteGateTests` failed on its first run and named the reason. This is the single
best argument in this change for having written the "the assumption this route rests
on" test at all: it is the one failure mode a passing build and a working ⌘A would both
have hidden.

The translation lives in `galleryCharacters`, at the one boundary that speaks both
vocabularies — **not** in `gridIsDeleteKey`. Widening the shared predicate to accept
`U+0008` would have been the tempting one-line fix and is wrong: `U+0008` is what ⌃H
produces, so it would have made a control chord delete things on every surface.

### The two things that were NOT done, and why

- **No `.keyboardShortcut`, and no `NSMenu` key equivalent for bare ⌫.** A menu key
  equivalent is matched *before* the first responder is consulted, so a bare ⌫
  registered anywhere would swallow Backspace in every text field in the app — the
  sidebar's rename row, the search field, the detail page's Name and Note. `ef5201d`
  left ⌫ off Edit ▸ Remove for exactly this reason and says so on `DeleteCommands`.
- **No local ⌘⌫ binding.** ⌘⌫ is Edit ▸ Delete, already app-wide, already in the key
  map's `.global` scope. Home now publishes a `DeleteVerbs` focused value, so that one
  item points at the Home selection — the same seam the grid, the board and search use.
  A second ⌘⌫ registered on the gallery would be the exact `.global`-shadows-a-surface
  case `KeyMap.collisions(in:)` exists to catch, and it would lose to the menu anyway.

The guard that makes bare ⌫ safe is structural rather than written down: `.onKeyPress`
only fires while the gallery holds SwiftUI focus, and the sidebar's rename field taking
the keyboard *is* the gallery losing it. Nothing needs to ask whether an `NSText` has
first responder, because the handler cannot run while one does.

## A judgement call worth naming

`DeleteVerbs` is published **only while cards are selected**, so Edit ▸ Delete is greyed
on an empty Home rather than clickable and inert; `canRemove: false` greys Edit ▸ Remove
always, as it is on search. This does light up a menu item that was dark on Home before
— the `DeleteCommands` doc comment said Home "publishes nothing" — which is a small
addition beyond the brief, but it is the mechanism that makes ⌘⌫ arrive at all, and a
Delete menu item that works where the key works is the truthful arrangement.

## The key map stays truthful

`KeyMap`'s `.gallery` rows said "⌫ — Delete the selected cards…" with a note explaining
that Home was the one surface breaking the rule. The row is now "⌫ — Nothing, ⌘⌫ deletes
the cards", filed under the `.delete` decoder, and the violation note is gone. It is a
row rather than an omission because the app really does claim the key: it consumes the
press and posts the notice.

The contract test now walks it back through **`galleryDeleteIntent`**, not only
`deleteIntent` — the row would have passed on the shared decoder alone while the gallery
was wired to something else entirely, which is the drift this table exists to prevent.
The collision test still passes with no new chords claimed.

## Files changed

- `AtelierRefs/AtelierRefs/CollectionsGalleryView.swift` — `.onDeleteCommand` replaced
  with `.onKeyPress(keys: [.delete, .deleteForward])` → `galleryDeleteKeyPress`;
  publishes `DeleteVerbs` while selecting; new pure `galleryEventFlags`,
  `galleryCharacters`, `galleryDeleteIntent`, `GalleryDeleteTargets` and
  `galleryDeleteTargets`. The
  selection → (collections, spaces) split moved out of two computed properties into
  the pure function, which also fixed their `Set`-iteration ordering to display order.
  ⌘A, Esc, the marquee and the selection bar's trash button are untouched.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — new `explainHomeDeleteKey()`, the
  bare-⌫ notice. `deleteCards` unchanged.
- `AtelierRefs/AtelierRefs/KeyMap.swift` — the `.gallery` ⌫ row rewritten and given the
  `.delete` decoder; the "violates the two-tier rule" note removed; the `.global` ⌘⌫
  row's doc now says why a surface never gets a ⌘⌫ row of its own; the bare-binding
  constraint list gains Home's SwiftUI-focus guard as a fourth entry.
- `AtelierRefs/AtelierRefsTests/HomeDeleteGateTests.swift` (new) — 14 tests: the four
  tiers (bare / ⌘ / ⌥ / ⌃) and ⇧ tolerance through `galleryDeleteIntent`; that a letter
  is never a delete; **the `KeyEquivalent` → `NSEvent`-characters translation, both that
  it produces the app's delete keys and that SwiftUI's `.delete` is `U+0008` so the
  substitution is necessary** — the test that caught the bug above; the modifier
  bridge; the target split over mixed, select-all, Unsorted, stale-id and ordering
  cases; a bare ⌫ deleting nothing and naming ⌘⌫; and ⌘⌫ over a mixed selection
  deleting exactly what the split named and nothing else.
- `AtelierRefs/AtelierRefsTests/KeyMapTests.swift` — the `.delete` contract test now
  asserts a `.gallery` row exists, plus a new contract test walking that row through
  `galleryDeleteIntent` and checking it agrees with `deleteIntent`. The stale comment
  about Home not being in the table is corrected.

## Migration notes

**No schema change.** The behaviour change is the migration note:

- **⌫ on Home no longer deletes collections or spaces.** It deletes nothing at all and
  posts a notice naming ⌘⌫. Anyone whose fingers learned the old binding will press ⌫,
  see the confirmation not appear, and read why.
- **⌘⌫ on Home deletes**, exactly as ⌫ used to: the same "Delete N items?" confirmation,
  the same `deleteCards`, collections gone fire-and-forget (Unsorted still guarded),
  each space recoverable with its own ⌘Z. Edit ▸ Delete now works on Home too, and is
  enabled only while cards are selected.
- ⌥⌫ and ⌃⌫ on Home do nothing, as on every other surface.
- The context menus' per-card Delete and the selection bar's trash button are unchanged.
