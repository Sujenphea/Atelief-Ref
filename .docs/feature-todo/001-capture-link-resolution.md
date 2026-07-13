# 001 — Capture: Add from Link (page-URL resolution)

> Covers the "Save designs from" group: **add from link** (the real gap), and records
> **drag & drop** and **right-click from Chrome** as already built (with gap notes).
> Companion: [002](./002-capture-instagram-bulk.md) (bookmarks bulk),
> [003](./003-multi-kind-items.md) (tweet/link kinds this feature later feeds).

## Traceability

| Requested | Status |
|---|---|
| Drag and drop | ✅ built — drop zone (`LibraryView.swift` `handleDrop`), file/browser-image/URL types, page-URL provenance attached to dragged browser images |
| Right click from Chrome | ✅ built — "Save to Atelier" context menu, page/image/link contexts (`extension/src/sw.js:346–367`) |
| Add from link | 🟡 bare **image** URLs only (`RemoteImageFetcher`); **page** URLs dead-end — this doc |

**Right-click gap note:** the context menu appears on every site, but capture quality
off the allowlisted platforms depends on the `web` OpenGraph extractor + `activeTab`
(granted by the menu gesture). Byte fetches from CDNs outside `host_permissions`
(`manifest.json:7–15`) can fail on exotic sites. Acceptable for now; widening
`host_permissions` to `<all_urls>` is a store-review tradeoff, not a code problem.

## Current state

Pasting/dropping a URL with no bytes → `IngestionModel.ingestRemoteImage(from:)`
(`IngestionModel.swift:781–794`) → `RemoteImageFetcher` fetches and sniffs the actual
bytes via ImageIO. A page URL sniffs as HTML → `.notAnImage` → status "That link isn't
a direct image." (`IngestionModel.swift:808–809`). This is by design
(`RemoteImageFetcher.swift:6–8`): the app deliberately makes no other outbound requests;
page-URL resolution was deferred in 007 §scope.

## Options

### O1 — App-side HTML fetch + og:image/oEmbed parse
Extend the app to fetch the page HTML, parse `og:image` / `og:video` / oEmbed /
`<link rel="image_src">`, then re-enter the existing bare-image byte path.

- ✅ No extension dependency; handles the 80% case (public blog / Dribbble / Behance /
  article) in one place; parser is pure and fixture-testable.
- ❌ Bends the "no outbound network" invariant — the app now fetches
  attacker-influenceable HTML (SSRF surface: redirects to `169.254.169.254`, internal
  hosts, `file://`).
- ❌ Auth-walled pages (private tweet, logged-in Pinterest) return login HTML → wrong
  og:image or nothing. og:image is often a low-res share card.

### O2 — Route through the extension
App asks the extension to open/scrape the page; extension harvests + fetches bytes
in-session and POSTs back through the capture endpoint.

- ✅ Rides the browser session → auth-walled pages work; reuses the entire extractor
  registry; app stays fully off-network.
- ❌ Requires the extension installed and a **new app→extension channel** (today the flow
  is strictly extension→app). Background tabs are heavyweight and user-visible. A large
  new seam for a convenience feature.

### O3 — Hybrid, gated (recommended)
O1's mechanism, strictly gated: (a) **user-gesture-only** (paste/drop; never background),
(b) **SSRF-hardened** fetch, (c) known auth-walled/media hosts (x.com, instagram.com,
pinterest closeups) are **not** app-resolved — the status line offers "Capture with the
extension" instead of saving a garbage share-card.

## Recommendation — O3

- **Edge cases over speed:** public page, auth-walled page, media-host page, video page
  each get a distinct, honest outcome instead of one failure string.
- **Explicit over clever:** the invariant bends narrowly and is written down. New rule:
  *the app fetches only (i) bare image bytes and (ii) HTML metadata for a user-initiated
  page resolution — both SSRF-walled.* Update the comment at `RemoteImageFetcher.swift:6–8`
  and 007 §scope when implementing.
- **DRY:** the resolved media URL re-enters the existing `RemoteImageFetcher` byte path
  and the existing pipeline — no parallel ingest path.

**Settled (user decision):** bending the invariant this way is approved.

## Schema / migration impact

**None.** A resolved og:image becomes an ordinary `.web` image asset via
`DirectInputReader.browserImageInput` (`DirectInputReader.swift:64–74`) with the **page**
URL as `original_url` — so re-resolving the same page dedups correctly through
`findDuplicate` (`AppServices.swift:917–919`).

Once [003](./003-multi-kind-items.md) lands, a tweet/link page URL should produce a
tweet/link **item** instead of a flattened image; O3's host detection becomes the
dispatcher into those kinds. No migration needed here either way.

## Phased implementation

1. **P1 (S) — resolver.** New `PageResolver` in `AtelierIngestion/Sources/AtelierIngestion/Input/`
   beside `RemoteImageFetcher`: pure `resolve(html:baseURL:) -> ResolvedMedia?`
   (og:image / og:video / oEmbed discovery / image_src; relative-URL resolution). SSRF
   guard in the fetch layer (reject non-http(s), private/link-local IPs incl. after
   redirect, cap redirect count + body size, send no cookies). Wire
   `IngestionModel.ingestRemoteImage`: image-sniff first (existing) → page-resolve →
   re-enter byte fetch. New user-facing failure statuses.
2. **P2 (S) — auth-wall routing.** Known-walled-host set + login-shaped-HTML heuristic →
   "Capture with the extension" status (sibling of `reportUnreadableDrop`).
3. **P3 (M, deferred) — extension reverse channel** (O2) only if auth-walled resolution
   demand materialises post-003.

Files: `PageResolver.swift` (new), `RemoteImageFetcher.swift` (guard + redirect policy),
`IngestionModel.swift:781–815`, `LibraryView.swift:295–322`.

## Test strategy

- Pure `resolve(html:baseURL:)` over committed HTML fixtures: og:image present/absent/
  multiple, og:video, oEmbed, relative URLs, meta-refresh, empty/malformed HTML.
- SSRF matrix via `URLProtocol` stub (the existing `RemoteImageFetcher` test pattern):
  `169.254.169.254`, `file://`, redirect-to-private, over-cap body, non-http scheme.
- Auth-wall heuristic: login-shaped HTML fixtures → `.authWalled`.
- No live network anywhere.

## Effort: **S–M** (P1+P2 = S; only the deferred extension channel makes it M)

## Risks & edge cases

- **SSRF is the headline risk** — the guard is not optional and must apply per-redirect-hop.
- og:image may be a low-res share card or a site logo. Accept as best-effort: the user
  sees the result and can delete.
- JS-only SPAs with no og tags → resolves nothing → honest failure message.
- GIF/video pages: og:video may be a player URL, og:image a poster. Treat as image unless
  a direct media URL sniffs as video (the pipeline already classifies movie bytes,
  `IngestPipeline.swift:138–140`).
- Charset/encoding oddities in fetched HTML; `Content-Type: text/html; charset=…` parsing.

## Settled decisions

- App-side HTML fetch approved, gated as described (user, 2026-07-13).
- Drag & drop and right-click are done; no work planned beyond the gap notes above.

## Open questions

1. When a **tweet URL** is pasted before 003 ships: flatten to image now (recommended —
   it works today via extension capture anyway) and redirect to the tweet kind when 003
   lands, or hold the feature until 003?
2. Should the resolver attempt oEmbed **discovery** (extra request per page) in v1, or
   og-tags only first? (Recommend og-tags only; add oEmbed if hit-rate disappoints.)
