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

## Review outcomes (2026-09-13)

Sixteen issues raised across architecture, code quality, tests and performance.
Recorded here because several change the task ORDER, and one (R14) found a gap
rather than a preference.

| # | Decision |
|---|---|
| R1–R4 | Settled by the captures, not by argument: resume cannot be seekable; detail is required; the ladder is staged; registration gets a consistency test |
| R5 | A test evaluates each MAIN-world hook in a sandbox and asserts its literal tags + matcher equal `bulk-messages.js` — replacing 8 "KEEP IN SYNC" comments with a gate |
| R6 | `DRIVER_BUILDERS` map; derive `SUPPORTED_PLATFORMS` from its keys. Deletes the duplicated list AND the `else`-defaults-to-Pinterest branch |
| R7 | `onExpandFailure` now (count + log the degradation); a first-class `partial` outcome is **on the K3b ship list**, not assumed |
| R8 | One `pickRednoteImage` + one `rednoteAuthor` (both key spellings). Cross-platform pickers stay separate — their rules genuinely differ |
| R9 | **`intercept-source.test.js` is written FIRST**, before R1/R7 touch the seam |
| R10 | `detectRednoteChallenge` mirroring IG's, plus coverage of `pendingError` — a path with no production user and no test today |
| R11 | Sanitize the real captures into the two-fixture split. Baseline staleness (72d vs 30d) noted, **not** queued |
| R12 | `bulk-rednote-integration.test.js` — the `cursor: ""` loop is invisible to per-page tests |
| R13 | Budget the cost; expansion becomes an opt-in popup toggle beside `resolveVideo`; cover-only is the default |
| R14 | **Known-set pre-check before expansion** — see below |
| R15 | Bound the hook replay buffer by SIZE as well as count. **Narrowed during T1b**: clearing after a replay was dropped — a second sweep on the same tab would replay nothing and could stall where today it replays and dedup-skips. The size bound fixes the actual harm without touching replay semantics |
| R16 | **Do nothing** about the per-item `SELECT status FROM job`. A real N+1, but a µs local PK read against a deliberate 1,500–2,700 ms pacing budget — optimising it measures the wrong thing |

### R14 — the gap, not a preference

`expandItems` runs inside `intercept-source.enumerate`, *before* the engine's
known-set check skips the relay. So re-sweeping an already-captured board under
K3b re-scrolls it, **re-opens all ~400 notes**, yields ~3,600 items, skips every
one, and ingests nothing — full cost, zero result, with early-stop disarmed so
nothing short-circuits it.

The fix is to pre-check the known-set before opening a note. That is only cheap
if the `sourceId` scheme makes "is this note done?" a lookup rather than a prefix
scan over `noteId:index` entries.

**Settled (2026-09-13): derive a note-level index, gate it on the clean marker.**
At sweep start, alongside the known-set:
`knownNotes = new Set([...knownSet].map((id) => id.split(":")[0]))` — O(n) once,
O(1) per note, and **no change to the `sourceId` scheme**, so nothing already
ingested needs migrating.

The residual risk is a note captured PARTIALLY (a sweep that died after 3 of 9
images looks "done"). That is handled by the precondition that already exists for
exactly this shape of optimisation: `sweepCleanMarkerKey`
(`bulk-controller.js:182`) records whether the prior run of this scope closed
failure-free, and Instagram already gates its early-stop on it. **Arm the
pre-check only when the prior sweep closed clean.**

Rejected: keying the cover as `<note_id>:0` to unify the namespace — it depends on
`cover == image_list[0]`, which is unverified, and 30 of 37 sampled notes are
`type: "video"`, where the cover is a poster that may not be in `image_list` at
all. Rejected: recording an expected image count — the count is not in the feed
row, so learning it requires the note-open the check exists to avoid.

## Tasks

Ordering matters: T1a exists because T1b and T5 modify a seam that has no tests.

### T0 — the `toRednoteOriginal` fix ✅ **shipped** (changelog 468)
Drop-two-segments; idempotence; short-path passthrough. 636 → 639 tests.

### T1a — `intercept-source.test.js` (R9, R10)
The seam tested generically — fake `parsePage`/`scroll`/`sleep`. Must cover what
X never exercises: `expandItems` success/throw/degrade, and the **`pendingError`
re-raise** (no production user, no test today). **Effort S–M. Do this first.**

