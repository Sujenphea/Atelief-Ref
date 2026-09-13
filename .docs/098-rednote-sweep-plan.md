# 098 — rednote board sweep: cover pass + note-detail expansion (plan)

> The implementation plan for [020](feature-todo/020-capture-rednote.md)'s K3/K4.
> Every mechanism below is **verified against live captures taken 2026-09-13**
> (`resources/rednote-board-page2.json`, `rednote-note-02.json`, a last-page
> response, and four `Copy as fetch` request dumps) — not inferred. Where 020
> guessed and the capture disagreed, the capture wins and § "What the capture
> overturned" says so explicitly.
>
> Companions: [015](015-bulk-import-overview.md) (the engine),
> [029](029-capture-instagram-bulk-overview.md) (per-child fan-out precedent),
> [096](096-tier3-plan.md) (`planCapture`, the shared decision seam).

## What the capture overturned

020 was written from a manual harvest, and four of its load-bearing claims are
wrong. They are corrected here so nobody re-derives the plan from 020's prose.

| 020 said | The capture shows |
|---|---|
| Board feed is `POST …/v1/homefeed`, signed | `GET //webapi.rednote.com/api/sns/web/v1/board/note?board_id=…&num=30&cursor=…&image_formats=…` — the URL arrives **protocol-relative** on the XHR path |
| Feed rows carry `imageList` → fan out per image | Rows carry **one `cover`**, nothing else. `imageList` / `video` / `stream` appear **zero** times in the feed response |
| `hasMore` is optimistic, needs an empty-page counter | The real terminator is clean: `has_more: false`, `notes: []`, `cursor: ""` |
| Media key = the last path segment | Wrong for `oss-sg/spectrum/…` images — **a live 404**. See D2 |

020's central instinct — *never reimplement request signing* — is upheld and
strengthened: hand-signing was attempted and **rejected with HTTP 461** (D1).

## Verified shapes

**Board feed** — `data.notes[]`, rows of exactly nine keys, uniform across 37/37:

```
note_id · time · last_update_time · xsec_token · type · display_title
user{ user_id, nick_name, avatar, xsec_token }
cover{ file_id, height, width, url, trace_id, info_list[2], url_pre, url_default }
interact_info{ … }
```

- `cover.url` is **`""` on 37/37**. `cover.file_id` is **`""` on 37/37**. The
  usable URLs are `url_pre`, `url_default`, and `info_list[]`
  (`image_scene` ∈ `WB_PRV` | `WB_DFT`, exactly 2 entries every time).
- `type` ∈ `video` (30) | `normal` (7) — this board is **81 % video**.
- `num=30` returned **37** notes. Page size is not honoured; no count-based
  completeness check is possible.
- Real dimensions (922×1230 … 2588×3449). Covers are not thumbnails.

**Note detail** — `POST https://webapi.rednote.com/api/sns/web/v1/feed`,
body `{ source_note_id, image_formats, extra, xsec_source, xsec_token,
need_translation }` → `data.items[0].note_card`:

```
note_id · type · title · desc · time · last_update_time · ip_location
user{ user_id, nickname, avatar, xsec_token }
image_list[]{ live_photo, height, width, url, info_list[2], url_pre,
              stream, file_id, trace_id, url_default }
tag_list · at_user_list · share_info · interact_info · note_translation
```

- Sample note: **9 images**, all `1242×1660`, `live_photo: false`, `stream: {}`.
- `desc` (408 chars) and `title` exist **only** here — the feed row has only
  `display_title`.
- **`user.nickname` in detail vs `user.nick_name` in the feed.** A shared author
  mapper written against one shape silently yields `null` on the other. D6.

## D1 — Acquisition: intercept only. Never sign, never replay.

`x-t` is a live millisecond timestamp and `x-s` is signed over the request, so a
stored signature cannot be replayed against a different `cursor`. Confirmed by
experiment: calling the page's own `window._webmsxyw` and issuing the detail POST
returned **HTTP 461** with `msg: ""` (every genuine response says `msg: "成功"`),
and the signer's `XYW_`-prefixed output does not match the `XYS_` the page sends —
there are further layers (`x-s-common`, `x-rap-param`, `anti_hp_sign_config`).

