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

**Corrected 2026-09-14 (T4a).** This section, and `toRednoteOriginal`'s own doc
comment, said the multi-segment keys were a note-detail concern and that a board
cover was keyed `<id>` — one segment. Sanitizing the live capture disproved it.
Across the 37 rows of one ordinary board:

| cover key shape | rows |
| --- | --- |
| `<id>` | 15 |
| `spectrum/<id>` | 16 |
| `oss-sg/notes_pre_post/<id>` | 6 |

So the last-segment rule 404'd on **22 of 37 rows of a plain board sweep**, not
on some narrower slice of detail images. T0 was a larger fix than it was scoped
as, and the drop-two rule is load-bearing on the cover pass itself — which is why
the canary now asserts the *input* properties of its fixture (signed host, ≥3
path segments, a surviving `!` suffix) rather than only the output.

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

### T2 — the pure parser: `bulk-rednote.js`, cover pass (R8, R10) ✅ **shipped** (changelog 471)
`parseBoardFeedPage`, `pickRednoteImage` (serves cover AND `image_list`),
`rednoteAuthor` (both spellings), `mapBoardNote`, `cursorFromRequestURL` /
`boardIdFromRequestURL` (protocol-relative safe), `matchesScope`,
`isBoardFeedRequest`, `detectRednoteChallenge`. 28 tests, 12 of them against the
live capture. 667 → 695 tests.

`xsec_token` rides as a LOCAL `BulkItem` field, never inside `provenance` — the
single-capture path already establishes that a short-lived credential does not
belong in stored provenance.

