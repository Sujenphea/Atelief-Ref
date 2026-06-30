# 001 — Foundation: Overview

> Synthesis, decisions, and index for **ref-atelier**'s foundational planning.
> Companion docs: [research](./002-foundation-research.md) ·
> [design/spec](./003-foundation-design.md) ·
> [plan](./004-foundation-plan.md).

**ref-atelier** is a native macOS app for curating a personal library of design
references. It ingests assets (images, videos) from around the web — via a
Chrome extension, copy/paste, and drag-and-drop — organizes them into
**collections**, and lets you browse them in multiple ways, including a **grid**
and an **infinite canvas** (Figma-style).

Two principles drive every decision:

1. **Local-first & fast.** Assets are downloaded and stored on-device. Native
   rendering, no spinners for content you already have. Network is for
   *ingestion*, not *browsing*.
2. **Provenance is sacred.** Every asset records where it came from. The
   original source URL is never lost.

## Document index

| Doc | Kind | What it covers |
| --- | --- | --- |
| [001 — Overview](./001-foundation-overview.md) | overview | Vision, principles, non-goals, decisions log, index |
| [002 — Research](./002-foundation-research.md) | research | Native vs Electron/Tauri, storage & testing evaluations, Chrome-extension feasibility |
| [003 — Design](./003-foundation-design.md) | design | The spec: architecture, data model, ingestion, views, agent interface |
| [004 — Plan](./004-foundation-plan.md) | plan | MVP scope, phased roadmap, testing strategy |

## The problem

Designers collect references constantly — a screenshot, a Pinterest save, a
tweet with a great UI, a Cosmos cluster. They scatter across bookmarks,
screenshot folders, Notes, and platform-specific "saves" you can never find
again. Worse, the link back to **where it came from** — the post, the designer,
the context — is usually lost.

## What we're building

The single, fast, local home for design references:

- **Capture** from anywhere: a Chrome extension for platform saves, plus paste
  and drag.
- **Organize** into a library of **collections** (moodboards, projects, themes).
- **Browse** in the view that fits — a dense **grid** for scanning, an
  **infinite canvas** for spatial arrangement.
- **Keep provenance** on every asset: original URL and platform are first-class,
  always-present metadata.

## Who it's for

A **designer / creative individual** curating their own reference library.
Single-user, single-machine to start. Not a team tool (yet).

## Core principles

1. **Local-first and fast.** Native macOS app, not a web wrapper. Captured
   content is on-device and renders instantly. The headline quality bar: *faster
   than anything web-based.*
2. **Provenance is non-negotiable.** Every asset carries source platform,
   original URL, author/handle when available, and capture time. Never stripped.
3. **Multiple views over one dataset.** Grid and canvas are *views*, not
   separate stores. The collection is the source of truth; adding a view later
   (timeline, list, graph) must not reshape the data.
4. **MVP first, but architect for expansion.** Ship something small that works
   end-to-end; make the early structural calls (data model, storage, ingestion
   abstraction, view abstraction, one mutation path) with the full feature set
   in mind so growth is additive.
5. **External agent over internal AI.** Rather than an in-app AI to auto-sort,
   the app exposes an interface an external agent can drive. Intelligence stays
   swappable; the core stays lean.

## Non-goals (for now)

- **Cloud sync / multi-device** — local-first first; sync can be an additive
  layer later.
- **Team collaboration / sharing** — single user to start.
- **An internal AI assistant** — intelligence lives in an external agent.
- **A general file manager** — scoped to visual design references (image/video).
- **Editing assets** — we curate and arrange; we don't retouch.

## Decisions log

Key decisions made during planning, with rationale recorded in the linked docs.

| # | Decision | Rationale | Detail |
| --- | --- | --- | --- |
| D1 | **Native macOS (Swift / SwiftUI + AppKit)** — not Electron or Tauri | Efficiency and OS integration are the #1 product goal; accept building the canvas ourselves | [research §native-vs-web](./002-foundation-research.md) |
| D2 | **Chrome extension is the primary platform-ingestion path** | Rides the user's authenticated browser session — dodges auth walls / ToS that sink headless scraping; perfect provenance | [research §chrome-extension](./002-foundation-research.md) · [design §ingestion](./003-foundation-design.md) |
| D3 | **GRDB (SQLite) for storage** — over SwiftData / Core Data | First-class FTS5 search, explicit migrations, query control at canvas scale | [research §storage](./002-foundation-research.md) |
| D4 | **Swift Testing primary; XCTest for UI (XCUITest) + performance (`measure`)** | Modern, parameterized, async-native; XCTest covers the two gaps | [research §testing](./002-foundation-research.md) · [plan §testing](./004-foundation-plan.md) |
| D5 | **One App Services mutation path** for UI, agent, and extension | Single seam for the agent interface, the extension endpoint, and future sync | [design §architecture](./003-foundation-design.md) |
| D6 | **Content-addressed blob store + SQLite metadata** | Free dedup, small DB, media served straight from disk | [design §storage](./003-foundation-design.md) |

### Open decisions / risks
- **Infinite-canvas renderer** is the critical-path engineering risk (no
  off-the-shelf equivalent when native). Mitigation: a rendering spike first —
  see [plan](./004-foundation-plan.md).
- **Per-site extension content scripts** are an ongoing maintenance tax as
  platforms change their DOM.

## Status

These documents capture the **foundational product direction** and are meant to
evolve. The architecture is scoped so the MVP is small but does not paint us
into a corner — see [plan](./004-foundation-plan.md).
