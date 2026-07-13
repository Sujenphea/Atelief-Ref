# 009 — Multi-Select & Move Between Collections (Unsorted Stacks + Drop Rail)

> Covers the post-004/005 organization gaps: **no way to move items between
> collections**, **no multi-select**, a Procreate-style **collection-stack row at the
> top of Unsorted** (drop to move), and a **floating collections rail** inside a
> collection that expands into named drop targets when a drag approaches. One coherent
> feature: triage/organization. Builds directly on the landed 004 shell
> (`AppShellView`/`NavModel`/`CollectionsGalleryView`/`CollectionView`).

## Current state (verified, uncommitted main)

- **Selection is strictly single**: `IngestionModel.selectedItemID: UUID?`
  (`IngestionModel.swift:70`), `select(_:)` (`:531`). Every consumer (detail overlay,
  keyboard nav `CollectionView.swift:206`, delete `:189`) assumes one item.
- **Grid click opens detail immediately** (`CollectionView.swift:157–160`) — there is
  no "select without opening" gesture, which multi-select requires.
- **Drag exists only for in-grid reorder**: cells are
  `.draggable(detail.asset.id.uuidString)` with a `String` `dropDestination` on each
  cell (`CollectionView.swift:168–171`, `reorder` `:229–234`). Single item only; the
  payload is a bare UUID string with no source-collection context.
- **No atomic move**: `addAssets` (`AppServices.swift:321`) and `removeAssets`
  (`:345`) are batch, idempotent, each one transaction — but a "move" today would be
  two separate write-funnel transactions.
- **Gallery cards are single-cover and non-droppable**
  (`CollectionsGalleryView.swift:35–41`); no stack rendering, no drop targets
  anywhere outside the grid.
- Batch-shaped model methods already exist: `removeFromFolder(assetIDs:)`,
  `requestDelete(assetIDs:)` take arrays — the UI just never passes more than one.

## Design

### 1 — Atomic move service (foundation)

**`moveAssets(_ assetIDs: [UUID], from: UUID, to: UUID)`** in AppServices, ONE
transaction: validate target collection + assets exist (`.notFound` rolls back) →
insert missing target memberships (skip existing — 18A-style dedup, an asset already
in the target simply loses its source membership) → delete source memberships.

- ✅ Crash-safe: never a state where the item vanished from both or duplicated
  half-moved. Explicit single verb for the domain's most common triage action.
- Rejected: UI chaining `addAssets` + `removeAssets` — two transactions, a crash
  between them leaves the item in both (benign but silent), and it scatters move
  semantics across call sites (DRY).
- Semantics: `from == to` → no-op; moving **into** Unsorted allowed (un-triage);
  moved items land at the target's feed end (no `manual_order` yet — same as any
  fresh `addAssets`). "Copy" needs no new service — it IS `addAssets`.

### 2 — Selection model (settled: hover-circle + Google-Photos mode)

Replace `selectedItemID: UUID?` with `selectedItemIDs: Set<UUID>` +
`anchorItemID: UUID?` (⇧-range pivot) + `leadItemID: UUID?` (the item the detail
overlay shows / keyboard cursor). **Selection mode is derived, not stored**:
"selecting" simply means `!selectedItemIDs.isEmpty` — no separate flag to drift.

The interaction contract (settled):

- **Idle (empty selection): plain click on a thumbnail opens detail** — unchanged
  from today. Hovering a cell reveals an **open circle at the top-right** of the
  image; clicking the circle selects the item (entering selection mode) without
  opening detail.
- **While selecting (non-empty selection)**: circles are visible on ALL cells
  (filled check on selected ones), and a plain click on any thumbnail **toggles**
  it instead of opening detail (no accidental detail-opens mid-triage). Esc,
  deselect-all, or click-empty-background clears the selection and exits the mode;
  clicks open detail again.