### T3 — `rednote-hook.js` + wiring (R5, R6) ✅ **shipped** (changelog 472)
Matcher pinned to `/api/sns/web/v1/board/note` — **not** host-shaped
(`t2.rnote.com`, `apm-fe.rnote.com` are telemetry on adjacent hosts). Manifest
content_scripts + WAR for both domains. `bulk-context.js` recogniser (board id is
**24-char hex** — Pinterest's `/^\d+$/` cannot be copied), `REASON_MESSAGE`,
`sweepLabel`, `sweepWarning`, `DRIVER_BUILDERS` map, `PLATFORM_PACING`. Plus the
hook-sync test. **Effort M.**

### T4 — fixtures + integration (R11, R12) ✅ **shipped** (changelogs 483, 484)
`drift.CHECKS.rednote` and `platform-registry.test.js` landed early in T3: the
registry test refused to let rednote be half-added, which is what it is for.

**T4a — fixtures.** `rednote-board-live.json` (sanitized 37-note canary) and
`rednote-board.json` (a trimmed first page). rednote now reports as a real PASS
instead of `⊘ NEVER VERIFIED`. The sanitizer needed three fixes to get there, and
the first is the one worth remembering: it rewrote CDN hosts to
`sample2.example.com`, and `toRednoteOriginal` passes through anything not on
`rednotecdn.com` — **the fixture would have exercised no rewrite at all while the
canary went green.** Also: `nick_name` was not an identity key (only `nickname`
was — D6's trap biting the sanitizer), leaking 6 display names; and rednote ships
`interact_info` counts as pre-formatted strings (`"27.7K"`), which the
number-only `_count` rule never saw. LEAKED 28 → 0. Re-sanitizing the IG and
Pinterest raws reproduces their committed files byte for byte.

**T4b — `bulk-rednote-integration.test.js`,** 14 cases proving parser, seam and
engine compose: two-page union, `has_more:false`, **`cursor:"" terminates`** (in
both the live-last-page and the `has_more:true` forms), an empty page that is
*not* the end, a scroll wall, a 461 halting resumable with `cursor: null`
checkpointed, dedup-skip, a cross-page duplicate, a coverless row dropped at the
parser, and a foreign board's page — and its *refusal* — ignored by scope. Every
load-bearing assertion was verified by mutation: each fails when the property it
names is broken. 715 → 729 tests.

### T5 — K3b: note-open driving + detail parser ✅ **shipped** (changelogs 485, 486)
Split the way T2 → T3 was split.

**T5a — the pure detail parser.** `parseNoteDetail` fans out one item per
`image_list[]` entry, `sourceId = <note_id>:<index>`, reusing `pickRednoteImage`
and `rednoteAuthor`. Two judgement calls worth remembering: a `live_photo: true`
entry **keeps the still** and flags it (Q4 defers the *motion*, which lives in
`stream` — dropping the item would cost a real image), and a `video`-bearing note
is **refused visibly** (`unsupported: "video"`, cover kept) rather than fanned
out, because its poster is already ingested as `<note_id>` by the cover pass and
fanning out would re-enqueue the same picture as `<note_id>:0` — two keys, two
downloads, a dedup-skip that cannot see the duplicate. `items: []` with
`unsupported` set means *keep the cover*, never "this note is empty". A `rednote-detail`
drift check sits beside `rednote` the way `x-thread` sits beside `x`. 729 → 756 tests.

**T5b — the driving.** `rednote-detail-client.js`, shaped after
`twitter-detail-client.js`: it **clicks the note's own card link** rather than
assigning `location` (which would tear down the content script and the sweep with
it), closes with Escape, falls back to `history.back()` if the SPA routed rather
than overlaid, and restores `scrollY` so the board keeps paging from where it was
— in a `finally`, so a challenge still gives the board back. Correlation is by
`parseNoteDetail().noteId` against the note opened, with mismatches discarded,
except that a **refusal outranks correlation** (it carries no note id to
correlate on). Budget `NOTE_OPEN_BUDGET = 400` opens/sweep at 1800 ms ± 1200;
exhaustion is not a halt — the cover pass finishes and the sweep reports
`partial`. 756 → 823 tests.

### T5 addendum — R14's formula was not safe as written

Two defects, both found while building, both fixed:

**Mode-blindness (sweep level).** Cover items are keyed `<note_id>`, expanded
children `<note_id>:<index>`, so after a cover-only sweep `knownNotes` holds
*every note on the board* — a user who then enables the toggle has every
note-open skipped and is told "complete, 0 new". The toggle would have done
nothing on any board already swept, silently, inverting the failure R14 cured (a
loud waste of budget). Fixed by recording the sweep's **mode** in the clean marker
(`{ clean, mode }`, `"cover" | "expansion"`) and arming the pre-check only when the
prior clean sweep was at least as rich as this one. A marker with no `mode` reads
as unknown, arms nothing, and leaves `STOP_AFTER_CONSECUTIVE_SKIPS` untouched —
tested against Instagram, not in the abstract.

**Over-broad derivation (note level).** `id.split(":")[0]` over *every* known id
cannot tell a cover from an expanded child, so a note that **degraded**, or that
the **budget never reached**, reads as done. A board larger than the budget could
therefore never be finished: every re-sweep would spend its whole budget
re-opening notes already done. `knownNoteIndex` counts **only ids that are
expanded children**. Same O(n)/O(1) cost, no `sourceId` change.

The rejected `<note_id>:0` unification stays rejected, now on evidence rather
than suspicion: the detail capture's `file_id`s are `oss-sg/spectrum/<id>` while
board covers are 15/37 bare `<id>` — **cover ≠ `image_list[0]`**.

### T6 — K4: the video ladder ✅ **shipped** (changelogs 487, 488, 490)
Unblocked 2026-09-14 by a `type: "video"` note detail capture, and split into
three commits.

**T6a — a second silent 404, and it was not latent.** The video `master_url` is
**already unsigned** (`sns-v11.rednotecdn.com/stream/1/110/258/…_258.mp4`), but
`toRednoteOriginal` asked only "are there ≥3 path segments" and so stripped
`stream/1/` and rehosted it on the image origin. Verified live: the URL as sent
returns 206 `video/mp4`, the rewritten one 404. The guard now tests the real
invariant — the first two segments must *look like* signing material
(`/^\d{10,14}$/` then `/^[0-9a-f]{32}$/i`), validated over 138 distinct URLs with
`file_id` agreeing 40/40 and no image answer changed. **This was reachable
today**, not merely latent: the single-capture path runs `largestMedia(harvest,
CDN)` with no `kind` filter, and `harvest.js` emits `kind: "video-src"`. A second
unsigned family exists too — subtitles, signed by `?sign=` query — which is the
stronger argument that signed-in-path is the special case.

**T6b — the selector.** `selectStreamRung` drops url-less, non-mp4 and
`ef??`-fourcc rungs, orders buckets `EF4`…`EF7` with unknown names last, never by
size (020 rule 1), and returns a typed refusal (`no_ladder` / `empty_ladder` /
`no_usable_rung` / `undecodable_codec`). **`ef*` is a four-character fourcc
(`ef51`), not the three-character bucket label (`EF4`)** — relaxing the guard to
`/^ef/i` breaks 21 tests, because it would refuse every rung rednote has ever
sent. `videoCandidates` is `master_url` then `backup_urls[]` per rung — D5
predated the discovery that `backup_urls[]` exists. 020 rule 3 is enforced
structurally: the property is **non-enumerable**, so `JSON.stringify`,
`structuredClone` and spread all drop it, and a guard test runs the real
`runSweep` asserting no stream url reaches a checkpoint.

**T6c — the ingest walk.** `planCapture` grows an ordered `videoCandidates[]`
(one element for the other three platforms — the saved result gained no field, so
`sw.test.js`'s `deepEqual` assertions pass unchanged, which is the cheapest proof
of identity). `ingestOne` walks it: **422 → advance** (020 rule 2), CDN 404/410 →
advance (the candidate is gone; retrying spends four backoffs on a dead url), a
non-video body or over-cap clip → advance, transport failure → stop (it says
nothing about the rung). Bounded at `MAX_VIDEO_CANDIDATES = 4`, since each
attempt is a whole download. Exhaustion is `{ status: "skipped" }` — a typed
skip with the cover kept, never a failed item.

Video notes now yield `<note_id>:v`, **not** a fanned-out poster: a video note's
one-entry `image_list` is the same picture the cover pass already ingested as
`<note_id>`, so fanning out would be one picture, two keys, two downloads and a
dedup-skip that cannot see the duplicate. `:v` registers as an expanded child
under `knownNoteIndex`'s real predicate, so a captured video note is not
re-opened. An **`ef*`-only note is re-opened** on the next expansion sweep, on
purpose: 020 B3 saw one note serve a different ladder minutes apart, so a refusal
is a fact about one visit, not about the note.

`resolveVideo` gains no sibling: `expandNotes` decides whether notes open,
`resolveVideo` whether a video note is one of them. Off/off is the cover pass;
on/off is T5b exactly; on/on adds the streams — and because that is ~5× the
note-opens on an 81 %-video board, D8's risk gate re-renders and resets its
acknowledgement on the video checkbox too. `refused` and `streamRefused` are
counted apart and neither is `partial`: a sweep that read the ladder did what it
set out to do.

## The first live run (2026-09-14) — what running it actually found

Everything above T7 was verified against captures and tests. Then the extension
was loaded and pointed at a real board. **Five defects surfaced that no fixture
could have shown**, and one load-bearing claim in this plan turned out false.

### L1 — the sweep captured 78 of 116 notes and reported `complete`
The worst kind: a wrong answer wearing a success. Cursor evidence from the page's
own responses, across two passes:

| page | notes | next cursor |
| --- | --- | --- |
| A | 38 | `6a804923…` |
| B | 37 | `6a650248…` |
| C | 38 | `6a616185…` |
| D | 3 | `""` (end) |

The sweep saw B, C, D only. **116 − 78 = 38, exactly one page.** The board feed is
cursor-FORWARD and the driver's only lever is `scrollTo(bottom)`, which can never
re-request an earlier page — so a sweep started on an already-scrolled board can
only capture from where the page happens to be. The replay buffer is not the
constraint (25 entries, 8 MB).

**Fixed, and confirmed live: a mid-scrolled board now yields all 116.** In two
parts, deliberately. `392dc8d` makes the sweep **refuse** unless
it holds the feed's first page (`isFirstBoardFeedRequest`, halting resumable).
That is a guard, not a fix — it converts silent loss into a loud refusal. `d927083`
is the fix: the sweep **resets the feed in-page** by clicking the board's own
`/user/profile/<id>` anchor and going back, which was verified live to re-request
with `cursor=""`. A reload was rejected — it tears down the content script the
sweep runs in. The guard stays as the assertion that the reset worked.

Two subtleties the reset had to get right, both found by mutation: the back leg
fires **only after the click is confirmed to have routed** (otherwise `history.back()`
pops the board itself off the stack), and responses arriving before the decision
are **held, not forwarded** — without that, a board scrolled to its bottom replays
the exhausted tail page, which queues ahead of the refetched page A and ends
enumeration before page A is yielded. That is L1 rebuilt out of its own repair.

### L2 — K3b expansion cannot reach most notes on a real board
**The grid is virtualised: 13 cards mounted, against 37–38 notes per feed page.**
`findLink` can only click a card that is in the DOM, and expansion runs over a
whole page *after* it arrives, by which time most of those cards have unmounted.
So expansion succeeds for the handful on screen and degrades the rest.

020's risk list named "Virtualised grid" and the driver never accounted for it.
**This plan's T5/T6 entries claimed expansion shipped; they did not say it cannot
reach most of a board.** `33632bd` makes the shortfall visible — `unreachable`
(could not reach the note) is counted apart from `degraded` (reached it, no
answer), and the terminal line now reads `expanded 13 of 116; 103 had no card on
the page to open`. **That is honesty, not a fix.** The fix is **2A** — interleaving
expansion with the scroll so notes open while their cards are mounted — and it is
**outstanding work, not shipped.**

### L3 — the note-open clicked a link that 404s
The board renders **two anchors per note** and the tokenless one comes first in
document order, so `querySelector` took the one without `xsec_token` — which
rednote answers with a 404. Fixed in `295c5a1` by preferring the tokenised anchor.
The same commit found a third route shape (`/discovery/item/<id>`, alongside
`/explore/<id>` and the board's `/board/<board>/<note>`) and a `closeNote` history
fallback that tested for `/explore/` and therefore **could never have fired on a
live board**.

### L4 — every resumable halt rendered the same sentence
`terminalMessage` was discarding `result.error` outright, so the stall, the 461 and
the new refusal were indistinguishable in the popup. Found while wiring L1's
refusal (`392dc8d`). It is why the first live stall said so little.

### L5 — a selector-injection test that could never fail
The fake window's selector parser returned `[]` for anything it did not recognise,
and a guard breakout produces a **valid** selector, not a malformed one. Found by
mutating the id guard and watching nothing fail (`295c5a1`).

### Decided, and deliberately not built
**3B — the expansion batching stays.** `items = await expandItems(items)` blocks a
whole page, so nothing is ingested for 2–5 minutes with expansion on. It is latency,
not loss, and whatever 2A does will restructure how `expandItems` is driven — fixing
it first risks doing the same work twice in a file all four platforms share.

### What the live run confirmed
The cover pass captures a real board end to end; a re-sweep deduped all 78 against
a live job ledger (`ingested: 0, skipped: 78`); the parser handled pages of 37, 38
and 3 despite the request asking `num=30`; and the board URL recogniser accepted
the real URL, query string and all — closing **Open question 1**.

### Unverified without a live run
- **`createPageNoteDriver`** infers the board card's link shape and the overlay's
  close affordance; neither was captured, and it now drives video notes too. A
  failure degrades **loudly** — the degradation count and the partial status line
  — and leaves the cover pass untouched. With D8's gate, that is why expansion is
  opt-in.
- **Only `EF4` has ever been populated.** Between-bucket ordering and the
  422-advance *between* rungs have never met a real multi-rung ladder; those tests
  use invented shapes and are labelled as such. The within-rung walk across
  `backup_urls[]` is the half the live capture covers. The 422 backstop is what
  makes a wrong guess recoverable rather than fatal.
- **No capture carries a fourcc in `video_codec`**, so `ef*` → `streamRefused` →
  re-open is exercised by tests alone.
- `master_url` was fetched live from a browser (206, `video/mp4`), **not** from
  the service worker's cookie-less cross-origin fetch.
- ~~**The reset, end to end.**~~ **Verified 2026-09-14**: a sweep started on a
  deliberately mid-scrolled board drove the reset itself and captured all **116**
  notes — the same board and the same starting condition that silently yielded 78
  before `d927083`. Still one board and one SPA build, so the guard stays; any
  divergence lands there rather than in a wrong capture.
- `FEED_RESET_SETTLE_MS = 1200` and `FEED_RESET_GRACE_MS = 1500` are **reasoned,
  not measured**. Too short shows up as a log line and degrades into the guard,
  never as a wrong capture.
- The **13 mounted cards** is one probe at one scroll offset — "a fraction of a
  page", not a constant.

## Open questions

1. ~~**Board URL path shape**~~ **Answered 2026-09-14** — `/board/<24-hex>`, with
   a `?source=…` query the recogniser ignores. Confirmed against the user's real
   board URL, which is the same board the captures came from.
2. ~~**`sourceId` scheme across cover → expanded**~~ **Settled and shipped** —
   keys unchanged; an expanded-children-only `knownNoteIndex`, gated on a
   mode-aware clean marker. See the T5 addendum. The `cover == image_list[0]`
   half is **answered: no** (T5a). What a `type: "video"` note's `image_list`
   holds is still open, and is the same capture T6 needs.
3. **Entry point** — boards only (recommended), or also "My saves"?
4. **Live Photos** — `image_list[].live_photo` exists. Defer.
5. ~~**Video ladder shape**~~ **Answered** (2026-09-14 capture) — four buckets
   `EF4`/`EF5`/`EF6`/`EF7`, each an array; `master_url` already unsigned, plus
   `backup_urls[]`. Only `EF4` populated in the one capture, so ordering between
   buckets remains untested. See T6.
