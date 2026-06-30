# 003 — Foundation: Design (Spec)

> The technical spec for ref-atelier: architecture, data model, ingestion,
> views, and the agent interface. Decisions and their rationale live in
> [overview](./001-foundation-overview.md) and
> [research](./002-foundation-research.md).

---

## §architecture

### Guiding constraints
- **Native macOS** (Swift / SwiftUI + AppKit), optimized for speed and
  efficiency (memory, disk, render). *Decided — see [research §native-vs-web](./002-foundation-research.md).*
- **Local-first**: a content database + a local blob store for media.
- **One data core, many views** (grid, infinite canvas, future views).
- **Ingestion is pluggable** (one source adapter per platform).
- **Scriptable**: an external agent and the Chrome extension drive the app
  through one mutation path.

### Stack

| Layer | Choice | Why |
| --- | --- | --- |
| UI shell | **SwiftUI**, dropping to **AppKit** where needed | Native, fast; AppKit for the canvas and controls SwiftUI can't do well |
| Canvas rendering | **Core Animation layers / Metal** | Thousands of tiles must pan/zoom at 120fps; view-per-item won't scale |
| Metadata store | **GRDB / SQLite** | Fast, FTS5 search, explicit migrations, agent-readable. See [research §storage](./002-foundation-research.md) |
| Blob store | Content-addressed files in an app-managed Library directory | Keeps DB small; media served straight from disk |
| Thumbnails | Pre-generated, multiple sizes, cached, via Image I/O | Grid scanning must be instant |
| Networking | `URLSession` + per-source adapters | Ingestion only |
| Agent / extension API | Localhost App Services surface (see [§agent-interface](#agent-interface)) | Drive the app externally |

### Layered design

```
┌─────────────────────────────────────────────────────────┐
│ Views (SwiftUI / AppKit)                                 │
│   Library · Grid view · Infinite canvas · Inspector      │
├─────────────────────────────────────────────────────────┤
│ View Models / App Services                               │
│   selection, arrangement, search, import orchestration   │
├─────────────────────────────────────────────────────────┤
│ Core Domain (the source of truth)                        │
│   Collections · Assets · Sources · Tags                  │
│   — pure, view-agnostic, agent-agnostic                  │
├──────────────┬───────────────────────┬──────────────────┤
│ Persistence  │ Media Store           │ Ingestion        │
│ (GRDB/SQLite)│ (content-addressed     │ (source adapters │
│              │  blobs + thumbnails)  │  + paste/drag    │
│              │                       │  + extension)    │
├──────────────┴───────────────────────┴──────────────────┤
│ App Services mutation path                               │
│   used by UI, external agent, AND Chrome extension       │
└─────────────────────────────────────────────────────────┘
```

The **Core Domain** is the contract. Views, ingestion, the agent, and the
extension all sit around it; none becomes the source of truth. Routing **all
mutations through one App Services layer** is the key "architect for expansion"
decision — it's what makes the agent interface, the extension endpoint, and a
future sync engine thin additions rather than refactors.

### Storage layout
The app owns a single Library directory (user-relocatable later):

```
~/Library/Application Support/ref-atelier/   (or user-chosen location)
├── library.sqlite              # metadata: collections, assets, sources, tags
├── blobs/                       # original downloaded media, content-addressed
│   └── ab/cd/abcd…ef.jpg        # sharded by hash prefix
├── thumbnails/                  # derived, regenerable
│   └── ab/cd/abcd…ef@512.jpg
└── cache/                       # transient, safe to purge
```

- **Content-addressed blobs** (hash of bytes) give free deduplication: the same
  image saved twice stores one file, two asset records.
- **Thumbnails and cache are derived/regenerable** — excluded from backups,
  purgeable under disk pressure.

### Performance strategy
- **Thumbnails first** — grid and canvas render from pre-sized thumbnails;
  full-res loads lazily on zoom/open.
- **Virtualized rendering** — grid realizes only visible cells; canvas renders
  only tiles intersecting the viewport, with level-of-detail by zoom.
- **Off-main work** — download, hash, thumbnail, decode off the main thread.
- **Async, resumable imports** — ingestion is a queue of jobs with progress and
  retry, so a 500-item import never blocks the UI or loses work.
- **Indexed queries + FTS5** — membership, source filtering, and text search are
  indexed.

### Keep flexible
Library location (relative paths from root) · source adapters (one protocol) ·
view modules (shared protocol) · the single App Services mutation seam (for a
future sync/backup engine).

---

## §data-model

The data model is the contract every other part sits on. Small for the MVP, but
shaped so expansion is additive.

### Asset
A single piece of captured media and its provenance.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | Stable identity |
| `kind` | enum | `image` \| `video` (extensible: `gif`, `audio`, …) |
| `blob_hash` | string | Content hash → file in `blobs/`. Enables dedup |
| `mime_type` | string | e.g. `image/jpeg` |
| `width`, `height` | int | Intrinsic dimensions (layout without decoding) |
| `duration` | float? | For video |
| `file_size` | int | Bytes on disk |
| `download_state` | enum | `pending` \| `downloaded` \| `failed` |
| `created_at` | timestamp | When captured |
| `source_id` | FK → Source | **Required.** Where it came from |

> **Provenance is required.** Every asset references a `Source` — even a pasted
> image (`local_paste`) or a dragged file (`local_drag`). We never create an
> asset with no origin.

### Source
The origin of an asset — first-class and required.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | |
| `platform` | enum | `twitter` \| `pinterest` \| `instagram` \| `cosmos` \| `web` \| `local_paste` \| `local_drag` |
| `original_url` | string? | **The canonical link back to the post.** Critical |
| `author_handle` | string? | e.g. `@designer` |
| `author_name` | string? | Display name |
| `title` | string? | Post title / caption excerpt |
| `captured_at` | timestamp | When ingested |
| `raw_metadata` | JSON | Platform-specific extras, preserved verbatim |

`raw_metadata` is a deliberate escape hatch — each platform exposes different
fields (Pinterest board, tweet id, IG shortcode, Cosmos cluster); we keep the
raw blob so we never lose data we didn't model yet.

### Collection
A named grouping — the unit of organization in the library.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | |
| `name` | string | |
| `description` | string? | |
| `cover_asset_id` | FK? | Optional cover thumbnail |
| `created_at`, `updated_at` | timestamp | |

### CollectionItem (membership + per-view placement)
An asset's membership in a collection. **Many-to-many**: one asset can live in
multiple collections without disk duplication.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | |
| `collection_id` | FK → Collection | |
| `asset_id` | FK → Asset | |
| `added_at` | timestamp | |
| `manual_order` | int? | Ordering in grid view |
| `canvas_x`, `canvas_y` | float? | Position on the infinite canvas |
| `canvas_w`, `canvas_h` | float? | Size on the canvas (overrides intrinsic) |
| `canvas_z` | int? | Stacking order on the canvas |

> Canvas placement lives **per-membership**, not on the asset. The same asset can
> sit at different spots on different boards — this is what lets grid and canvas
> be two views of the *same* data.

### Tag (reserved in MVP)
Free-form labels for cross-collection filtering and agent-written organization.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | |
| `name` | string | |
| `source` | enum | `user` \| `agent` — who applied it |

Join table `AssetTag(asset_id, tag_id)`.

### Relationships
```
Collection 1───* CollectionItem *───1 Asset *───1 Source
                                        │
                                        *──────* Tag   (via AssetTag)
```
- **Asset ↔ Source**: many assets to one source possible (a post with several
  images); every asset has exactly one source. Required.
- **Asset ↔ Collection**: many-to-many via `CollectionItem`; dedup on disk via
  `blob_hash`.
- **Canvas position**: a property of the membership, not the asset.

### Expansion notes
- `raw_metadata` JSON absorbs platform differences without schema churn.
- `kind`/`platform` enums are open-ended; new values aren't relationship
  migrations.
- Tags carry `source` (`user` vs `agent`) so agent organization is
  distinguishable and reversible.
- Nested / smart collections are out of MVP, but `Collection` having its own id
  means a future `parent_collection_id` or saved-query collection is additive.
- **Explicit GRDB migrations** from day one.

---

## §ingestion

Two paths, converging on the same outcome: a downloaded, locally-stored asset
with a complete **Source** record.

### The pipeline (every import runs through this)
```
discover → resolve media URL(s) → download bytes → hash (dedup check)
        → store blob → extract dimensions/duration → generate thumbnails
        → write Source + Asset → add to target Collection
```
- **Async & queued** — jobs with progress, retry, cancellation; large imports
  never block the UI.
- **Resumable** — `download_state` lets a failed download retry without
  re-creating records.
- **Dedup by content hash** — reuse the blob if bytes exist; still create a
  distinct asset/source if provenance differs.

### Path 1 — Direct input (always available, MVP day-one)
- **Paste an image** → `platform = local_paste`; capture a source URL if the
  clipboard carries one.
- **Paste a URL** → fetch the page, resolve media (OpenGraph/Twitter-card or
  on-page media), `platform = web`, URL as provenance.
- **Drag a file** (Finder) → `platform = local_drag`, original path in
  `raw_metadata`.
- **Drag a browser image** → the drag often carries the source page URL → capture
  as `original_url`.

### Path 2 — Platform ingestion (per-platform adapters)
Each platform is a **source adapter** implementing one protocol, so adding a
platform is one new module:
```
protocol SourceAdapter {
    var platform: Platform { get }
    func discover(_ input: SourceInput) async throws -> [DiscoveredItem]
    // each DiscoveredItem → media URL(s) + a populated Source record
}
```
The adapter only **discovers + resolves + populates provenance**; the shared
pipeline handles download, dedup, storage, thumbnails.

**Target platforms:**

| Platform | What we ingest | Provenance |
| --- | --- | --- |
| **Twitter / X** | Media from a tweet or likes/bookmarks | tweet URL, handle, text |
| **Pinterest** | Pins from a board or saves | pin URL, board, source link, description |
| **Instagram** | Media from a post or saved collection | shortcode/URL, author, caption |
| **Cosmos** | Elements from a cluster | element URL, cluster, connections |

**Primary platform path — Chrome extension** (*see [research §chrome-extension](./002-foundation-research.md)*).
A "save as you browse" extension captures the current post/pin from inside the
user's authenticated session and POSTs it to a **localhost endpoint — the same
App Services surface the agent uses.** Per-site content scripts do the
extraction, each mapping onto the `SourceAdapter` shape. This dodges auth walls /
ToS and captures perfect provenance. It is the MVP platform-ingestion story.

**Secondary path — link resolution (fallback).** Paste/drag a single post URL →
resolve media + provenance. For when the extension isn't installed or on a
non-Chromium browser.

**Later — bulk import / backfill.** Import a whole board / likes / cluster behind
the same adapter protocol — the only path that backfills existing history the
extension can't capture retroactively.

### Failure & edge handling
- Dead/blocked media → `download_state = failed`, kept with its source for retry.
- Auth required → adapter surfaces a clear "sign in to import" state.
- Rate limits → job queue backs off and resumes.
- Unknown platform fields → preserved in `raw_metadata`.

---

## §views

A **view** is a lens over a collection; the collection is the source of truth.
Switching views never copies data. MVP ships **Grid** and **Infinite Canvas**
behind a shared abstraction so a third view later is additive.

### The view abstraction
All views read the same `CollectionItem` rows; they differ in which placement
fields they honor — grid honors `manual_order`, canvas honors
`canvas_x/y/w/h/z`. Because placement lives on the membership, the same asset
can be order 3 in the grid and at (1200, 480) on the canvas with no duplication.

```
protocol CollectionView {
    func render(_ items: [CollectionItem]) -> some View
    // reads shared data, writes only its own placement fields
}
```

### Grid view
The fast, dense, scannable default.
- **Virtualized** masonry/justified grid — only visible cells realized.
- Renders from pre-sized thumbnails; full-res on open.
- Sort/filter: recency, platform, tag, manual order.
- Interactions: select (single/multi), drag-reorder (`manual_order`), drag into
  another collection, open full-res, reveal source URL.

### Infinite canvas (Figma-style)
The spatial, arrangement-focused view — the performance-critical one.
- **Pan & zoom** over an unbounded plane; assets freely positioned
  (`canvas_x/y`), resizable (`canvas_w/h`), stackable (`canvas_z`).
- **Rendering must scale:** tile-/layer-based (Core Animation / Metal), **not** a
  native view per asset; **viewport culling** (only visible tiles); **level of
  detail** (low-res when zoomed out, full-res only when close). Target smooth
  120fps with thousands of tiles.
- Interactions: free move/resize, marquee select, group/arrange, snapping
  (later), plus the same open/reveal-source actions as the grid.

### Shared behaviors
- **Selection persists across views** — select in grid, switch to canvas.
- **Provenance always reachable** — every asset, any view, can reveal/open its
  original source URL. A first-class action, never buried.
- **Inspector panel** — selected asset's metadata: platform, original URL,
  author, dimensions, tags, collection memberships.
- **Drag between views and collections** updates membership/placement, never
  duplicates the blob.

### Future views (allowed, not in MVP)
Timeline (`captured_at`/post date) · list/detail · source-grouped · map/graph
(relationships, esp. Cosmos clusters). None require data changes beyond possibly
adding view-specific placement fields.

---

## §agent-interface

ref-atelier **does not embed its own AI.** It exposes an interface an **external
agent** can drive — to read the library, organize, tag, and arrange. The
intelligence is swappable; the app stays lean.

### Why external, not internal
- **Lean core** — no model hosting or AI deps baked into a native app.
- **Swappable intelligence** — any tool (script, CLI agent, MCP assistant) can
  improve independently of the app.
- **Same contract as the UI** — the agent mutates through the **same App Services
  layer** the UI uses. Anything the agent does, a human could, and vice versa.
  No privileged backdoor, no divergent state.

### What the agent needs

| Capability | Reads / writes |
| --- | --- |
| **Inventory** | List collections, assets, sources, tags |
| **Inspect** | An asset's metadata + provenance; thumbnail/blob paths |
| **Search** | By text, platform, tag, dimensions, date (FTS5) |
| **Organize** | Create/rename collections; add/remove assets |
| **Tag** | Apply/remove tags (written `source = agent`) |
| **Arrange** | Set grid order and canvas placement on memberships |
| **Observe** | Be notified of new ingests to suggest filing |

> Agent-written changes are **attributed and reversible** — tags/arrangements
> made by the agent are `source = agent`, so the user can review, accept, or roll
> back the agent's work separately from their own.

### Interface options (the contract matters more than the transport)
1. **MVP** — a local, documented App Services API behind a thin IPC surface: a
   **localhost HTTP/JSON server** or a **CLI** wrapping the same services.
   *(This same localhost endpoint is what the Chrome extension POSTs to.)*
2. **Then** — an **MCP server** exposing App Services as tools
   (`list_collections`, `search_assets`, `add_to_collection`, `tag_asset`,
   `set_canvas_position`, …) for assistant-style agents.
3. **Also** — a **URL scheme / AppleScript** surface for lightweight automation
   and deep links.

All are **adapters over the one App Services layer** — pick the transport; the
capabilities are identical.

### Illustrative capability surface
```
# Read
list_collections() -> [Collection]
get_collection(id) -> Collection + items
search_assets(query, platform?, tag?, date_range?) -> [Asset]
get_asset(id) -> Asset + Source + thumbnail/blob paths

# Write (same path as the UI)
create_collection(name, description?) -> Collection
add_assets_to_collection(collection_id, asset_ids)
remove_assets_from_collection(collection_id, asset_ids)
tag_assets(asset_ids, tags)            # written as source = agent
set_grid_order(collection_id, ordered_asset_ids)
set_canvas_placement(collection_id, asset_id, x, y, w, h, z)

# Observe
subscribe_new_ingests() -> stream of Asset
```

### Boundaries
- The agent **cannot** bypass the data model or write blobs directly — it goes
  through App Services, which enforces invariants (e.g. provenance required).
- Organization is **proposable and reviewable** via `source = agent` attribution.
- Security — the local API binds to localhost, scoped to the library; no remote
  exposure in the MVP.

Even though rich agent integration is post-MVP, routing **all mutations through
one App Services layer** from the start is what makes both the agent interface
and a future sync engine thin additions rather than refactors.