Two consequences, both binding:

1. **`hook-core.js`'s request proxy does not transfer.** It works for X because
   X's auth is a URL-independent bearer token. rednote's is URL-bound. It is also
   GET-only by construction (`serveProxyRequest`), and detail is a POST.
2. **Resume cannot be seekable.** rednote rides `createInterceptSource`, whose
   `enumerate()` already ignores the engine's `{ cursor }`
   (`intercept-source.js:123`). Resume = re-scroll + dedup-skip.

**Sub-task (shared, small):** an intercept source should declare
`resumable: "scroll"` so the engine stops persisting a cursor nothing reads. The
checkpoint stays useful for `jobId` reopening; the cursor field becomes honest.

## D2 — The media-key rule (fixes a live bug)

`toRednoteOriginal` (`extractors/rednote.js:47`) takes the **last path segment**
as the object key. For `oss-sg/spectrum/…` images that drops two segments:

```
http://sns-i27.rednotecdn.com/oss-sg/spectrum/1040g3ug…  → 200  image/jpeg  240,729 B
http://sns-i27.rednotecdn.com/1040g3ug…                  → 404            ← we generate this
```

**This degrades captures today.** The 404 is masked by `mediaUrlFallback`, so the
item saves — as the 47,226 B signed webp instead of the 240,729 B original. 5×
quality loss, silent, no log. It is not a sweep bug; it is a shipped bug the sweep
would inherit, which is why it is T0.

**The rule:** the signing prefix is always `<timestamp>/<sighex>/`, so the key is
**the path minus its first two segments**, `!transform` suffix stripped.
`file_id` corroborates it when non-empty.

Validated over **184 URLs** from both captures: drop-two agrees with `file_id`
on **184/184**; last-segment disagrees on 36; and drop-two still works where
`file_id` is `""` (all board covers).

Prefer the unsigned original, keep the signed URL as `mediaUrlFallback` — the
existing Pinterest `pickPinImages` shape, unchanged.

## D3 — K3a: the cover pass

One `BulkItem` per note, from the intercepted board feed alone.

| field | source |
|---|---|
| `sourceId` | `note_id` |
| `mediaUrl` | `toRednoteOriginal(cover.url_pre)` |
| `mediaUrlFallback` | `cover.url_default` (signed, always loads) |
| `originalURL` | `https://<host>/explore/<note_id>?xsec_token=<row token>` |
| `authorName` | `user.nick_name` · `authorHandle`: `null` (no username exists) |
| `title` | `display_title` |
| `rawMetadata` | `{ noteId, type, xsecToken, userId, width, height }` |
| `cursor` | the `cursor` parsed off the **intercepted request URL** |

No signing, no extra request, one intercepted response per 30–37 notes.

**Termination:** `data.has_more === false`. `cursor: ""` must be treated as
**absent** — Instagram's `next_max_id != null` idiom (`bulk-instagram.js:225`)
would read `""` as live and loop. Keep Pinterest's `MAX_EMPTY_PAGES` as a
belt-and-braces guard against a pathological feed, not as the primary signal.

## D4 — K3b: detail expansion by driving the page, not by signing

The sweep opens each note through the SPA; the page issues its own correctly
signed `POST /api/sns/web/v1/feed`; the hook intercepts the response. Same
principle as the board pass (*the page signs, we listen*), generalised from
"scroll to fetch more" to "open to fetch detail". It survives signature rotation
by construction.

It rides the **existing** `expandItems` seam (`intercept-source.js`) — the
optional, gracefully-degrading hook X uses for thread expansion. **K3a is
literally the unexpanded path**, so K3b is additive, and a failed expansion
degrades to the cover rather than failing the item.

Fan-out on expansion: one `BulkItem` per `image_list[]` entry,
`sourceId = <note_id>:<index>` — 020's Instagram-shaped decision, preserved, just
sourced from detail instead of the feed.