### T1b — seam changes (R1, R7, R15) ✅ **shipped** (changelog 470)
`resumable: "scroll"` + the engine honouring it; `onExpandFailure`; a size bound on
the hook replay buffer. Behaviour-preserving for X. 661 → 667 tests.

### T2 — the pure parser: `bulk-rednote.js`, cover pass (R8, R10)
`parseBoardFeedPage` → `{ items, endOfFeed, cursor }`; `pickRednoteImage`;
`rednoteAuthor` (**`nick_name` and `nickname`**); `mapBoardNote`;
`cursorFromRequestURL` (must handle the **protocol-relative** `//webapi…` form —
`new URL()` throws on it); `detectRednoteChallenge` (461 / empty `msg` / code).
**Effort M.**

### T3 — `rednote-hook.js` + wiring (R5, R6)
Matcher pinned to `/api/sns/web/v1/board/note` — **not** host-shaped
(`t2.rnote.com`, `apm-fe.rnote.com` are telemetry on adjacent hosts). Manifest
content_scripts + WAR for both domains. `bulk-context.js` recogniser (board id is
**24-char hex** — Pinterest's `/^\d+$/` cannot be copied), `REASON_MESSAGE`,
`sweepLabel`, `sweepWarning`, `DRIVER_BUILDERS` map, `PLATFORM_PACING`. Plus the
hook-sync test. **Effort M.**

### T4 — fixtures + canaries (R11, R12, and R4's registry test)
Sanitize the captures into `rednote-board.json` (parser) +
`rednote-board-live.json` (canary). `drift.CHECKS.rednote`.
`bulk-rednote-integration.test.js` — pagination, `has_more:false`,
**`cursor:"" does not loop`**, 461 → halt resumable, dedup-skip on re-sweep.
`platform-registry.test.js`. **Effort M.**

### T5 — K3b: note-open driving + detail parser (R13, R14, R7)
Opt-in toggle, cover-only default, budgeted cost, known-set pre-check.
**Effort L. Gated on Open question 2.**

### T6 — K4: `selectStreamRung` + `videoCandidates[]` + 422 rung-advance
**Effort M. Blocked on a `type: "video"` note capture.**

## Sizing

**T1a S–M · T1b S · T2 M · T3 M · T4 M** — a shippable, tested cover sweep.
**T5 L · T6 M** — full fidelity, separately schedulable and separately gated.

## Cost budget (R13)

A 400-note board, at the adopted Instagram pacing:

| | Cover pass | Full fidelity |
|---|---|---|
| Note-opens | 0 | ~400 (serial, ≥13 min) |
| Items | ~400 | ~3,600 |
| Relay time | ~5–9 min | ~45–80 min |
| Bytes | ~88 MB | ~860 MB (multi-GB at 020's observed sizes) |

Cover-only is the default because of this table, not despite it.

## Test strategy

- Pure mappers/parsers exported and tested apart from transport, mirroring
  `bulk-pinterest.test.js`.
- Table tests: the key rule (both URL shapes), the author mapper (**both**
  spellings), termination (`has_more:false`, `cursor:""`, empty page), codec
  selection (`ef*`-only → typed refusal).
- Named tests for every real observed shape: `cover.url === ""`,
  `cover.file_id === ""`, `num` not honoured, protocol-relative request URLs,
  461 → challenge-halt, `image_list` absent.
- Engine/ledger/endpoint need no new coverage — platform-blind.

## Risks

- **461 mid-sweep** — must halt resumable. First real user of `pendingError`.
- **Note-open driving is the fragile half**; the cover pass does not depend on it.
- **`xsec_token` expiry** on a long-paused sweep — re-resolve from the feed.
- **Two domains** in every host match.
- **Video may be most of a board** (81 % here) — say so in the popup label.
- **Drift fixtures are 72 days stale** against a 30-day window (pre-existing).

## Open questions

1. **Board URL path shape** — never recorded; needed for the recogniser.
2. ~~**`sourceId` scheme across cover → expanded**~~ **Settled** — keys unchanged;
   a derived `knownNotes` index, armed only after a clean prior sweep. See R14.
   Still worth one cheap capture: open a note that IS on a saved board page and
   check whether `cover` equals `image_list[0].file_id`, and whether a
   `type: "video"` note's `image_list` holds the poster or is empty. That would
   also unblock T6.
3. **Entry point** — boards only (recommended), or also "My saves"?
4. **Live Photos** — `image_list[].live_photo` exists. Defer.
5. **Video ladder shape** — unverified; T6 blocked on one capture.
