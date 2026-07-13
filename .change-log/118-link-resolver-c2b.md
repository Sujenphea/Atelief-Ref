# 118 — Link resolver enrichment (001 · C2b, SSRF-hardened)

A pasted / typed PAGE url now resolves into a rich `.link` item — og:title,
description, and an og:image card thumbnail — instead of dead-ending as "that link
isn't a direct image". This is the security-sensitive piece: the app makes a second
(and last) kind of outbound request, and every hop is SSRF-walled.

## Decisions (locked at kickoff)

- **Synchronous enrichment at capture** — the link lands already enriched; no new
  mutate-existing-asset path (assets stay first-wins-immutable). A resolution failure
  still saves a bare link.
- **Pragmatic SSRF v1** — http(s)-only, per-redirect-hop host validation, reject
  private / loopback / link-local / ULA / multicast IPs (v4 + v6 + IPv4-mapped),
  redirect + body caps, no cookies. Does NOT pin the socket to the validated IP, so
  DNS-rebinding is not fully closed — a documented, accepted v1 limitation.
- **P1 resolver + P2 auth-wall routing**, og-tags only (no oEmbed discovery request).

## What ships

- **`SSRFGuard`** (new) — the security boundary. `validate(url)` requires http(s) and
  that the host resolve EXCLUSIVELY to public addresses; DNS is injected so the whole
  matrix is unit-tested without real DNS. Pure, total IP classification (RFC-1918,
  loopback, link-local 169.254, CGNAT, ULA fc00::/7, link-local fe80::/10, multicast,
  IPv4-mapped v6). `SSRFGuard.permissive` for call sites with their own isolation.
- **`PageResolver`** (new) — a PURE og-tag parser (`parse(html:baseURL:)`: og:title /
  description / og:image with twitter:* and `<title>` / meta-description fallbacks,
  relative-URL resolution, entity decode, first-og:image-wins) + a GUARDED fetch: a
  cookie-less ephemeral session with auto-redirect DISABLED (a `RedirectBlocker`
  delegate), following redirects MANUALLY so each `Location` re-runs the SSRF guard,
  with a redirect cap, a body cap, and an HTML content-type gate. Plus
  `isAuthWalledHost` (x / twitter / instagram / pinterest / facebook + subdomains).
- **`RemoteImageFetcher`** — now takes an `SSRFGuard` and validates the URL before
  fetching (`.blockedHost`). This closes the SSRF on BOTH the "is a pasted URL an
  image?" sniff AND the resolved og:image byte fetch (both attacker-influenceable).
  Per-redirect validation on the image path is a noted v1 gap (the metadata / direct
  private-host cases ARE blocked; the HTML path is fully per-hop).
- **`IngestionModel`** — the `.notAnImage` arm of `ingestRemoteImage` and `addLink`
  now resolve the page → save a `.link` with its og:image as the card blob (via the
  pipeline's `remoteContentWithImage`), or a media-less link when there's no image, or
  a bare link when resolution fails — the paste is never lost. An auth-walled host is
  NOT app-resolved (it returns a login / share-card); the status points at the
  extension. The resolved-page → ingest-input mapping is a pure `linkInput(...)`.

## Files changed

- New: `AtelierIngestion/.../Input/SSRFGuard.swift`, `.../Input/PageResolver.swift`.
- `AtelierIngestion/.../Input/RemoteImageFetcher.swift` (SSRF guard + `.blockedHost` +
  header/invariant update).
- `AtelierRefs/IngestionModel.swift` (`resolveLinkAndIngest`, pure `linkInput` /
  `webURL`, `addLink` resolves, `.blockedHost` status).
- Tests: `SSRFGuardTests`, `PageResolverTests` (parser + guarded-fetch SSRF matrix +
  auth-wall), `RemoteImageFetcherTests` (+`.blockedHost`, existing hermetic via
  `.permissive`), `AtelierRefsTests/LinkResolutionTests` (the `linkInput` / `webURL`
  mapping).

## Tests

AtelierIngestion **122** green (`swift test`), AtelierRefs **87** green (`xcodebuild`).
No real network in any test.

## Security notes

- The invariant is now written down (RemoteImageFetcher header): the app makes exactly
  two user-initiated, SSRF-walled outbound request kinds — bare image bytes and page
  HTML + og:image.
- **Residual (accepted v1):** no DNS-rebind pinning; `RemoteImageFetcher` validates the
  request host but not each redirect hop (the `PageResolver` HTML fetch does). Both are
  candidates for a future hardening hop.

## Migration notes

None — no schema change. A resolved link is an ordinary `.link` asset (payload +
optional card blob) the funnel already accepts.

## Remaining (001 / 003)

- **Extension web→link switch** — deliberately NOT done: a `web` capture already fetches
  its og:image in the browser session; converting it app-side isn't needed. Left as a
  separate call if the extension should emit link kinds directly.
- DNS-rebind pinning + per-redirect image-path validation — future hardening.