**Costs, stated plainly:** one note-open per note (~400 on a large board); much
slower than the cover pass; fragile against SPA route/DOM change; and a heavy
automation footprint against a site shipping `xhsFingerprintV3` and an active
anti-bot layer. D8's warning gate and pacing exist because of this.

**A cover-pass item and its expanded children have different `sourceId`s**
(`<id>` vs `<id>:0`). A board swept cover-only and later re-swept with expansion
will therefore re-ingest, not dedup-skip. Named as Open question 2 — it needs a
decision before K3b ships, not after.

## D5 — K4: the video ladder

Blocked: **no `type: "video"` note detail has been captured yet.** 81 % of the
sample board is video, so this is most of the content, not a tail case.

What holds regardless:

- **Select by codec, never by size** — 020's rule, learned by getting it wrong.
- The only pre-download signal is the **`EF4`/`EF5`/`EF6`/`EF7` bucket name**; a
  fourcc (`ef51`) lives in the MP4 bytes. So `selectStreamRung(ladder)` is a pure
  function over JSON, table-tested, with an `ef*`-only input asserting a typed
  refusal.
- The 422 from `/ingest-video` is the *backstop* for a mis-classified bucket. To
  act on it, `planCapture` must return ordered `videoCandidates[]` (one element
  for every existing platform — behaviour-identical) and `ingestOne` must walk it
  (`sw.js:269`, today a single try then still-fallback). `capture-plan.js` is
  shared with tier 3, so this is a deliberate change to a shared seam, staged
  behind the pure selector.
- **Never checkpoint a stream list** — 020 B3, a ladder differed between visits.

## D6 — DRY: what must be shared, and one trap

- `bulk-rednote.js` **imports** `toRednoteOriginal`; it does not re-derive it.
  020 describes the rewrite as new work — it shipped with K2.
- The cover mapper and the detail-image mapper both consume
  `{ url_pre, url_default, info_list, file_id }` — **one** `pickRednoteImage()`
  serves both, because the shape is genuinely identical.
- **The trap:** `nick_name` (feed) vs `nickname` (detail). One author mapper must
  read both, with a test asserting each shape, or it silently returns `null`.

## D7 — Platform registration

rednote is the 4th sweep platform and touches nine unconnected places, none of
which fail at build time (`bulk-context.js` ×2, `bulk-controller.js` ×2,
`manifest.json`, `media-hosts.js` ✓ shipped, `popup-view.js`, `config.js`,
`drift.js`). Miss the manifest entry and the hook never installs; miss
`drift.CHECKS` and the parser rots silently.

**Add a consistency test, not an abstraction.** One `platform-registry.test.js`
asserting every `SUPPORTED_PLATFORMS` member has a `platformForHost` branch,
non-generic `sweepLabel` copy, a `media-hosts` predicate, a `drift.CHECKS` entry,
a pacing entry or a deliberate absence, and manifest `content_scripts` +
`web_accessible_resources` coverage. Test-only blast radius; a descriptor
registry is premature at n=4.

## D8 — Account risk and pacing

The capture shows `as.rednote.com/api/sec/v1/shield/webprofile`,
`xhsFingerprintV3`, `x-rap-param` and a 461 risk-control status. rednote profiles
actively. So:

- `sweepWarning()` gains a rednote entry — the mandatory acknowledge gate
  Instagram has (`popup-view.js`), which 020 never proposed.
- `PLATFORM_PACING.rednote` starts at **Instagram's** numbers or gentler.
- **Early-stop stays disarmed.** IG earned `STOP_AFTER_CONSECUTIVE_SKIPS` with a
  live-verified newest-first ordering precondition. Board ordering is unverified;
  copying it would silently truncate sweeps.
- A 461 must be recognised as a **challenge → halt resumable**, mirroring
  `detectChallenge`. It is not an HTTP status the engine's classifier knows.

---

## Tasks

### T0 — the `toRednoteOriginal` fix *(ships independently of everything below)*
Drop-two-segments + `file_id` preference. Tests: both URL shapes, `file_id`
empty vs populated, idempotence, non-rednote passthrough, unparseable input.
Fixture rows lifted from the two captures. **Effort: S.**

