# 011 — User-Experience Features: Out-Flow, Browsing Feel, Speed, Palette

> Covers the daily-feel layer docs 001–010 don't: getting refs OUT of the app,
> browsing quality (justified grid, density, Quick Look, motion), speed tools
> (⌘K, keyboard triage, favorites), per-item notes, capture feedback, and a
> floating always-on-top reference palette. All four clusters were confirmed as
> v1 priorities (user, 2026-07-13).

## Status (re-verified against the tree 2026-08-10)

**Five of seven phases have shipped.** Two remain, and they are the whole reason
this doc is still in the backlog:

| Phase | State | Where |
|---|---|---|
| U1 out-flow | **shipped, all three** | `AssetExport.swift` (+`AssetExportTests`), `AssetFilePromise.swift`, `AssetPasteboard.swift`; ⌘C in `4be6f88`. A2 batch export + A3 share sheet in `.change-log/385` — `AtelierExport/Assets/AssetFolderWriter.swift`, `AssetFolderExport.swift`, `AssetShare.swift` |
| U2 justified grid + density | **shipped, as masonry** | `MasonryLayout/CollectionLayout/GridHost/GridItem/LayoutCache`, `GridDensity.swift`. Landed as a masonry layout rather than the justified-rows sketch below; marquee + keyboard nav consume its frames as planned (`MarqueeMath`, `GridNavigation`) |
| U3 Quick Look + toasts | **shipped** | `QuickLookController.swift`, `ToastQueue.swift` (+`ToastQueueTests`) |
| U4 ⌘K switcher + triage | **half shipped** | `M` / `A` triage landed (`.change-log/348`, `MoveAddShortcutTests`, `KeyMap`). **The ⌘K quick switcher does not exist** — no switcher type anywhere in the app target |
| U5 favorites | **shipped** | schema **v19** `asset.is_favorite`, ⌘D, star chip, search token (`567c302`, `ServicesFavoritesTests`, `AppFavoritesTests`) |
| U6 floating palette | **not started** | `AtelierRefsApp.swift:30` declares one `WindowGroup`; no auxiliary window, no `.windowLevel(.floating)` |
| U7 notes | **shipped** | schema **v10** `asset.note` + `AppServices.setNote` (`:2752`); searchable via v12 |

So the live remainder is **U4's ⌘K switcher** and **U6's floating palette** —
both M, both zero-schema, neither blocked by anything.

The `is_favorite` and `note` migration slots this doc speculated about are spent:
`note` rode v10, `is_favorite` landed as its own v19. Schema impact from here is
**zero**.

## Current state at the time of writing (historical — see Status above)

- **Nothing leaves the app.** No `NSFilePromiseProvider`/`Transferable` file
  representation anywhere — the grid drag payload is internal-only ([009]'s
  `AssetDragPayload`); no ⌘C, no share sheet. The payoff loop of a reference tool
  (drag a ref into Figma) is impossible today.
- **Grid is uniform fixed-density**: `.adaptive(minimum: 112, maximum: 140)` square-ish
  cells (`CollectionView.swift:30`), no size control, crops tall/wide refs.
- **Quick Look exists but only from Spaces** (`QuickLookPresenter.swift`, used by
  `SpaceView`) — no spacebar preview in the grid.
- **No favorites, no notes** — neither column exists on `asset`; no ⌘K switcher; no
  keyboard move-to-collection; remote captures land with no in-app feedback.
- Justified-row layout math already exists for canvas flow-in (reused by
  `AddFromLibrarySheet`) — the exact math the grid needs.

## Cluster A — Get refs out (the payoff loop)

