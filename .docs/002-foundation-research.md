# 002 — Foundation: Research

> Evaluation of alternatives behind the decisions in
> [overview](./001-foundation-overview.md). Covers the app shell (native vs
> Electron/Tauri), storage, testing framework, and Chrome-extension ingestion
> feasibility.

---

## §native-vs-web — App shell: native vs Electron vs Tauri

### What prompted this
A comparable app is built on an **Electron + Node** stack:
`better-sqlite3`, `electron-updater`, `nanoid`, `node-vibrant`, `sharp`. The
presence of `electron-updater` means it ships web tech in a Chromium shell. We
evaluated adopting a similar approach versus staying native.

### Library-by-library: their Node stack vs. our native equivalents

| Their lib | Purpose | Native equivalent | Verdict |
| --- | --- | --- | --- |
| **better-sqlite3** | Synchronous SQLite for Node | **GRDB / SQLite** | Wash. Both excellent; GRDB has stronger typed migrations |
| **sharp** | Thumbnail/resize (libvips) | **Image I/O + vImage / Core Graphics** | **Native wins** — hardware-accelerated decode/encode, native HEIC, zero dependency |
| **node-vibrant** | Color palette extraction | **Core Image / vImage** (or small k-means) | Slight convenience edge to them; native is faster |
| **nanoid** | Short unique IDs | `UUID` / native | Wash |
| **electron-updater** | Auto-update | **Sparkle** (or App Store) | Wash — both are the standard answer for their platform |

**Takeaway:** every library in their stack has a first-party native equivalent.
For the two that matter most — image pipeline and DB — native is at least as
good, usually faster with no dependency weight. The Electron stack's real value
is the surrounding **web ecosystem**, not any single library.

### The real trade-off

| | Web-tech (Electron/Tauri) stronger | Native (our choice) stronger |
| --- | --- | --- |
| **Canvas** | Mature infinite-canvas tooling (`tldraw`, PixiJS, Konva) — pan/zoom/culling/LOD largely free | Highest performance ceiling once built (Metal/Core Animation tile renderer beats web canvas at thousands of full-res tiles) |
| **Efficiency** | — | RAM, battery, bundle size; no Chromium runtime tax. **This is the #1 product goal** |
| **OS integration** | — | Drag-drop fidelity, QuickLook, Share Extension, Spotlight, menu-bar capture |
| **Iteration** | Faster build, bigger ecosystem, near-free cross-platform | Slower, smaller ecosystem, macOS-only |
| **Image pipeline** | sharp (good) | Image I/O beats sharp on Mac |

