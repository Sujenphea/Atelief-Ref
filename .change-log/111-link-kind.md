# 111 — Link kind, structural (003 · C2a)

The second media-less kind. A saved link is a first-class item — grid card,
detail card with an Open action, dedup by canonical URL — built structurally on
109's seam, mirroring how color (C1) went core-first. **No network:** title /
description enrichment (og tags) waits on a page resolver (001); a bare paste
still saves a usable link keyed by its URL.

## What ships

- **`LinkPayload`** (url / title / description) on `AssetPayload`, plus
  **`LinkPayload.canonicalURL`** — *moderate* normalization (003 · open Q2):
  prepend `https://` when scheme-less, lowercase scheme + host, drop fragment /
  default port / trailing slash (incl. root), strip tracking params (`utm_*`,
  `fbclid`, `gclid`, …). Deliberately does not touch other query params or path
  case — over-stripping would merge distinct pages.
- **`AssetContent.link(LinkContent)`** — the render projection carries url / title
  / description + the asset's own `blobHash` as an optional og:image (nil until
  resolved; present later shows a thumbnail instead of a card).
- **`ingestContent` for links** — the canonical URL is the dedup key AND the
  provenance `original_url` (the funnel aligns them), so `example.com/x`,
  `example.com/x/`, and `…/x/?utm_source=tw` collapse to one link. `searchText`
  is title + description + host, so a link is findable by name or domain via
  `asset_fts`. New error `.invalidLinkURL`.
- **UI** — grid `LinkCardTile` (globe + title/host); detail `LinkDetailView`
  (title / host / description + a prominent **Open Link** via SwiftUI `Link`, og:
  image shown once resolved); `AddLinkButton` toolbar → `IngestionModel.addLink`.

## Files changed

- Core: `AssetPayload.swift`, `AssetContent.swift`, `Validation.swift`,
  `ServiceTypes.swift`, `AtelierError.swift`, `AppServices.swift`.
- App: `SharedThumbnail.swift` (link card tile), `ItemDetailView.swift` (link
  arm + `LinkDetailView`), `AddLinkButton.swift` (new), `IngestionModel.swift`
  (`addLink`), `CollectionView.swift` (toolbar).

## Tests

Core **294** green (+10): `LinkPayload.canonicalURL` matrix (normalization,
tracking-strip, rejection, equal-pages-collapse); `AssetContent` link mapping
(bare vs og:image-resolved); `ingestContent` link ingest / URL-canonical
dedup / `.invalidLinkURL` / search-by-title-and-host. App unit bundle green;
Ingestion + Server rebuild clean.

## Migration notes

None — rides on v6 (109). No schema change: a link is an `asset` row with
`kind='link'`, nil bytes, a `payload` JSON, and `dedup_key` = canonical URL.

## Remaining (003)

- **C2b — resolver enrichment** (= 001 P1): a SSRF-hardened page fetch fills
  title / description / og:image, upgrading the bare card to a rich one. The
  extension's `web` captures become links.
- **C3 — tweet** (needs the media-children modeling decision).

The `003-multi-kind-items.md` feature doc stays live for those.
