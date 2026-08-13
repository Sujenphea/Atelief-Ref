# 393 — Eleven keys of a hundred and eight

The Pinterest and Instagram fixtures were 41 and 29 days stale, and refreshing them was
the last red stage in the gate. The refresh found four live drifts, closed one documented
gap, proved another one unclosable, and turned up a fixture that could never have done the
job it was committed to do.

## The fixture that was checking itself

`instagram-saved.json` was the canary's Instagram input. It carries **11–13 keys per
media**. The live API sends **108–128**.

It was never a capture — it was a hand-reduction, and the reduction had quietly become the
thing under test. The canary's whole question is *does a response Instagram sent today
still parse*; run over that file it could only answer *does our own trimmed shape still
parse*, which it would keep answering "yes" to long after the real response moved.

So Instagram joins X on the two-fixture split (390): the composed fixture stays for the
unit tests, which pin it literally, and a new `instagram-saved-live.json` — 3 whole posts
lifted byte-for-byte out of a 21-post, 1.84 MB page — is what the canary runs. Same for
Pinterest boards. The pattern is now written down in the fixtures README rather than being
re-derived per platform.

## Staleness is per-fixture now

The top-level `capturedAt` covered the composed fixtures — files that are **deliberately
frozen**, because three test files assert their synthetic ids literally. A staleness window
over a file nobody will ever re-capture is a permanently red gate with no action behind it,
which is precisely what it had become. It is now descriptive and does not touch the exit
code; every fixture the canary actually runs carries its own date and window.

`ageInDays` also clamped at 0. `capturedAt` is a bare `YYYY-MM-DD` parsed as UTC midnight,
so a capture taken minutes earlier on a UTC+12 machine reported **"-1d ago"**.

## What the live probes found

**X-APP-VERSION drifted** — `1df0da9` → `194583e` in 42 days. Already scraped at runtime,
so nothing broke; the marker was simply wrong, and now records both values so the drift
rate is visible.

**The pws-handler gatekeeper is weaker than documented.** 019 §T10 established it as the
sole 403 trigger, which reconfirmed exactly: no header → 403, header → 200. What is new is
that it is **presence-checked, not route-matched** — `BoardsResource` returned 200 for both
`www/[username].js` and `www/[username]/[slug].js`. The comment in `PWS_HANDLERS` said a
handler-less resource "will 403 — acceptable while that path is deferred"; the deferral was
costing nothing but a one-line entry. `BoardsResource` now has one, written as its true
route rather than the value that merely happens to work.

**Instagram pagination is fully closed.** Both committed captures were terminal pages, so
`next_max_id` had only ever been inferred from IG convention and the paginating test
synthesized it. The saved feed has since grown past one page: the first fetch came back
`more_available: true` with `next_max_id` populated (120 opaque chars), and feeding it back
as `?max_id=` returned 200 with 21 more posts. Both halves of the round trip are now
measured.

**The Pinterest video-pin gap is not closable by capturing harder**, and the README now
says so instead of advising another search. A board does hold pins flagged `is_video: true`
— but `videos` is `null` on all of them, across four field sets (`react_grid_pin`,
`detailed`, `unauth_react_main_pin`, `partner_react_grid_pin`) *and* a direct `PinResource`
fetch by pin id. The payload is not reachable from this account, so `mapPinterestPin`'s
video branch stays unexercised by any real response. That is a finding, not a to-do.

## Sanitizing: three leaks, and the audit that was excusing one

The sweep is key-independent — value shape decides, not field name — because the X capture
leaked profile images through `avatar.image_url` when it was keyed on
`profile_image_url_https` (390). This round it leaked three more classes, each found by the
audit rather than by reading the rules:

- `814154277899006v` — an Instagram id with a **trailing letter**. The rule required
  all-digits.
- `C-rig7dCqdD`, `DRBfI5HAXpy`, `DXOORsHAf9U` — Instagram **post shortcodes**.
  `instagram.com/p/C-rig7dCqdD/` addresses a real post.
- `redacted@example.com`, plus gender and IP region — Pinterest's `BoardsResource` ships a
  `client_context` block describing the **requester**. The email fell through every
  predicate: too short to count as free text, and `@` is in none of the token or id
  character classes.

The shortcodes are the instructive one, because **the audit had excused them**. Its notion
of "structural survivor" was any short alphanumeric run with no whitespace — which is also
exactly what an opaque identifier looks like. It now requires a survivor to look like
something a *schema author* wrote (snake_case, UPPER_SNAKE, a capitalised word, a GraphQL
typename); mixing character classes is disqualifying. An audit whose escape hatch is shaped
like the thing it is hunting will pass while leaking, and it did.

Two rules are openly key-assisted rather than shape-derived, because shape genuinely cannot
reach them: display names and handles (`framer` is indistinguishable from an enum), and
viewer-context subtrees (`AUK` and `female` are shape-identical to enums). Both **collect**
by key and then **replace globally by value**, so they only ever add coverage. Hosts are
kept deliberately — the mappers branch on them — except for locale subdomains, so
`REDACTED` normalises to `www.pinterest.com`.

Final audit: **0 leaked** on both captures, every survivor a schema constant, read
individually.

## Result

| | before | after |
|---|---|---|
| gate | 6/7 — Extension red on fixture age | **7/7 green** |
| extension tests | 519 pass | **520 pass** |
| IG canary input | 11–13 keys/media (our reduction) | 108–128 keys/media (live) |
| IG `next_max_id` | inferred from convention | confirmed both directions |

## Files changed

- `extension/src/bulk-pinterest.js` — `BoardsResource` handler + the presence-vs-route note
- `extension/test/bulk-pinterest.test.js` — the unmapped-resource test repointed at a
  genuinely unmapped resource, plus a test that boards now send their handler
- `extension/scripts/drift-check.js` — live fixtures for `instagram`/`pinterest-boards`,
  top-level date made non-enforcing, undated markers reported, `ageInDays` clamped
- `extension/test/fixtures/instagram-saved-live.json`, `pinterest-boards-live.json` — new
- `extension/test/fixtures/drift-baseline.json` — dated pinterest + instagram markers
- `extension/test/fixtures/README.md` — composed-vs-live split, both gap entries rewritten

## Migration notes

None — fixture and canary changes only. One thing is **outstanding**: the Pinterest
board-feed live capture was taken (25 pins, cursor present) but could not be written to
disk, because Chrome set *Automatic downloads: Block* for pinterest.com partway through and
a real user gesture does not override it. `pinterest-board` still runs the composed fixture
until that lands; the marker records the pending state rather than implying coverage that
does not exist.