1. **Drag-out**: every draggable cell/detail/space tile carries BOTH the internal
   `AssetDragPayload` AND a file representation. Internal drops keep preferring the
   payload (009 semantics untouched); external targets (Figma, Finder, Photoshop)
   receive the original file. Mechanism: `Transferable` `FileRepresentation`
   exporting the blob with a human filename (`<title-or-source>-<shorthash>.<ext>`,
   the [081](../081-backup-plan.md) export sanitizer — build once, share). Blobs are already immutable
   files on disk, so export = copy/hardlink to a promise temp dir, no re-encode.
   - Rejected: `NSFilePromiseProvider` via AppKit subclassing — the `Transferable`
     route composes with the SwiftUI `.draggable` already in use; drop to AppKit
     only if receiver compatibility testing forces it.
2. **⌘C** in grid/detail: image bytes + file URL + source URL on the pasteboard
   (multi-select → multiple files). **⌘⌥C copies the source link** (matches the
   existing detail action).
3. **Share sheet** (`ShareLink`/`NSSharingServicePicker`) on detail + context menu:
   cheap once file export exists. — *Effort: M total; zero schema.*

**All three shipped** (`.change-log/385`), plus one this sketch did not name: a
**batch folder export** (`File ▸ Export Assets…`, the selection popover, the
right-click menu) writing the originals into a folder the user names. That is what
`AssetExport.swift:6` meant by "the future ⌘C / 008 export all", and what
`ExportNameAllocator` was written for — it is the caller that needs many names side
by side in one destination, which no single drag ever did.

Two decisions worth keeping, both departures from the sibling exports:

- **Videos export as the video**, where the web page ([082](../082-sharing-out-plan.md))
  copies only a poster frame. The originals are the product here.
- **No config popover.** The other three exports each open one; this has nothing to
  configure, so the click goes straight to the save dialog.

Byte-less refs (a colour, an image-less link/tweet) are reported skips rather than
invented sidecars — the text fallback stays a ⌘C affordance. The archive shelf is
deliberately excluded from both verbs; Space boards still export moodboards rather
than originals.

## Cluster B — Browsing feel

1. **Justified rows** (settled): aspect-preserving rows replace the uniform grid in
   `CollectionView`. Reuse the canvas flow-in math as a pure `JustifiedLayout`
   helper (rows target a height, scale to fill width; last row left-aligned).
   Ripple (handled): [009]'s marquee switches from computed uniform geometry to the
   layout's own frames — `JustifiedLayout` returns every item's frame as pure data,
   so marquee hit-testing stays exact for offscreen items AND fully unit-testable;
   `nextGridIndex` keyboard nav swaps to row/column neighbor lookup on the same
   frame data. 009 §2 updated to match.
2. **Density control**: ⌘+/⌘− (and a toolbar slider) steps the target row height
   through ~4 notches. Stored in UserDefaults — a pure *view* preference, unlike
   007's `sort_mode` which changes data semantics and lives in the library. Global,
   not per-collection (one muscle memory).
3. **Spacebar Quick Look** in the grid: reuse `QuickLookPresenter`; multi-select →
   QL flips through the selection. Space toggles, stays independent of the detail
   overlay (QL = ephemeral peek; detail = the work surface).
