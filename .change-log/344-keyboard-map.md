# 344 — The Keyboard Map, Written Down and Then Shown

[024] K1, K2 and K4. K3 (the `M` / `A` bindings themselves) is not in this change —
it needs the shared destination picker [343] is building.

The app decided key presses in **seven** independent places and listed them in
**none**. `SettingsView` had no shortcuts section, there was no Help menu content,
and the only discovery route was `.help()` tooltips on a handful of buttons —
several of which deliberately decline to name their shortcut (`ItemDetailView.swift`
explains at length why the star button won't advertise ⌘D).

## K1 — one table

`KeyMap.swift`: a `Shortcut` value type — `(keys, modifiers, title, scope, decoder,
status, source)` — and one table of every binding the app has, verified against the
source at `ef5201d`. Pure and SwiftUI-free, in the shape `DeleteIntent.swift`
established.

**Nothing dispatches from it.** `gridKeyCommand`, `detailStepDelta`,
`CanvasHostView.toolShortcut` and `deleteIntent` stay authoritative; they are already
tested, and rewriting dispatch to be table-driven would be a large change for no
user-visible gain. The table is a *description*, and it buys three things:

1. **A collision test** — no two rows in the same scope, or in `.global` plus any
   scope, may claim the same chord. This is the main reason the table exists.
2. The shortcuts sheet renders from it.
3. The Help menu item reads its title from it.

A description can drift from what it describes, so every row that a pure decoder
owns *names* that decoder, and `KeyMapContractTests` walks each row back through it:
`.grid` rows through `gridKeyCommand` (and assert the *command*, not merely
non-`nil`), `.detailStep` rows through `detailStepDelta` (and the direction),
`.canvasTool` rows through `toolShortcut`, `.delete` rows through `deleteIntent`
(and the tier). Rows filed as having no decoder are checked the other way — none of
the decoders may claim them, which is how a misfiled row is caught.

### What the collision test found

**No collisions.** The table is clean, and the two detector tests prove the check
can actually fail (a same-scope duplicate and a `.global` row shadowing a surface
row are both caught).

Writing the map down did surface three facts a passing test cannot express, recorded
in the file's own doc comments:

- **⌘D's two meanings are isolated by convention, not by construction.** *Favorite*
  is `Edit ▸ Favorite`, an app-wide **menu key equivalent** gated on
  `canToggleFavorite` — which reads the *collection grid's* selection. *Duplicate*
  is a sibling `keyboardShortcut` on the board's action bar. They are filed under
  different scopes because that is how a user experiences them, and the decision is
  to keep both. But nothing in the code enforces the split.
- **Home breaks the two-tier delete rule.** Everywhere else `ef5201d` established
  "⌫ removes from the container in view, ⌘⌫ deletes from the library". On the Home
  gallery a bare ⌫ *deletes* the selected collections and spaces outright (behind a
  confirmation) — it is `SwiftUI`'s `.onDeleteCommand`, which never sees a modifier,
  so it cannot route through `deleteIntent` at all. Noted in the table for whoever
  revisits [073]; not changed here.
- **⌘Z / ⇧⌘Z are one chord over two undo stacks.** The menu drives the model's;
  a Space overrides both with the board's. Same verb, so one row — but worth knowing.

### The `M` / `A` rows

`KeyMap.planned`, a **separate array** that the sheet does not render and `KeyMap.all`
does not contain. [024] is explicit that "a table row without a binding is a lie the
collision test cannot catch", so a user is never shown a key that does nothing, and
a test asserts no planned row leaks into the bound table. They are still written down,
because the collision test runs over `all + planned` too: K3 gets a failing build the
moment `M` or `A` stops being free, instead of finding out by hand.

The conflict facts K3 can rely on are in the table and pinned by
`plannedKeysAreFreeInTheDecoders`: `V`/`F`/`T` are taken on the canvas, `X` is taken
in the grid, no other bare letter is claimed on either, and **both decoders require
bare modifiers** — so ⌘A stays Select All and ⌘M is nobody's. The constraint every
bare letter lives under (never fire while a text box has the keyboard) is documented
with the three different ways the three surfaces currently solve it.

## K2 — the sheet

Help ▸ **Keyboard Shortcuts (⌘/)**. A sheet, not a Settings tab: Settings is where
things you *change* live; this is reference you open mid-task and dismiss.

- One card per scope, headed and subtitled with the surface it applies to. The
  subtitle is load-bearing rather than decorative — it is what makes ⌘D read as two
  surfaces instead of one contradiction.
- Chords render as `field` key caps on a `hairlineStrong` border, alternates side by
  side (`⌘=` `⌘+`). Existing `Theme` tokens throughout; nothing new invented.
- **Scope-aware**: `NavModel`'s `sidebarSelection` + `presentedItemID` already say
  where you are, so the matching card is marked "Where you are" and scrolled to.
  Item detail wins over the sidebar selection — the overlay is raised *from* a
  collection, so reading the selection alone would always answer "Collection" behind
  it. The mapping is pure and unit-tested, including "every scope the sheet can open
  on has rows to show".
- **Not** editable rebinding, and the page's own footer says so rather than leaving
  it implied.

⌘/ was verified unbound; `?` is free too, and ⌘/ is the convention users arrive with.
The item is added **after** the default Help item, not in place of it — this phase
adds a menu item, it does not remove one.

## K4 — [011] amended

`.docs/feature-todo/011-ux-features.md` Cluster C-2 said **M** = "Move to…" and
**⇧M** = "Add to…". Amended to **M** / **A**, with an inline note saying it was
amended by [024] and why: `A` is mnemonic, it is one hand, and ⌘A being Select All
means the bare key is not confusingly "nearly" taken. [011] is unbuilt and neither
key is bound today, so nothing migrates.

## A deviation from the plan, stated

[024] specified six scopes: `.global | .collection | .detail | .space | .gallery |
.search`. There are **seven** — `.sidebar` was added, because the sidebar grew real
key bindings *after* [024] was written (`2b5560d`: Enter renames the selected row,
→/← expand and collapse). A keyboard map that omits the newest bindings in the app
fails its one job, and the alternative — filing them under `.global` — would have
been false (they only fire while the outline view holds first responder) and would
have manufactured a collision against the grid's Return.

## Files changed

- `AtelierRefs/AtelierRefs/KeyMap.swift` (new) — the table, the collision detector,
  and the pure "where are you" mapping.
- `AtelierRefs/AtelierRefs/KeyboardShortcutsSheet.swift` (new) — the page.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — Help ▸ Keyboard Shortcuts (⌘/).
- `AtelierRefs/AtelierRefs/NavModel.swift` — `showShortcuts`, the route state the
  menu command flips (a `Scene`-level command has no view to hang a sheet on).
- `AtelierRefs/AtelierRefs/AppShellView.swift` — presents the sheet and resolves the
  scope at presentation, so the sheet itself takes a plain value.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `toolShortcut`
  made `public`, for the same reason `deleteIntent` already is: the contract test
  that keeps the table honest lives in the app's suite, which can only see the
  package's public surface. No behaviour change.
- `AtelierRefs/AtelierRefsTests/KeyMapTests.swift` (new) — 19 tests: the collision
  test, two detector tests proving it can fail, the contract tests against all four
  decoders, and the scope mapping.
- `.docs/feature-todo/011-ux-features.md` — C-2 `⇧M` → `A`.

No existing binding's behaviour changed.

## Verification

`xcodebuild build … -destination 'generic/platform=macOS'` — succeeded (only
pre-existing warnings).

Full suite, measured before and after in this tree: **1431 passed / 0 failed** →
**1470 passed / 1 failed**. The one failure is
`CollectionDestinationPerfTests.coldBuildIsCheap()`, from [343]'s untracked
`CollectionDestinationTests.swift` — a different agent's file, not touched here. All
19 KeyMap tests pass.

The sheet is view code: compile-only plus manual, per repo convention.

## Migration notes

None.