- **⇧-click** ranges from the anchor in feed order — in or out of selection mode
  (Shift signals intent, so it never opens detail). **⌘-click** toggles (a
  keyboard-savvy alias of the circle). **⌘A** selects all; **⇧-arrow** extends the
  range via the existing `nextGridIndex` math; plain arrows move the `leadItemID`
  cursor; **Enter** opens the cursor item's detail (006's planned invocation).
- All of it lives in a **pure `GridSelection` helper** (the
  `GridNavigation`/`GridReorder` pattern — SwiftUI-free, exhaustively unit-tested):
  a reducer over (click kind, modifiers, mode) → new selection + effect
  (`openDetail` vs `none`), so the mode-dependent click semantics are testable
  without UI.
- **Marquee**: a drag gesture on the scroll content's background. The virtualization
  trap — `LazyVGrid` only lays out *visible* cells, so live cell frames can't drive
  hit-testing for offscreen rows. Solution: **compute, don't measure** — the layout's
  frames must come from pure math. With [011](./011-ux-features.md)'s settled move to
  **justified rows**, that math is the `JustifiedLayout` helper: it returns every
  item's frame as pure data (offscreen included), and marquee resolution becomes
  rect-intersection over those frames — exact and trivially testable. (Under today's
  uniform grid the same idea uses `gridColumnCount`/cell-size math,
  `CollectionView.swift:212` — don't build that variant if U2 lands first; sequence
  N6 with 011-U2.) Keyboard `nextGridIndex` nav swaps to neighbor lookup over the
  same frame data. Gesture arbitration with scrolling: begin marquee only from empty
  background hits (not on a cell) with a small movement threshold; edge auto-scroll
  via `ScrollViewProxy` stepping.

### 3 — Drag payload (shared by reorder, stacks, rail, gallery)

A custom `Transferable`/`Codable` **`AssetDragPayload`**: `assetIDs: [UUID]` +
`sourceCollectionID: UUID`, under an exported custom `UTType`
(`com.ref-atelier.asset-ids`). Replaces the bare-`String` payload everywhere.

- Dragging a **selected** cell drags the whole selection; dragging an **unselected**
  cell first selects it (Finder convention), so drag count always equals selection.
  Drag preview = thumbnail with a count badge for >1.
