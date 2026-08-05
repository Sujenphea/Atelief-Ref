# 024 — The Keyboard Map, Written Down and Then Shown

> Requested: **M = move, A = add** on Spaces, and **a shortcuts page**. The
> shortcuts page is the load-bearing half — the app has ~30 bindings spread across
> six key-handling sites, and **not one of them is documented in the UI**. Adding
> M/A before writing the map down is how you get a third convention.

## Current state (verified)

Six independent key-handling sites, no shared registry:

| Site | Where | Bindings |
|---|---|---|
| App menus | `AtelierRefsApp.swift:143,146,177,219,260` | ⌘Z, ⇧⌘Z, ⌘D (favorite), ⌘N (new collection/space), ⌘[ (back) |
| Collection grid | `gridKeyCommand`, `MasonryGridHost.swift:1776` | ←↑→↓ (+⇧ extend), Return open, Esc, Space Quick Look, `X` toggle lead, ⌘A, ⌘=/⌘+, ⌘−; ⌫/⌦ via `deleteBackward:` (`:327`) |
| Item detail | `detailStepDelta`, `ItemDetailView.swift:1399` | ←/→ step; Esc back; ⌘−, ⌘0, ⌘+, ⌘= zoom |
| Space canvas | `CanvasHostView.swift:1143` + `toolShortcut` | `V`/`F`/`T` tools, ⌫/⌦ remove tile, ⌘C, ⌘V; ⌥-drag duplicate, ⌘-drag out |
| Space chrome | `SpaceView.swift:663-805` | ⌘Z, ⇧⌘Z, ⌘D duplicate, ⌘⇧], ⌘⇧[ |
| Collections gallery | `CollectionsGalleryView.swift:73-81` | ⌘A, ⌫ (`onDeleteCommand`), Esc |

Plus ⌘F (`LibrarySearch.swift:625`), ⌘⇧E (`MoodboardExportControls.swift:138`),
⌘V paste-into-collection (`CollectionView.swift:248`).

**Nothing lists these.** `SettingsView.swift` has no shortcuts section; there is
no Help menu content; the only discovery route is `.help()` tooltips on a handful
of buttons, and several of those deliberately *decline* to name a shortcut
(`ItemDetailView.swift:270-274` explains why the star button won't advertise ⌘D).

Two consequences worth naming:

- **Bare-letter keys are already claimed asymmetrically.** `X` is the grid's
  toggle-lead; `V`/`F`/`T` are the canvas's tools. A bare `M`/`A` on Spaces would
  be the *third* bare-letter convention, on a surface that already has three.
- **Collisions are invisible.** ⌘D means *Favorite* in the grid and *Duplicate*
  on a board. That is defensible — but only because nobody can see both at once,
  which is exactly what a shortcuts page changes.

## A — the map (do this first)

One `Shortcut` value type and one table, `KeyMap.swift`, pure and
SwiftUI-free: `(keys, modifiers, title, scope)` where scope is
`.global | .collection | .detail | .space | .gallery | .search`. Nothing
*dispatches* from it — the existing pure decoders (`gridKeyCommand`,
`detailStepDelta`, `toolShortcut`) stay authoritative, because they are already
tested and rewriting dispatch to be table-driven is a large change for no user-
visible gain.

What the table buys, in order of value:

1. **A collision test.** One unit test asserting no two entries in the same scope
   (or in `.global` + any scope) share a chord. This is the thing that keeps a
   growing key map honest, and it costs one test.
2. **The shortcuts page** renders from it.
3. **Menu items** ([073] adds Edit ▸ Remove/Delete) read their titles from it.

Keeping the table beside the decoders means they can drift; the mitigation is a
second test that walks the table's collection-scope rows through
`gridKeyCommand` and asserts each resolves — a contract test, the same shape as
[011]'s "same frames in → same selection out".

## B — the shortcuts page

A **sheet**, not a Settings tab: it is reference material you open mid-task and
dismiss, and Settings is where things you *change* live.

- Reached from **Help ▸ Keyboard Shortcuts (⌘/)** — `⌘/` is the convention users
  arrive with, and it is currently unbound.
- Content: one section per scope, in the order a user meets them (Global,
  Collections, Item Detail, Spaces, Search). Chords rendered as key caps; rows
  come straight from the table, so a binding added without a table row is
  invisible and a table row without a binding is a lie the collision test cannot
  catch — hence the contract test in A.
- Scope-aware highlight: the section matching the current surface opens first.
  Cheap (`nav.sidebarSelection` + `presentedItemID` already say where you are)
  and it is most of the perceived value.
- **Not** editable rebinding. That is a real feature with real storage and a
  conflict UI; v1 is a reference card.

## C — M / A on Spaces (and everywhere else)

[011] Cluster C-2 already settled this shape for the **grid**: with a non-empty
selection, **M** opens "Move to…" and **⇧M** opens "Add to…". The request here is
**M = move, A = add** on Spaces. Reconcile before implementing, because shipping
both spellings is the exact failure this doc exists to prevent.

Recommended: **M = Move to…, A = Add to…, on every surface with a selection.**

- `A` is a better key than `⇧M` — it is mnemonic, it is one hand, and ⌘A is
  already select-all so the bare key is not "nearly" taken in a confusing way.
- It matches the request as given.
- It costs [011] a one-line amendment (C-2's `⇧M` → `A`), and [011] is unbuilt,
  so nothing has to be migrated.

Conflict check against the current map:

- Space canvas: `V`/`F`/`T` are taken; `M`/`A` are free (`toolShortcut`,
  `CanvasHostView.swift:1198`, returns `nil` for everything else).
- Collection grid: `X` is taken; `M`/`A` free (`gridKeyCommand:1799`).
- Both decoders already require *bare* modifiers, so ⌘A / ⌘M are unaffected.

Semantics on a board differ from a grid and must be stated:

- **M (Move to…)** — file the selected tiles' assets into a collection **and drop
  the placements** (the board is not a collection; "move" means the assets leave
  the board's working set). This needs the [073] remove-placement path plus
  `moveAssets`, in one undo group.
- **A (Add to…)** — file the assets into a collection, **placements untouched**.
  This is the common one on a board, and it is `addAssets` — already reachable
  from the Space's own targets (`SpaceTargets.swift`).

Both open the same destination picker the selection bar uses —
`CollectionTargets.moveTargetTree` (`CollectionTargets.swift:62`), the full
indented hierarchy. That is [075]'s point too: **one destination list, one
ordering, everywhere.**

## D — the small gaps the audit turned up

- Sidebar rename has no key path at all — that is [074], which owns Enter /
  double-click on a sidebar row.
- The grid decodes ⌫ through `deleteBackward:` but has no `\u{7f}` case in
  `gridKeyCommand`, so there is no seam to read a modifier — [073] §"Where it is
  decided" fixes this.
- `⌘/` is unbound; `?` is unbound. Take `⌘/`.

## Schema / migration impact

**None.**

## Phased implementation

1. **K1 (S)** — `KeyMap` table + collision test + contract test against the three
   existing decoders. No UI.
2. **K2 (S–M)** — the shortcuts sheet + Help ▸ Keyboard Shortcuts (⌘/).
3. **K3 (M)** — M / A on the collection grid (needs [011] C-2's picker) and on
   Spaces (needs the move-and-drop-placement composite).
4. **K4 (XS)** — amend [011] C-2's `⇧M` to `A`; add the [073] Edit-menu rows to
   the table.

## Test strategy

- Collision test over `KeyMap.all` (the point of the whole exercise).
- Contract test: every `.collection`-scope row resolves through `gridKeyCommand`;
  every `.detail` row through `detailStepDelta`; every `.space` tool row through
  `toolShortcut`.
- `M`/`A` decoding: bare only — ⌘M, ⌥A, ⌃A all `nil`; ⇧ tolerated.
- Space `M`: one undo entry restores both the memberships and the placements
  (the composite is the risky part, not the key).
- Page render: compile-only + manual (repo convention for view code).

## Effort: **A: S · B: S–M · C: M · D: XS**

## Risks & edge cases

- A bare `M`/`A` must never fire while a text box has the keyboard — the canvas
  already guards on `editingTileID` (`CanvasHostView.swift:1152`) and the detail
  page declines to steal from `NSText`; the grid has no text entry, but the
  sidebar draft field does, and it lives in the same window.
- The shortcuts page will make ⌘D's two meanings (Favorite / Duplicate) visible
  side by side. Either accept it with an explicit scope label, or rename one —
  worth deciding *when writing the page*, not after someone files it as a bug.
- Space `M` is destructive-adjacent (placements disappear). It needs a toast that
  names both halves, or it reads as a bug.
- A rebinding UI will be asked for the moment the page exists. Say "not v1" in
  the page's own footer rather than leaving it implied.

## Open questions

1. Confirm **A** over [011]'s **⇧M** for "Add to…" (recommended: A).
2. Should `M`/`A` also work on the **Collections gallery** (moving whole folders)?
   Recommended: no — folder reparenting has its own "Move to" menu ([075]).
3. Shortcuts page as a sheet (recommended) or a Settings tab?
4. Does ⌘D keep two meanings, or does the board's Duplicate move to ⌘⇧D?