### T1 — the pure parser: `bulk-rednote.js`, cover pass
`parseBoardFeedPage(json, { host, cursor })` → `{ items, endOfFeed, cursor }`;
`pickRednoteImage(imageish)`; `mapBoardNote(note, ctx)`; `cursorFromRequestURL(url)`
(must handle the **protocol-relative** `//webapi…` form — `new URL()` throws on
it). No browser API; unit-tested against the committed fixture. **Effort: M.**

### T2 — `rednote-hook.js` + wiring
Thin config over `hook-core.js`: matcher pinned to `/api/sns/web/v1/board/note`
(**not** host-shaped — `t2.rnote.com/api/v2/collect` and `apm-fe.rnote.com` are
telemetry on adjacent hosts). Manifest content_scripts (MAIN `document_start` +
ISOLATED loader) and WAR matches for both domains. `bulk-context.js` recogniser
(board id is **24-char hex**, not digits — Pinterest's `/^\d+$/` cannot be
copied), `REASON_MESSAGE`, `sweepLabel`, `sweepWarning`, `SUPPORTED_PLATFORMS`,
`buildRednoteDriver`, `PLATFORM_PACING`. **Effort: M.**

### T3 — drift canary
`drift.CHECKS.rednote` + a committed sanitized fixture
(`node scripts/sanitize-capture.js`). Invariants: envelope shape, per-note cover
resolves to an unsigned original, `has_more:false`/`cursor:""` terminates,
`cover.url` being `""` does **not** drop the item, route matcher still matches.
Plus T0's key rule. **Effort: S.**

### T4 — `platform-registry.test.js` (D7). **Effort: S.**

### T5 — K3b: note-open driving + detail parser. **Effort: L.** Gated on Open q2.

### T6 — K4: `selectStreamRung` + `videoCandidates[]` + 422 rung-advance.
**Effort: M.** Blocked on a video-note capture.

## Sizing

**T0 S · T1 M · T2 M · T3 S · T4 S** — a shippable cover sweep.
**T5 L · T6 M** — full fidelity, separately schedulable.

## Test strategy

- Pure mappers/parsers exported and tested separately from transport, mirroring
  `bulk-pinterest.test.js` — a response-shape drift breaks a test, not a live run.
- Table tests for the key rule (both URL shapes), the author mapper (`nick_name`
  **and** `nickname`), termination (`has_more:false`, `cursor:""`, empty page),
  and codec selection (`ef*`-only → typed refusal).
- Edge cases that must have named tests, because each is a real observed shape:
  `cover.url === ""`, `cover.file_id === ""`, `num` not honoured, protocol-relative
  request URLs, 461 → challenge-halt, a note with `image_list` absent.
- Engine/ledger/endpoint need no new coverage — platform-blind.

## Risks

- **461/risk-control mid-sweep** — must halt resumable, not burn.
- **Note-open driving is the fragile half** (D4); the cover pass does not depend
  on it, which is why they are separate phases.
- **`xsec_token` expiry** on a long-paused sweep — re-resolve from the feed, never
  from a checkpoint.
- **Two domains** (`rednote.com`, `xiaohongshu.com`) in every host match.
- **Video may be most of a board** (81 % here) — a cover-only sweep of a video
  board is a shelf of stills. Set expectations in the popup label.

## Open questions

1. **Board URL path shape** — the capture gives `board_id=69322476000000001202811f`
   in the query and `referrer: https://www.rednote.com/`, but the *page* URL was
   never recorded. Needed for the `bulk-context.js` recogniser.
2. **Cover→expanded `sourceId` migration** (D4). Re-sweeping an expanded board
   after a cover-only pass re-ingests. Decide before K3b.
3. **Sweep entry point** — boards only (recommended, mirrors Pinterest), or also
   a user's "My saves"?
4. **Live Photos** — `image_list[].live_photo` exists (`false` on the sample) and
   each image carries a `stream` object. Never captured, never scoped. Defer.
5. **Video ladder shape** — unverified; T6 is blocked on one capture.