- **In-grid reorder goes multi**: dropping a payload on a cell inserts the dragged
  set as a contiguous block at the target index, preserving the set's current feed
  order — a pure extension of the `GridReorder` helper. Reorder remains meaningful
  only in manual sort mode (007's rule applies unchanged).
- **⌥-copy detection**: SwiftUI's `dropDestination` doesn't surface modifiers; read
  `NSEvent.modifierFlags.contains(.option)` at perform time (small AppKit escape
  hatch, isolated in one helper so it's mockable). ⌥ → `addAssets` (source kept),
  plain → `moveAssets`.

### 4 — Unsorted stack row (settled: root collections only)

Shown only when `collectionID == unsortedFolderID`, a horizontal scroll of
**`CollectionStackCard`s** — one per root collection (Unsorted excluded): the
collection's 3 most-recent thumbnails fanned with slight rotations, name + count
below. Rotation is **seeded by the collection UUID** (stable across refreshes — no
jitter), "random" only in appearance.

- Data: one new read `collectionStackPreviews(limit: 3)` → `[(collection, count,
  [blobHash])]` via a window-function query (`ROW_NUMBER() OVER (PARTITION BY
  collection_id ORDER BY added_at DESC)` — SQLite on macOS 26 is far past 3.25).
  Rejected: N queries per collection (chatty), reusing the single `cover_asset_id`
  (a stack of one isn't a stack; covers stay the *gallery's* concept).
- Each stack is a `dropDestination(for: AssetDragPayload.self)` →
  `moveAssets(from: unsorted, to: that collection)` (⌥ = copy). `isTargeted` scales
  the stack up slightly — the Procreate affordance.
- Subfolder targets are deliberately out (settled): move to the root, re-triage
  inside. Spring-loaded stack expansion is a possible v2.

### 5 — Floating drop rail (settled: always visible, expands on drag)

On every collection screen **except Unsorted** (which has the stack row; one screen,
one metaphor): a slim floating rail pinned to the trailing edge — tiny cover
thumbnails (~28 pt), always visible. When a drag approaches the trailing edge, the
rail **expands** to named rows; each row is a drop target (`moveAssets` /
⌥-`addAssets` from the current collection). When no drag is in flight, **clicking a
row navigates** (`nav.openCollection`) — the rail doubles as quick-switch.

- **Proximity detection without new gesture machinery**: a transparent full-height
  strip (~120 pt) layered over the grid's trailing edge that is itself an
  `onDrop(isTargeted:)` no-op target — its `isTargeted` flips the rail into the
  expanded state; the rail's own row targets take over from there. Pure SwiftUI,
  no drag-session plumbing.
- Contents: the current collection's **direct subfolders first**, then **root
  collections** (current + Unsorted's position: Unsorted included — dragging back to
  Unsorted is legitimate un-triage). Scrolls if long. The rail is a *drop/switch*
  surface, not a tree — it does not reintroduce the removed persistent sidebar.
- Rejected: drag-only materialization (no discoverability, no quick-switch — user
  chose against) and always-expanded (it *is* the removed sidebar).

### 6 — Menu path (accessibility + discoverability)

Batch context menu on any selected cell, acting on the whole selection:
**Move to ▸** / **Add to ▸** submenus (subfolders + roots, same list as the rail),
plus the existing Remove from Collection / Delete now passing all selected IDs.
Dragging must never be the only way to move — keyboard/menu users get the same verbs.

## Schema / migration impact

**None.** No new tables or columns — `moveAssets` and `collectionStackPreviews` are
additive service/read methods over existing rows. (A rare organization feature with
zero migration risk.)

## Phased implementation

1. **N1 (S) — core verbs.** `moveAssets` + `collectionStackPreviews` in AppServices
   + full service tests. Pure core, no UI.
2. **N2 (M) — selection model.** `GridSelection` pure reducer + tests; model swap to
   `selectedItemIDs`/anchor/lead; hover-circle overlay on cells; mode-dependent
   click (idle → detail, selecting → toggle); batch context menu with Move to ▸ /
   Add to ▸; ⇧-click/⌘-click/Esc/⌘A/⇧-arrow/Enter.
3. **N3 (M) — drag unification.** `AssetDragPayload` + UTType; multi-drag with count
   badge; multi-item `GridReorder` block insertion; ⌥ modifier helper.
4. **N4 (M) — Unsorted stack row.** `CollectionStackCard` (fan + seeded rotation),
   stack previews wiring, drop-to-move with targeted feedback.
5. **N5 (M) — drop rail.** Proximity strip + expand animation, subfolders+roots
   list, drop-to-move, click-to-navigate.
6. **N6 (M) — marquee.** Background drag gesture, pure rect→indices math, edge
   auto-scroll, threshold arbitration vs scroll.

N1–N3 are strictly ordered; N4/N5/N6 are independent after N3 and can land in any
order (marquee last keeps the riskiest gesture work off the critical path).

## Test strategy

- `moveAssets`: atomicity (missing target/asset rolls back the whole batch), dedup
  into target (already-member loses source membership only), `from == to` no-op,
  empty batch, Unsorted round-trip, cover-asset moved away (cover survives —
  membership ≠ cover), order-lands-at-end.
- `GridSelection` pure matrix: every (click kind: image/circle × modifier) ×
  (idle/selecting × target selected/unselected) state, asserting BOTH the new
  selection AND the effect (idle image-click → `openDetail`; selecting image-click →
  toggle, never `openDetail`; ⇧/⌘-click never `openDetail` in any state); ⇧-range
  across anchor moves; ⌘A/Esc; deselect-last exits the mode; ⇧-arrow at grid edges;
  marquee rect→indices across column counts, partial rows, zero-size rects, rects
  past content bounds.
- `GridReorder` multi-block: contiguous/non-contiguous sets, drop inside the dragged
  set, feed-order preservation, single-item regression.
- `AssetDragPayload` Codable round-trip; ⌥-detection helper behind a protocol
  (injectable `ModifierReader`) so move-vs-copy routing is unit-testable.
- `collectionStackPreviews`: 0/1/3/5-item collections, recency order, root-only
  filter, deleted-asset holes.
- Rotation seeding: same UUID → same angles (pure function test).
- Views compile-only per repo convention; manual pass for marquee-vs-scroll feel and
  rail expand timing.

## Effort: **L total** (N1 S · N2 M · N3 M · N4 M · N5 M · N6 M)

The full-set-in-v1 selection decision (marquee + ⇧-arrow) is what pushes this from M
to L — N6 alone is the fiddliest gesture work in the set.

## Risks & edge cases

- **Marquee vs ScrollView** is the one genuinely risky interaction: begin-from-
  background + movement threshold usually suffices on macOS, but budget manual
  tuning time; the index math itself is pure and safe.
- The marquee's frame source must match the shipped layout: [011](./011-ux-features.md)
  settles justified rows, so build N6 against `JustifiedLayout`'s frames (land N6 and
  011-U2 in the same window; don't implement uniform-grid marquee math that U2 would
  immediately obsolete).
- `NSEvent.modifierFlags` at drop time is global state — isolate behind the
  injectable helper; document that drop-modifier UX (cursor badge) can't fully match
  AppKit's `NSDraggingDestination` without dropping to AppKit later.
- The derived mode has one sharp edge: deselecting the **last** selected item
  instantly exits selection mode, so the very next image click opens detail — a
  surprise if the user was mid-toggle. Deliberate (explicit over clever — no hidden
  sticky-mode timer), but verify it feels right in the manual pass.
- Hover is pointer-only — the circle affordance needs the cell itself to stay a
  valid selection target via ⇧/⌘-click and marquee for completeness (it does).
- Selection must survive a feed reload only for IDs still present (prune on `items`
  change — extend the existing stale-`selectedItemID` guard,
  `IngestionModel.swift:480`); detail overlay keeps working off `leadItemID`.
- Moving the item currently open in detail: overlay already auto-dismisses via the
  `selectedItem != nil` guard — keep that property through the model swap.
- Stack row and rail must ignore drops of their own source (`from == to`) and
  foreign/malformed payloads (decode failure → refuse, never crash).
- Delete/Remove with a large selection goes through the existing confirmation alert —
  make the count explicit ("Delete 34 items?").

## Settled decisions (user, 2026-07-13)

- Drag **moves**; **⌥-drag copies** (adds without removing) — one gesture, standard
  modifier, exposes multi-membership deliberately.
- **Full multi-select set in v1**: hover circle + mode toggling + ⇧-click ranges +
  ⌘A/Esc + marquee + ⇧-arrow extension.
- **Single click opens detail when idle** (unchanged behaviour); selection starts
  from the **hover circle at the image's top-right**; while a selection exists,
  image clicks **toggle** (Google Photos model) and Esc/deselect-all exits.
- **Drag-to-select = the background marquee only** — no circle-sweep/paint gesture;
  image-drag always means move/copy, background-drag always means marquee.
- Stack row = **root collections only**, Unsorted screen only.
- Rail = **always visible, minimized; expands on drag approach**; click-to-navigate
  when idle.

## Open questions

1. Should the **home gallery cards** also accept drops (move into a root collection
   from… nowhere draggable today — only becomes meaningful if a future screen drags
   over the gallery)? Recommend: not in v1; revisit if search results become
   draggable.
2. Rail ordering: subfolders-then-roots (recommended) vs most-recently-used-first?
3. Multi-item drag preview: count badge on the lead thumbnail (recommended) vs a
   mini-fan of up to 3 thumbnails (prettier, more work)?
4. Does ⇧-arrow also scroll the newly included item into view (recommend yes, reuse
   the existing `scrollTo` path)?
