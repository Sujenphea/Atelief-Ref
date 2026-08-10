# 082 — Sharing Outward: Moodboard PNG / PDF / Static HTML Export

**Status: shipped** — all three phases. S1 in `8162c58` (moodboard PDF/PNG UI,
progress ring, save panel); S2 in `eda306c` (collection contact-sheet PDF/PNG via
masonry); S3 in `87eb2e7` (a collection as a self-contained web page, recorded in
`.change-log/323`), with `7cad73c` fixing board text survival in the page.

Both open questions are answered by what shipped, and one settled decision moved:

1. **PNG scale** — neither answer: it became a control, not a default. A 1/2/3
   segmented picker on the export row (`MoodboardExportControls.swift:79`).
2. **Contact-sheet captions** — likewise a control, one `Captions` toggle on the
   contact-sheet popover (`ContactSheetExportControls.swift:92`), alongside scale
   and column count.
3. The composer landed as its own package, **`AtelierExport`**
   (`Layout/MoodboardLayout`, `Model/`, `Render/MoodboardRenderer`,
   `Site/StaticSiteRenderer`), not as a seam inside `CanvasRenderer` as sketched
   below — pure, GRDB-free and golden-file tested, with the app-side controllers
   (`MoodboardExport`, `ContactSheetExport`, `CollectionSiteExport`) holding the
   panels and progress.

Promoted out of `feature-todo/014-sharing-out.md`.

> Presenting references to clients/teams without collaboration infrastructure.
> Settled scope (user, 2026-07-13): **local files only** — no hosted publish, no
> accounts, no network-posture change. Three outputs: Space → image, Space /
> collection → PDF, collection → self-contained static HTML.

## Current state (verified)

- Nothing exports a composed view. [081](081-backup-plan.md)'s export is a *data* round-trip
  (originals + manifest); [011](feature-todo/011-ux-features.md)'s out-flow is per-item. No board/contact-sheet
  rendering exists.
- The rendering ingredients all exist: `CanvasRenderer` composes tiles into
  CALayers; [005](005-canvas-overview.md)'s hybrid renderer adds vector frames/text as layers; justified
  layout math ([011] U2) composes collections.

## Outputs

### 1 — Space → PNG (the moodboard image)

Render the space's content bounds offscreen: build the same layer tree the canvas
shows (image tiles at **full-resolution decode**, not screen LOD, + [005]'s vector
elements) into a bitmap context at 1×/2×/3×. Content-bounds fit + padding; no
viewport dependence.

- Implementation seam: an offscreen composer in `CanvasRenderer` that reuses
  `Tile` geometry + the decode path but bypasses the pool/culler (render-once, not
  120 fps). Explicitly NOT a screenshot of the live view — deterministic output,
  testable via snapshot hashing on fixtures.
- Memory: tile-by-tile draw into one `CGContext`; cap the largest dimension
  (~16k px) with a scale-down warning rather than OOM.

### 2 — Space / collection → PDF

Same composer into a PDF context: **vector where possible** ([005] frames/text
stay vectors — crisp print), images embedded at original resolution. Collection
variant = contact-sheet pages via `JustifiedLayout` ([011]) with optional
title/source captions. Multi-page pagination is a pure function (items → page
breaks) — testable.

### 3 — Collection → static HTML folder

A self-contained folder: `index.html` + `assets/` (originals or sized-down
copies), zero JS dependencies, justified CSS layout, optional source-link
captions. Works from disk, email, or any static host — *the user's* hosting
choice, not the app's. Reuses [081]'s filename sanitizer + [011]'s export helper
(one export layer, three consumers — DRY).

- Rejected: single-file HTML with data-URI images (multi-hundred-MB files);
  hosted publish (settled out — an infrastructure + privacy-posture product
  decision, not a feature).

## Provenance option

Every output offers **include source links: on/off** (captions/footnotes in
PDF/HTML; PNG gets an optional caption strip). Sharing others' work with
provenance stripped is a posture choice the user makes explicitly, not a default.

## Schema / migration impact

**None.** Pure read + render.

## Phased implementation

1. **S1 (M)** — offscreen composer (space → PNG), scale options, save panel.
2. **S2 (M)** — PDF context variant + collection contact-sheet pagination.
3. **S3 (M)** — static HTML exporter (template + asset copy + captions). Shipped
   — `323-a-collection-becomes-a-web-page`.

S1 blocks S2 (same composer); S3 is independent (needs only [011]'s export
helper). All after [005] E2/E3 for space content to exist.

## Test strategy

- Composer: fixture space → bitmap hash stability (determinism), content-bounds
  math, dimension-cap behavior — pure over injected tile sources.
- Pagination + HTML template rendering: pure golden-file tests.
- Caption/sanitizer matrix shared with [081]'s suite (same helper).
- PDF/save-panel glue: compile-only + manual print/preview pass.

## Effort: **M per phase, L total**

## Risks & edge cases

- Full-res decode of a large board can dwarf canvas memory budgets — the
  tile-by-tile single-context strategy is the guard; test with a 100-image board.
- Video items in an exported board: poster frame + a small play-glyph badge
  (honest about what a still export is). The HTML export does the same and
  copies no video file (settled — see below).
- Fonts in [005] text elements must embed in PDF (standard CoreText-to-PDF
  handles it; verify with non-system fonts).
- Empty space/collection → disable the action, not an empty file.

## Settled decisions

- Local files only; no hosted publish (user, 2026-07-13). Provenance inclusion is
  an explicit toggle. One shared export layer with [081]/[011].
- HTML export carries **poster frames only** — a still plus a play glyph, and a
  line in the page's own footer saying so. Videos are not copied (closes OQ1;
  shipped in `323-a-collection-becomes-a-web-page`).

## Open questions

1. PNG default scale — 2× (recommended) or ask every time?
2. Contact-sheet captions default: title only (recommended) vs title + source URL?