### Tauri — the middle option we did **not** take
Tauri (Rust backend + the OS's native webview, no bundled Chromium) keeps the
web canvas libraries but ships ~10–20MB at a fraction of Electron's memory, with
`rusqlite` + the `image` crate on the backend. It's the most efficient way to
get the web canvas ecosystem.

### Decision (D1): native
We chose **native over both Electron and Tauri** because "fastest, most native
Mac app" is core to the product identity, and the efficiency + OS-integration
wins outweigh the canvas-engineering savings.

**Trade-offs accepted:**
1. **The infinite canvas is real engineering** — no off-the-shelf
   tldraw/PixiJS equivalent; we build tile rendering, viewport culling, and LOD
   ourselves. The largest single cost of the decision.
2. **macOS-only** initially — cross-platform would be a rewrite, not a recompile.
3. **Slower iteration** and a smaller third-party ecosystem.
4. **A little more glue** for niceties (e.g. color extraction) that are turnkey
   in Node.

**Trade-offs gained:** efficiency/speed (the headline requirement), a
best-in-class image pipeline, deep OS integration, no Chromium tax.

**Revisit if:** cross-platform becomes a hard requirement (→ Tauri); the native
canvas costs far more than projected (→ consider a Tauri shell with a web canvas
over the same native data-core design).

---

## §storage — SwiftData vs Core Data vs GRDB

### Between the two Apple frameworks
For a greenfield app on current macOS, **SwiftData** beats Core Data: it's
Apple's forward direction (Core Data is now legacy), far less boilerplate
(`@Model`/`@Query` vs `.xcdatamodeld` + `NSFetchedResultsController`), and has
matured since its rocky launch. Core Data only wins if SwiftData can't do
something — and starting on legacy tech to avoid that is the wrong trade for a
new project.

### Why GRDB wins for *this* app (Decision D3)
The deciding factor is **full-text search.** The search capability (UI + agent)
wants real **SQLite FTS5.** Neither SwiftData nor Core Data exposes FTS5 cleanly
— you fall back to `contains`-predicate table scans, or bolt a *second* SQLite
FTS index alongside the object store. GRDB gives FTS5 in the one store you
already have. Two more:

- **Explicit, typed migrations** — the schema will evolve (tags, nested
  collections, new platforms); GRDB's migration API is more predictable than
  SwiftData's still-maturing schema migration.
- **Query control + performance at scale** — grid and canvas filter thousands of
  membership rows with placement fields; GRDB gives exact SQL and indexing,
  where SwiftData's predicate layer is more opaque.

**A non-factor:** agent/extension access. The localhost API runs *inside* the
app process, sharing the app's store — so all three options work there. Don't
pick on that basis.

**GRDB's only real cost:** no free SwiftUI `@Query` binding — but
`ValueObservation` (or the small `GRDBQuery` package) provides equivalent
auto-updating SwiftUI integration. Solved problem, not a downgrade.

**If first-party is a hard requirement:** use SwiftData and maintain a side FTS
index for search.

---

## §testing — Test framework

### Decision (D4): Swift Testing primary, XCTest for the gaps
**Swift Testing** (Apple's framework, GA since Xcode 16) is the default for all
unit/logic tests, over XCTest:
- `@Test` + `#expect`/`#require` — cleaner than `XCTAssert*`, with diagnostics
  that show sub-expression values.
- **Parameterized tests** (`@Test(arguments:)`) — ideal for running the same
  extraction test across Twitter/Pinterest/Instagram/Cosmos fixtures.
- `@Suite` setup instead of `setUp/tearDown`; parallel by default; async-native
  (matches the async ingestion pipeline).
- It's where Apple is investing; XCTest is legacy for unit tests.

**Keep XCTest for two things Swift Testing doesn't cover:**
1. **UI tests → XCUITest** (XCTest-based) — drives the real app (drag-drop, grid,
   inspector). Swift Testing has no UI-automation story.
2. **Performance benchmarks → XCTest `measure {}`** — matters most for the
   **canvas spike**: a perf test that renders thousands of tiles and measures
   frame cost as a CI guardrail. (Deep profiling is Instruments, not a test.)

The two frameworks coexist in the same project. Skip third-party frameworks
(Quick/Nimble) — Swift Testing now covers what they offered, first-party.

---

## §chrome-extension — Chrome-extension ingestion feasibility

### Verdict: feasible, and the right primary path (Decision D2)
This directly solves the hardest problem — auth walls / ToS / fragile scraping
of Twitter, Pinterest, Instagram, Cosmos.

**Why it works so well:**
- Runs **inside the user's already-authenticated browser session**, seeing each
  platform exactly as the logged-in user does — **no separate auth, no API keys,
  no login scraping.** Sidesteps the entire hard part of bulk scraping.
- **Provenance captured perfectly** — the extension knows the current URL and
  DOM metadata (author, caption, pin source link, cluster), producing a complete
  `Source` record for free.
- **User-driven save, not bulk crawl** — a far safer ToS posture, and the model
  Pinterest's own button, Raindrop, MyMind, and Cosmos already use.

**How it connects to the app:**
- Extension → app over a **localhost endpoint** (or macOS **native messaging**
  host). That endpoint is the *same App Services surface* exposed to the external
  agent — extension and agent share **one ingestion seam**.
- Per-site **content scripts** extract media + metadata (context-menu "Save to
  ref-atelier," injected save button, or capture-current-post), each mapping onto
  the same `SourceAdapter` shape.
- **Independent of the native-vs-web app choice** — it just POSTs to localhost.

**Costs, eyes open:**
- **Per-site maintenance** — content scripts break on DOM changes; bounded and
  per-adapter, but an ongoing tax.
- **Distribution** — Chrome Web Store review, or ship unpacked initially;
  Chromium-only unless a Safari/Firefox variant is built.
- **Captures only while browsing** — "save as you go," not a backfill of existing
  history. Backfill is the later bulk-import path.

This promotes the Chrome extension to **the** primary platform-ingestion path,
ahead of the earlier "paste-a-link" idea (now a fallback) — same
authenticated-session benefit, better provenance, smoother UX.
