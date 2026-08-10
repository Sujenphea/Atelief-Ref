# 020 — Rednote (Xiaohongshu): Single Capture + Bulk Board Sweep

> Adding rednote as a first-class capture platform. Scope prompted by a **manual
> one-off harvest run 2026-07-31** (a 32-note board pulled into the production
> library by hand); every mechanism below is *verified against that run*, not
> inferred. Companions: [015](../015-bulk-import-overview.md) (bulk engine),
> [029](../029-capture-instagram-bulk-overview.md) (the carousel-shaped precedent),
> [028](../028-capture-link-resolution-overview.md) (the junk-card stopgap in C).

## Status (re-verified against the tree 2026-08-10)

| Phase | State | Where |
|---|---|---|
| K1 `PageResolver` walled-host stopgap | **shipped** | the live junk-card bug is fixed — a pasted rednote link now says "capture with the extension" instead of saving a `"Web - rednote"` card |
| K2 platform + single-note capture | **shipped** | `rednote` exists as a platform, and schema **v18** (`Migrator.swift:162`) re-tagged the pre-platform harvest — closing Open question 1 as **yes, re-tag**, the recommended answer |
| K3 bulk board sweep | **not started, BLOCKED** | no `rednote-hook.js`, no `bulk-rednote.js` in `extension/src/` |
| K4 video stream ladder | **not started** | depends on K3's driver seam |

**K3 is blocked on Open question 3 and that blocker is unchanged**: the sample
board never fired a page-2 request, so the paginated board-feed response shape is
still unverified. A board with **more than 30 notes** is the single input the
driver most depends on, and it can only be captured out-of-band from a logged-in
session (save the response via DevTools into the gitignored `resources/`, then
run `node scripts/drift-check.js`).

Because K4 sits behind K3's seam, "do rednote next" is not currently an
available choice — **capturing that fixture is the next action on this doc**, not
writing code. Everything else here (§A's interception design, §B's three video
rules, the fixtures and drift-canary plan) is ready to build the moment it lands.

## Current state at the time of writing (historical — see Status above)

- **Unsupported everywhere.** `extractors/registry.js:36` registers only
  `twitter, pinterest, instagram, cosmos, web`; rednote is absent from
  `manifest.json` `host_permissions`, absent from the `media-hosts.js` CDN
  allowlist (deny-by-default → every byte fetch refused), and has no bulk adapter.
- **A pasted link silently saves garbage.** rednote is *not* on
  `PageResolver.isAuthWalledHost` (`PageResolver.swift:101`), so a board URL
  resolves: HTTP 200, `og:title` = `"Web - rednote"`, `og:image` = a generic
  270 px card. The user gets a junk item, not an error. This is the one live bug.
- **Board content is entirely client-rendered.** 482 KB of board HTML contains
  exactly one CDN URL — that same generic card. A cookie-less app-side fetch can
  never see the notes; only an authenticated in-browser harvest can.
- **The 2026-07-31 manual run** (grounding for all of the below): 32 notes →
  126 images (242.9 MB) + 19 videos (47.7 MB, 9.7 min), all `downloaded`, tagged
  `platform: web` with `rawMetadata.source = "rednote"`. See Open question 1.

## A — Bulk board sweep (the main body of work)

**The design driver: never reimplement request signing.** rednote signs its API
calls (`webapi.rednote.com/api/sns/web/v1/homefeed`, POST, `X-s`/`X-t` headers
from obfuscated JS). `hook-core.js` already wraps `fetch` *and* `XMLHttpRequest`
in the MAIN world and forwards responses matching a URL predicate — its header
states it is deliberately kept generic "for the next interceptable platform."
The controller scrolls, the page makes its own signed calls, the driver reads the
responses. A signature-scheme change then cannot break the sweep.

- **`extension/src/rednote-hook.js`** — thin config over `hook-core.js` (URL
  matcher + message/replay tags), exactly as `twitter-hook.js` is. Small.