4. **Motion policy**: GIFs animate in detail always, in grid **on hover only**
   (decode cost); videos show a muted hover-preview loop in grid at v1.5 (needs a
   pooled player — don't block v1). Poster frames remain the default everywhere.
5. **Capture feedback**: a small toast queue (pure model, tested) — remote capture
   lands → "Saved to Unsorted — Jump" (invokes `nav.openCollection` + select). One
   toast per batch, not per item, on the bulk path. — *Effort: M–L total (B1 is the
   bulk); zero schema.*

## Cluster C — Speed

1. **⌘K quick switcher**: a floating palette over the shell — type-ahead across
   collections, spaces, and verbs ("New Space", "Snapshot now"), recents first.
   Pure fuzzy-match/ranking helper (tested); selection routes through `NavModel`.
2. **Keyboard triage**: with a non-empty [009] selection, **M** opens "Move to…"
   (same type-ahead list, Enter moves via `moveAssets`), **A** = "Add to…" (copy
   semantics). Complements drag; no number-key bindings v1 (collections are
   dynamic; muscle-memory slots can come later as pins).
   > *Amended by [077] K4: `⇧M` → `A`.* [077] settles the same pair for Spaces, and
   > shipping two spellings of "Add to…" is the exact failure that doc exists to
   > prevent. `A` is mnemonic, it is one hand, and — since ⌘A is already Select All —
   > the bare key is not confusingly "nearly" taken. Nothing migrates: this cluster
   > is unbuilt, and neither key is bound today (see `KeyMap.planned`).
3. **Favorites** (settled: simple flag): `asset.is_favorite` boolean, **⌘D**
   toggles (works on selection), star chip in grid cells + detail, a favorites
   filter token in [007]'s search field and a filter chip on collection screens.
   Exported in [081]'s manifest. — *Effort: M total; one tiny additive migration
   (`is_favorite` — can ride 007's migration slot).*

## Cluster D — Floating reference palette

A compact always-on-top auxiliary window (`WindowGroup(id: "palette", for:
Space.ID.self)` + `.windowLevel(.floating)`, macOS 26 SwiftUI) showing one chosen
space or collection as a mini grid/board while the user designs in another app.

- **v1 is read-only + drag-out** — its entire job is *reference while working*:
  glanceable, drag a ref out into the design tool (Cluster A makes that work).
  No editing, no selection model, no toolbars; a picker to swap what it shows.
- Rejected for v1: pinning multiple palettes (one window, one focus), editing in
  the palette (duplicates the main surface's interaction model at miniature scale).
- Risks: `@main` scene plumbing must not double-instantiate `IngestionModel` —
  the palette gets a read-only projection of `AppServices` reads + thumbnail
  store, not a second full model. — *Effort: M; zero schema.*

**Built** ([099 · P6](../099-mac-backlog-plan.md),
[476](../../.change-log/476-the-palette-is-the-second-window.md)), with **two
departures from the sketch above, both deliberate**:

- **`Window`, not `WindowGroup(id:for:)`.** A `WindowGroup` opens a NEW instance per
  `openWindow(id:)`; a `Window` raises the one that exists. Since this cluster's own
  first rejection is *pinning multiple palettes (one window, one focus)*, the scene
  type that cannot make a second one is the one that states the rule. The `for:
  Space.ID.self` value type goes with it: what the palette shows is app-level state
  (`PaletteModel`), remembered per library, not a value carried in a window's identity.
- **A collection or a saved search, not "one chosen space or collection".** A Space in
  the palette is NOT in v1. The reason is not effort: `CanvasHostView` is an editing
  model end to end — placements, a selection, an undo stack, a drop router that writes
  tile positions — so "a board, read-only" is a second renderer rather than a
  configuration. `MasonryGridHost` took a read-only configuration for the price of
  three flags. `PaletteDestinations.canShow(_:)` is where the refusal lives, as a
  `switch` with no `default`, so a later phase has to answer for it.

The risk named above did not materialise: the palette holds the SAME `IngestionModel`
(the App scene owns it, as `Settings` already did) and its own `CollectionReadModel` —
which is exactly the "read-only projection" this bullet asked for, built by 099 · 1A two
phases earlier for a different reason.

## Notes on items (settled: rides 003)

`asset.note TEXT NULL`, edited in [006]'s detail sidebar (`ItemNotesView`,
autosave-on-blur), **searchable via [003]'s `asset_fts`** (`note` joins
`search_text` composition — one FTS design, not two). Ships *with* 003's migration
rebuild, not before; the UI slot in 006 can land earlier showing provenance only.

## Schema / migration impact

- `is_favorite` — one additive column (+ partial index if the favorites filter
  proves hot). Rides the next migration slot (007's, if sequenced together).
- `note` — rides [003]'s asset-table rebuild + `asset_fts`. Everything else in
  this doc: **zero schema**.

## Phased implementation

1. ~~**U1 (M) — out-flow.**~~ **Shipped.**
2. ~~**U2 (M) — justified grid + density.**~~ **Shipped as masonry.**
3. ~~**U3 (S) — spacebar Quick Look + capture toasts.**~~ **Shipped.**
4. **U4 (M) — ⌘K switcher.** The `M` / `A` triage half shipped; the switcher
   itself is outstanding. Its ranking helper is the pure, testable core (see Test
   strategy); selection routes through `NavModel`. Note the shipped
   `CollectionDestinationList` already solves "type-ahead over collections" for
   the triage sheet — **reuse it rather than growing a second list widget**, and
   settle up front whether ⌘K is that list plus spaces plus verbs, or a genuinely
   separate surface.
5. ~~**U5 (S–M) — favorites.**~~ **Shipped** (v19).
6. ~~**U6 (M) — floating palette.**~~ **Shipped** (099 · P6, [476]) — see Cluster D's
   status block for the two departures from the sketch.
7. ~~**U7 — notes.**~~ **Shipped** (v10 `asset.note`, searchable from v12).

## Test strategy

- File export: filename sanitization matrix (shared with 008 — one suite),
  multi-select export N files, missing-blob error path; pasteboard content types.
  *(Covered: `AssetExportTests`, `AssetPasteboardTests`, plus `AssetFolderWriterTests`
  / `AssetFolderExportTests` / `AssetShareTests` for the batch + share halves.)*
- `JustifiedLayout`: pure — row fill/target height/last-row/single-item/degenerate
  (zero width, one giant image); frame-feed contract test with 009's marquee helper
  (same frames in → same selection out).
- Switcher ranking: pure fuzzy-match tests (prefix > substring > fuzzy, recents
  boost, empty query = recents).
- Favorites: service toggle idempotency, filter conjunct with 007's query builder,
  migration default false.
- Toast queue: pure — batch coalescing, auto-expiry ordering.
- Palette/QL/share: compile-only + manual pass (repo convention).

## Effort: **A: M · B: M–L · C: M · D: M** (independent; any order after their deps)

## Risks & edge cases

- Drag-out receiver quirks (Figma web vs desktop, Photoshop) — file promises are
  the compatibility long tail; test the top 3 targets early, keep the AppKit
  fallback in reserve.
- Justified rows change every frame the marquee/keyboard code sees — land U2 and
  009-N6 in the same window to avoid building uniform-grid marquee math twice
  (sequencing note added to 009).
- Hover-driven motion must respect "Reduce Motion" accessibility setting.
- Palette + single `IngestionModel`: the read-only projection must not observe
  the main window's selection (independent surfaces).
- ⌘K focus/first-responder handling inside the detail overlay and Spaces canvas
  (scope the shortcut per-screen deliberately).

## Settled decisions (user, 2026-07-13)

- All four clusters are v1 priorities: out-flow, browsing feel, ⌘K/triage/favorites,
  floating palette.
- **Justified rows** replace the uniform grid (marquee/keyboard math moves to
  layout-provided frames).
- **Simple favorite flag** (no rating). **Notes ship with 003's FTS**, not
  standalone.

## Open questions

Only the ones still live for U4 / U6 remain; 1, 2 and 4 were answered by U1, U2
and U3 shipping.

1. ~~Drag-out format for multi-select?~~ Answered by `AssetFilePromise`.
2. ~~Density notches global or per-collection?~~ Answered by `GridDensity`.
3. **Palette content: spaces only, or collections too** (recommended: both — it's
   a read-only projection either way)?
4. ~~Toast position/stacking?~~ Answered by `ToastHost` / `.change-log/352`.
5. **New — does ⌘K subsume the shipped destination list, or sit beside it?** The
   `M`/`A` sheet already does type-ahead over collections
   (`CollectionDestinationList`). Building a second ranked list for ⌘K would be
   the exact duplication [077](../077-keyboard-map-plan.md) exists to prevent.
