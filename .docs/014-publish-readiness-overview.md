# 014 — Capture extension publish readiness: Overview

Scope: the Chrome MV3 capture extension (`extension/`), its localhost server
(`AtelierServer`), and the companion macOS app. This is the standing checklist for
taking the extension from local/unpacked use to distribution. It supersedes two
earlier review notes whose engineering findings have since been implemented (see
"Resolved" below); what remains here is genuinely open work.

## Verdict

The capture path is solid for **local / unpacked** use: MV3 manifest present, no
runtime deps or build step, dependency-free `node --test` suites, and a deliberate
server security model (loopback bind, shared token, `Origin` allowlist,
constant-time compare, CORS preflight, body caps).

It is **not ready for public Chrome Web Store publication** — the gap is packaging
and review-prep, not core behaviour.

## Open work (pre-publication)

### Packaging / assets

- **Icons (hard blocker).** `extension/manifest.json` has no `icons` entry and the
  directory has no icon assets. The Web Store requires at least a 128×128 icon.
  Add the icon set + `icons`, and an `action.default_icon` if toolbar polish is
  wanted.
- **Production package script.** Add a step that zips only the files Chrome needs
  (exclude `test/`, `package.json` dev bits, etc.).

### Listing / review prep

- **Privacy disclosure.** Cover what's handled: captured post URLs, page metadata,
  and media bytes — all sent only to `127.0.0.1` (the companion app), never a third
  party. This is a strong privacy story; state it explicitly.
- **Reviewer instructions.** Install/open the macOS app → copy the token → paste
  into extension options → capture a supported post. A reviewer without the app
  sees a no-op, so this must be loud in the listing.
- **Distribution choice.** Decide public vs **unlisted** vs enterprise/internal.
  Given this is a personal, local-first companion, unlisted (shareable by link)
  likely fits better than public search listing and reduces "downloader" scrutiny.
- **Host-permission review.** Permissions are scoped by platform/CDN (not
  `<all_urls>`), which is good; review against Chrome's least-permission guidance
  before submission.

### Store-review notes (document in the submission)

The extension's logic is self-contained; remote requests fetch **data, not remote
code** — the right shape for MV3, but call it out:

- Twitter/X video resolution fetches JSON from the public syndication endpoint.
- Pinterest video resolution fetches logged-out HTML and parses media URLs.
- Media fetches retrieve image/video bytes to save into the local app.
- No remote JavaScript is loaded or evaluated.

Note the platform-ToS risk on the video-resolution paths (they read as
"downloader" behaviour); a public listing invites more scrutiny than unlisted.

### Security pairing (revisit at publish time)

The app currently accepts any `chrome-extension://` origin plus the token (fine for
an unpacked dev id that churns). For a store build, **pin the published extension
id** app-side once it's stable (decision 4A in changelog 052 deferred this on
purpose — the token remains the real barrier meanwhile).

## Resolved since the reviews (no longer open)

The prior readiness/codebase reviews flagged these; all are now fixed — see the
changelogs, not this doc, for detail:

- Extension video buffered as a `Uint8Array` before upload → now a streamed `Blob`
  plus a client-side `Content-Length` cap (052 §15A, 054).
- Image base64 built byte-by-byte → chunked encoding (052 §13A).
- Full-page video-frame rasterization → first eligible video only, as JPEG
  (052 §14A).
- `loadContents(of:)` stale-result race → generation-guarded (054).
- Library grid thumbnails decoded synchronously on the main actor → async
  `ThumbnailCache`, disk read/decode off-main (054).

## Suggested order of work

1. Add icon assets + manifest `icons` (unblocks any submission).
2. Add the production package/zip script.
3. Write the privacy disclosure + reviewer instructions.
4. Decide public/unlisted/enterprise; if publishing, pin the extension id app-side.