- **`extension/src/bulk-rednote.js`** — the `BulkSource` driver. Model on
  `bulk-instagram.js`, **not** Pinterest: rednote notes are carousels (1–15
  images), so yield **one `BulkItem` per image**, `sourceId` = `noteId:imageIndex`,
  mirroring the per-child fan-out at `bulk-instagram.js:182`. That is what makes
  engine dedup-skip work at picture level.
- **Media URL**: the page serves signed, resized webp
  (`sns-web-i10.rednotecdn.com/<ts>/<sig>/<key>!nc_n_webp_mw_1`). Stripping the
  signature and suffix to `http://sns-i27.rednotecdn.com/<key>` is **public,
  unsigned, and returns the full-resolution original** (verified: 2022×2696 and
  up, vs a 270 px thumbnail). Keep the signed webp as `mediaUrlFallback` — the
  prefer-original/keep-fallback shape of `pickPinImages` (`bulk-pinterest.js:101`).
- **Wiring**: `media-hosts.js:20` gains
  `rednote: (h) => hostIs(h, "rednotecdn.com")` — one entry covers both `sns-i*`
  (images) and `sns-v*` (video); `bulk-context.js:33` gains `platformForHost` plus
  a `/board/<id>` recogniser and its refusal reasons; `manifest.json` gains host
  permissions and the two content-script entries (hook MAIN/`document_start`,
  `bulk-loader.js` ISOLATED).
- Rejected: **calling the signed API directly** (re-deriving `X-s`/`X-t` is a
  treadmill against deliberate obfuscation). Rejected: **DOM-scraping the grid** —
  the board is virtualised (28 → 11 nodes at the bottom), so a scrape must
  accumulate while scrolling and still never sees `imageList`.

**Effort: L.**

## B — Video stream ladder

Each video note carries `note.video.media.stream`, bucketed `EF4`/`EF5`/`EF6`/`EF7`;
each entry has `masterUrl` on `sns-v28.rednotecdn.com` — **clean path, no query
string, no signing** — plus `backupUrls`. Transport is settled: `/ingest-video`
takes raw bytes with provenance base64'd into `X-Atelier-Provenance`, 512 MB cap
(all 19 videos totalled 48 MB). Precedent exists — `pinterest-video.js` /
`twitter-video.js`, and `resolveVideo` is already a popup toggle folded into the
start message (`bulk-context.js:19`).

Three rules, each learned by getting it wrong in the manual run:

1. **Select by codec, never by size.** Taking the largest file landed on a `_330`
   variant with sample-entry fourcc **`ef51`**. It carries a plausible `hvcC` box,
   but relabelling it `hvc1` still fails to decode — the parameter sets are
   invalid (`vps_reserved_three_2bits is not three`, `PPS id out of range`), and
   Quick Look produces no thumbnail. It is an obfuscated stream only rednote's own
   player decodes. **Prefer a sample entry with `avcC`/h264; treat `ef*` fourccs as
   unusable.** Un-obfuscating it is explicitly out of scope.
2. **`thumbnailFailed` means "advance the ladder", not "fail the item".** The
   HTTP 422 from `/ingest-video` is precisely the undecodable-rung signal. Map it
   to a retry against the next variant, not `permanentFailed`.
3. **Never cache a stream list across a resume.** The same note offered a
   *different* ladder on two visits minutes apart. A checkpoint holding a stale
   `masterUrl` will 404 or hand back a bad rung — re-resolve on resume.

Falling back from the `ef51` 1080×1920 rung to an h264 720×1280 rung cost
resolution only: identical duration (45.367 s), same content.

**Effort: M.**

## C — Single-note capture + the junk-card stopgap

- **`extractors/rednote.js`** + one line in `registry.js:36` — right-click "Save to
  Atelier" on an individual note. Small, and independent of A.
- **Stopgap (ship first, ~1 line):** add `rednote.com` (and `xiaohongshu.com`) to
  `PageResolver.isAuthWalledHost` (`PageResolver.swift:101`). Pasting a link then
  says "Capture with the extension" instead of silently saving a
  `"Web - rednote"` card. Fixes the live bug without waiting for A.

**Effort: S.**

## Schema / migration impact

