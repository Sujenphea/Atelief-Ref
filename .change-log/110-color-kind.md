# 110 — Color kind, end-to-end (003 · C1)

The first media-less kind reaches the user, proving the whole content path built
in 109: ingest → grid swatch → detail arm → dedup by hex. Zero network, no
thumbnail, no extension change — the simplest kind, shipped first to de-risk
link (C2) and tweet (C3).

## What ships

- **Add Color** — a toolbar affordance on every Collection screen
  (`AddColorButton`): a native `ColorPicker` and a `#RRGGBB` field kept in sync,
  with a live swatch preview. Committing calls `IngestionModel.addColor(hex:)`,
  which ingests a media-less color (local-paste provenance) through
  `ingestContent` and reloads the folder.
- **Grid swatch** — a color renders as a `ColorSwatchTile` (via the
  `AssetContentThumbnail` seam from 109), not a broken thumbnail.
- **Detail arm** — the detail page shows a large color swatch + its hex
  (`ColorDetailView`); the sidebar shows Kind "Color" and a Hex row; the blob
  actions (Open Full Resolution / Reveal in Finder) disable, since there is no
  file.
- **Dedup by hex** — `#F00`, `#ff0000`, `#FFFFFF`-vs-`#ffffff` collapse to one
  color per source (canonical hex is the dedup key, from 109's core).

## Design notes

- Colors are **grid-first**: they appear in the collection grid and search
  results and open the detail page. Placing a color on a canvas/space renders a
  neutral tile for now (media-less tiles are handled defensively) — a dedicated
  swatch tile on the board is a later polish, not required for C1.
- The picker→hex conversion lives in the view layer (`Color.toHexString()` /
  `Color(hexString:)`); the domain stores and dedups the canonical hex string.

## Files changed

- `AddColorButton.swift` (new) — the add-color popover.
- `IngestionModel.swift` — `addColor(hex:)`.
- `CollectionView.swift` — toolbar wiring.
- (Render seam, swatch tile, detail arm, and `Color(hexString:)`/`toHexString()`
  landed in 109's app sweep.)

## Tests

App unit bundle green, incl. new `ColorHexTests` (Color↔hex round-trip, parsing,
canonical output). The color ingest / dedup / validation semantics are covered
by Core's `ServicesContentTests` (109).

## Migration notes

None — rides on v6 (109).

## Remaining (003)

C2 (link — depends on 001's `PageResolver`), C3 (tweet — resolve media-children
first). The `003-multi-kind-items.md` feature doc stays live for those.
