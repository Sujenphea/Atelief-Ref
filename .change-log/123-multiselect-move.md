# 123 — Multi-select & move between collections (009)

Adds the triage/organization layer the post-004/005 shell was missing: **atomic
moves between collections**, **full multi-select** (hover-circle + Google-Photos
mode + ⇧-range + ⌘A + marquee + ⇧-arrow), a Procreate-style **collection stack
row** on the Unsorted screen (drop to move), and a **floating drop rail** on every
other collection screen (expands on drag, quick-switch on click). Drag **moves**;
**⌥-drag copies**. One coherent feature across six phases (N1–N6).

## What ships

### Core (AtelierCore)
- **`moveAssets(_:from:to:)`** — the atomic triage verb, ONE transaction: validate
  source+target+assets (`.notFound` rolls back the whole batch), dedup into the
  target (an already-member asset just loses its source membership), then drop the
  source membership (idempotent). `from == to` / empty batch are no-ops. Moved
  items **append** to the target's `manual_order` so they land at its feed END
  (17A — NULLs sort first, so without the append a move into an arranged grid would
  surface at the front). `addAssets`/`removeAssets` are unchanged.
- **`collectionStackPreviews(limit:)`** + `CollectionStackPreview` — one
  window-function read (`ROW_NUMBER() OVER (PARTITION BY collection_id …)`)
  returning every root collection (Unsorted excluded) with its count + newest
  thumbnail hashes. No N+1.

### App (AtelierRefs)
- **`GridSelection`** — the pure, exhaustively-tested selection reducer
  (`ids`/`anchor`/`lead`, mode derived): every gesture/key is an action →
  `(nextSelection, Effect)`; the mode-dependent "open vs toggle" lives here, views
  only execute effects (11A). `pruned(to:)` is a pure reload transition (10A).
- **Model swap** — `selectedItemID` → `selection: GridSelection` (2A); `select()`
  split into a pure `applySelection(_:)` and an `openItem(_:)` that alone loads the
  preview/tags (8A — no large-JPEG decode on a toggle or ⌘A). Batch move/copy verbs.
- **`CollectionCell`** — extracted, `Equatable` (13A): hover/selection circle,
  keyboard-cursor ring, raw-input routing; clicks decoded via `NSEvent`.
- **`AssetDragPayload`** (+ exported `com.ref-atelier.asset-ids` UTType, declared
  in `Info.plist`) — the ONE drag payload (asset ids + source collection);
  multi-drag with a count badge.
  Scope mirrors `actionTargets`: dragging a selected cell drags the whole
  selection, dragging an UNSELECTED cell drags just that one cell — a single-item
  drag that **leaves the selection untouched** (an idle drag ends idle, not stuck
  in selection mode); no count badge on the lone drag.
- **`DropRouter`** — the ONE pure drop decision (reorder / move / copy / reject),
  edge cases (from==to, foreign source, empty payload, non-manual reorder, ⌥ both
  ways) in one tested place (12A); `ModifierReading` isolates the ⌥ read.
- **`GridReorder`** multi-block insertion — a non-contiguous/reverse-picked
  selection lands as one contiguous run in feed order (single-item wrapper kept).
- **`CollectionTargets`** — the ONE collection-ordering helper (6B); the gallery,
  the Move/Add menus, and the rail all resolve their list here (gallery's old
  `orderedRoots` refactored onto it).
- **Unsorted stack row** (`CollectionStackCard`) — UUID-seeded fan tilt
  (process-stable, no jitter), drop-to-move with a targeted scale; loaded via the
  `loadContents` funnel with concurrent `async let` reads (16A) + Equatable
  publish-skip (15A).
- **Floating drop rail** (`CollectionDropRail`) — trailing, minimized covers that
  expand on drag-approach (the rail's own footprint is the proximity target, 3A —
  no click-stealing overlay strip); click-to-navigate when idle.
- **Marquee** (`MarqueeMath`) — a permanent layout-agnostic rect→indices core fed
  by a **temporary** uniform-grid frame source (1A, replaced by 011-U2's
  `JustifiedLayout`); ⇧-additive, click-clears, scroll-follow. Overlap is
  boundary-aware: an area marquee uses STRICT overlap so a drag ending exactly on
  a row/column line doesn't sweep in the neighbour, while a click / axis-aligned
  thin drag (zero-area) stays edge-inclusive so it still registers the cell it
  lands on.

## Schema / migration

**None** at the DB layer — `moveAssets` and `collectionStackPreviews` are additive
service/read methods over existing rows.

**Build config:** the app now ships a physical `AtelierRefs/Info.plist`
(`INFOPLIST_FILE = Info.plist`, still merged under `GENERATE_INFOPLIST_FILE = YES`)
declaring the drag type in `UTExportedTypeDeclarations`. Without that declaration
the OS doesn't recognize `com.ref-atelier.asset-ids` at a drop destination and
every drag (reorder / stack-move / rail-move) shows an invalid cursor and snaps
back — verified fixed by manual reorder after registering it.

## Files changed

- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` (moveAssets,
  collectionStackPreviews), `Services/ServiceTypes.swift` (CollectionStackPreview).
- `AtelierRefs/AtelierRefs/`: new `GridSelection`, `CollectionTargets`,
  `CollectionCell`, `AssetDragPayload`, `DropRouter`, `CollectionStackCard`,
  `CollectionDropRail`, `MarqueeMath`; edited `IngestionModel`, `CollectionView`,
  `CollectionsGalleryView`, `GridReorder`.
- Tests: new `ServicesMoveTests` (core), `GridSelectionTests`,
  `CollectionTargetsTests`, `DropRouterTests`, `FanRotationsTests`,
  `MarqueeMathTests`; extended `GridReorderTests` (multi-block).

## Tests

Core **swift test** green (327 tests, incl. the 19 new move/stack-preview tests).
App unit bundle green (0 failures). Views
are compile-only per repo convention; marquee-vs-scroll feel and rail expand timing
need a manual pass (the risk note's edge auto-scroll is a lightweight scroll-follow
pending 011-U2's justified frames).

## Notes

- Selection ids are **membership ids** (survive a reload, drive the detail overlay);
  the drop/move/delete boundary maps them to asset ids via the loaded items.
- Deselecting the last item instantly exits selection mode (the deliberate "sharp
  edge" — explicit over a hidden sticky-mode timer); verify it feels right manually.
- The stack row targets **root collections only** (re-triage inside after moving);
  the rail lists **direct subfolders then roots** (Unsorted included — un-triage).