**None required.** `source.platform` is `TEXT`, so `case rednote` in
`Enums.swift:43` is additive. Swift changes are three edits total — the enum,
the originalURL-required list (`Validation.swift:261`), and the display name
(`ItemDetailView.swift:1169`). The job ledger, `known-sources`, `/ingest` and
`/ingest-video` are all platform-blind already.

Optional backfill of the 145 already-harvested assets — see Open question 1.

## Phased implementation

1. ~~**K1 (S)** — `PageResolver` walled-host stopgap.~~ **Shipped.**
2. ~~**K2 (M)** — Swift enum + `media-hosts` + manifest + `extractors/rednote.js`.~~
   **Shipped**, with v18 re-tagging the earlier harvest.
3. **K3 (L)** — `rednote-hook.js` + `bulk-rednote.js` + `bulk-context` → image
   sweep. **Blocked on the pagination fixture** (Open question 3) — see Status.
4. **K4 (M)** — video ladder module + codec selection + `thumbnailFailed` retry.
   Depends on K3's driver seam, so blocked transitively.

## Test strategy

- **Fixtures** (committed, `extension/test/fixtures/`): board feed, note detail
  with a ≥13-image carousel, and a stream ladder that **includes an `ef51` rung**
  so codec rejection is asserted, not assumed.
- **Driver unit tests** mirroring `bulk-pinterest.test.js` — URL builders and the
  JSON→`BulkItem` mapper exported and tested separately, so a response-shape drift
  breaks a test rather than a live sweep.
- **Codec selection** gets its own table test: ladder in → chosen rung out, with
  `ef*`-only input asserting a typed refusal.
- **Drift canary**: a `FIXTURE` entry in `scripts/drift-check.js` plus a `CHECKS`
  invariant in `src/drift.js`, including the codec assertion — the thing that
  would have caught `ef51` before a live run.
- Engine, ledger and endpoint paths need no new coverage (platform-blind).

## Effort: **A: L · B: M · C: S**

## Risks & edge cases

- **`ef51` obfuscated video** — some notes may offer *only* `ef*` rungs. Then the
  honest outcome is cover-still-only for that note; record it as a typed skip, do
  not fail the sweep.
- **Ladder instability between visits** (see B3) — the main resume hazard.
- **`xsec_token` expiry** — tokens ride in the board-feed rows and are needed for
  note detail. A long-paused sweep resumes with dead tokens; re-resolve the feed
  page rather than trusting checkpointed tokens.
- **Virtualised grid** — any DOM-side fallback must accumulate while scrolling.
- **`hasMore` is optimistic** — the sample board reported `hasMore: true` with a
  live cursor while being genuinely complete at 32. Do not treat it as a
  termination signal on its own; use an empty-page counter like
  `bulk-pinterest.js`'s `MAX_EMPTY_PAGES`.
- **Board count disagrees with the feed** — header said "Notes · 33", the feed
  returned 32 across every reload. Assume deleted/unavailable notes exist and that
  header counts are not a completeness check.
- **Two domains** — `rednote.com` and `xiaohongshu.com` must both be covered in
  host matching and permissions.

## Settled decisions

- Intercept the page's own signed responses via `hook-core.js`; never reimplement
  `X-s`/`X-t` signing.
- Fan out one item per carousel image (`noteId:imageIndex`), following Instagram.
- Fetch media from the unsigned full-res CDN form; keep the signed webp as fallback.
- Select video rungs by codec (h264/`avcC`), never by file size; `ef*` is unusable
  and un-obfuscating it is out of scope.

## Open questions

1. ~~**Backfill?**~~ **Answered: re-tagged.** Schema v18 (`Migrator.swift:162`)
   ran the one-shot UPDATE over the 2026-07-31 harvest.
2. **Live Photos in scope?** `imageList` entries carry `livePhoto` and `stream`
   fields — some *stills* on non-video notes have motion attached. Never captured,
   never scoped. Recommend deferring to a follow-up.
3. **Pagination fixture (blocks K3).** The sample board never fired a page-2
   request, so the paginated board-feed response shape is *unverified*. A board
   with >30 notes is needed to capture it — the single input the driver most
   depends on.
4. **Sweep entry point**: board pages only (recommended, mirrors Pinterest), or
   also a user's whole "My saves"?
