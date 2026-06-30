# 004 — Foundation: Plan

> Implementation plan for ref-atelier: MVP scope, phased roadmap, and testing
> strategy. Builds on the [design spec](./003-foundation-design.md); decisions in
> [overview](./001-foundation-overview.md).

The strategy: **ship a small app that works end-to-end**, then expand in additive
phases. Every MVP decision is made with later phases in mind so growth doesn't
require a rewrite.

## MVP — the smallest lovable version

**Goal:** capture references locally, organize them into collections, and browse
them in grid and canvas — with provenance intact.

### In scope
- **Native macOS app shell** (SwiftUI + AppKit where needed).
- **Library + Collections** — create, rename, delete; the library browser.
- **Ingestion — direct input** — copy/paste (image or URL) and drag-and-drop
  (file or browser image). Every asset gets a complete Source record.
- **Ingestion — Chrome extension capture** — a "save as you browse" extension
  ingesting the current post/pin from Twitter, Pinterest, Instagram, or Cosmos
  via the authenticated session, POSTing to a localhost endpoint with full
  provenance. The primary platform path.
- **Ingestion — link resolution (fallback)** — paste a single post/pin URL →
  resolve media + provenance, when the extension isn't available.
- **Local storage** — GRDB/SQLite metadata + content-addressed blob store +
  thumbnails. Downloaded, on-device, fast.
- **Grid view** — virtualized, thumbnail-fast, reorderable.
- **Infinite canvas (basic)** — pan/zoom, free placement, viewport culling.
  Smooth before fancy.
- **Provenance everywhere** — every asset shows and can open its original source.
- **Inspector** — per-asset metadata panel.

### Explicitly deferred (but designed-for)
Bulk platform backfill · the external agent interface · tags UI (schema
reserved) · cloud sync / multi-device · nested / smart collections.

### MVP definition of done
A user can: paste/drag/extension-capture an image → it downloads and stores
locally with its source → it appears in a collection → they view that collection
in both grid and canvas → and from anywhere open the original source. Fast, no
spinners for already-captured content.

## Recommended build order

The data layer underpins everything, but the canvas is the **critical-path
risk** (no off-the-shelf renderer when native). Sequence:

1. **Canvas rendering spike (de-risk first).** A throwaway Core Animation/Metal
   tiling prototype: a few thousand dummy tiles, viewport culling, level-of-
   detail, pan/zoom. Prove the 120fps ceiling and the memory profile **before**
   building the app around it. Guard it with an XCTest `measure {}` benchmark.
2. **Data core + GRDB store** — schema, migrations, the Core Domain models
   (Asset, Source, Collection, CollectionItem), and the App Services mutation
   path. Everything depends on this.
3. **Ingestion pipeline + direct input** — paste/drag through the shared pipeline
   (hash → dedup → store → thumbnail). A working capture loop.
4. **Grid view** — the fast default, over real data.
5. **Infinite canvas (basic)** — productionize the spike against real data.
6. **Chrome extension + localhost endpoint** — the primary platform path; the
   endpoint is the seam the agent reuses later.
7. **Inspector + provenance actions** — polish the always-reachable source link.

## Roadmap (phased, additive over a stable core)

### Phase 2 — Ingestion depth
- **Bulk import / backfill** per platform (board / likes / cluster) behind the
  existing `SourceAdapter` protocol — backfills history the extension can't
  capture retroactively.
- **Extension breadth** — harden per-site content scripts; consider a
  Safari/Firefox variant.
- Robust auth handling, rate-limit backoff, resumable large imports.
- Video polish (scrubbing, poster frames); dedup review UI.

### Phase 3 — Organization & the agent
- **Tags** (user + agent-sourced), filtering, saved filters.
- **External agent interface** — localhost App Services API → CLI/HTTP → MCP
  server (reuses the extension's endpoint). Inventory, search, tag, arrange, and
  new-ingest notifications.
- New-ingest "inbox" for triage (manual or agent-assisted filing).

### Phase 4 — Views & polish
- Canvas richness: grouping, snapping, connections/links (great for Cosmos),
  LOD tuning.
- Additional views: timeline, source-grouped, graph/relationship.
- Smart / nested collections.
- Quick-capture: global hotkey, share extension, menu-bar capture.

### Phase 5 — Beyond local
- **Sync / backup** as an additive layer over the single App Services mutation
  path (seam reserved in the MVP).
- Export (to folders, to other tools); optional collection sharing.

### Sequencing principle
Each phase is **additive over a stable core** — data model, local store,
ingestion pipeline, and the single App Services mutation path are all
established in the MVP. Later phases plug into those seams (new source adapters,
new views, the agent interface, the sync engine) without reshaping what works.

> Build the smallest thing that is genuinely useful and genuinely fast, then grow
> it along the seams we deliberately left open.

## Testing strategy

Framework decision (Swift Testing primary; XCTest for UI + performance) is in
[research §testing](./002-foundation-research.md). What to test, in priority
order:

- **Data-model invariants** *(Swift Testing)* — provenance required, dedup by
  content hash, many-to-many membership without blob duplication. Correctness-
  critical and pure-logic.
- **Ingestion pipeline** *(Swift Testing)* — hash → dedup → store → thumbnail,
  including failure/resume states. Temp directories + fixture bytes, never the
  network.
- **Source adapters** *(Swift Testing, parameterized)* — over saved HTML/JSON
  fixtures per platform; never hit live platforms (they change and flake).
- **App Services / localhost API** *(Swift Testing, integration)* — the contract
  both the agent and the Chrome extension depend on; keep it stable.
- **Canvas performance** *(XCTest `measure`)* — the spike's frame-cost benchmark,
  kept as a CI regression guardrail.
- **UI flows** *(XCUITest)* — drag-drop, grid interaction, inspector.

**Project setup:** a unit test target (Swift Testing) and a UI test target
(XCUITest) — the standard Xcode template provides both. No third-party test
frameworks.
