# 500 — one dead token is not a flagged account

## Summary

[020](../.docs/feature-todo/020-capture-rednote.md) lists **`xsec_token` expiry** under
"Risks & edge cases": the token a note is opened with rides in the board-feed row, it is
short-lived, and a long sweep spends it long after it was minted. Nothing in the code
addressed it.

Investigating it found the hazard **half already answered and half pointing the wrong way**.

- **The checkpointed token is never spent.** `mapBoardNote` carries `xsecToken` as a local
  `BulkItem` field, and the expander threads it into `parseNoteDetail`, and *nothing ever
  puts it in a request*. The open is a **click on one of the page's own anchors**
  (`findLink`, 295c5a1), and the SPA signs and sends its own `POST /v1/feed` from whatever
  that anchor carries. So 020's prescription — "re-resolve the feed page rather than trusting
  checkpointed tokens" — is already structurally true, for a reason 020 could not have seen:
  there is no cheaper refresh than the one the driver already performs by accident of how it
  drives. That is now **pinned by a test**, because nothing reads `item.xsecToken` and so
  nothing would break if a future `findLink` started preferring the anchor that matches it;
  it would simply begin spending a stale credential, and would say so only on a live board.
- **A refusal on ONE note ended the whole sweep.** `detectRednoteDetailChallenge` →
  `RednoteChallengeError` → `isFatalExpandFailure` → a resumable halt of a 400-note sweep,
  on the **first** refused note-open. That is the right answer for a flagged session and the
  wrong one for a credential that expired, and the two cannot be told apart by their shape.

So the change is small and it is about the second thing: **a refusal is absorbed as one
note's degradation until it becomes a run, and a run halts the sweep as before.**

> **Index.** This entry is 500. 488–497 are taken and 498/499 are allocated; indices are
> never reused.

## What is actually known about how rednote refuses, and what is not

**Known, from live work.** The platform answered a hand-signed request with HTTP **461** and
a body of `{ success: true, code: 0, msg: "" }` — a rejection wearing a success envelope,
where every genuine response says `msg: "成功"` (098 D1). The hook forwards status-blind, so
the recogniser reads the body alone and its load-bearing test is the presence of a real
payload **array**, not the status fields. A note URL with **no** `xsec_token` answers **404**,
watched live on 2026-09-14 — which is what drove `findLink` to choose the tokenised anchor.

**Not known, and no offline test can establish it: what an EXPIRED token comes back as.** It
may be the 461 shape. It may be a `code != 0`. It may be the 404 route, in which case the SPA
may never issue a `/v1/feed` at all and the expander simply **times out** — which is already
handled, already counted `degraded`, and already reported. **No failure code has been
invented here**, and none is matched on. The code does not ask *which* refusal this is.

## The discriminator is the rhythm, not the body

A flagged session refuses **everything**. An expired credential is a fact about one note — or
about one feed page's cohort — with working notes on either side of it. That difference is
observable without knowing a single code:

- a refused note-open **below** a run degrades to the cover the board pass already captured,
  is counted, and the sweep carries on;
- `NOTE_DETAIL_REFUSAL_STREAK` (**3**) refusals **with no answered note between them** throw
  `RednoteDetailRefusalError` and halt the sweep resumable, exactly as the first refusal used
  to.

Only an **answer** breaks the run — and that is the arm that is easy to get backwards. A
**timeout** does not: a session being turned away can produce silence as readily as a refusal
body, and resetting on silence lets refuse/timeout alternate for ever. A note whose card was
never mounted does not either: it asked rednote nothing. Both are pinned, and both mutations
are killed by the same test.

Three, because the cost of being wrong is small in both directions and asymmetric in kind.
Too high and a genuinely flagged session gets a handful of extra opens — seconds of pacing,
not a treadmill. Too low and one dead credential ends a 400-note sweep, which is what it did.

## A fourth outcome, counted apart because it asks for something different

33632bd separated `unreachable` ("could not reach it") from `degraded` ("reached it, no
answer"), and T6c separated both from `refused` / `streamRefused`, which are **not**
shortfalls. `detailRefused` is none of those four:

| | what it means | is it `partial`? |
| --- | --- | --- |
| `unreachable` | no card on the page to open | yes — nothing the user can do |
| `degraded` | opened, and did not answer | yes |
| `refused` | a video note, video toggle off — never opened | **no**, by design |
| `streamRefused` | opened, and the ladder held no decodable stream | **no** — 020's typed skip |
| `detailRefused` | opened, and rednote **said no** | **yes**, *and re-sweeping is worth doing* |

It is the one that looks like the two typed skips and is not. An `ef*`-only ladder means the
content is genuinely not there in a form we can take; a refusal means the images are probably
still there and the credential that fetches them is minted fresh by the next sweep. So it is
in `partial` where those two are not, and the status line says so with the action attached:
`rednote refused 2 when opened — sweep again`.

`reasons` records the refusal's **kind** (`detail_refused:code_-1`, `detail_refused:no_feed_payload`,
…). That is deliberate and it is the point of the whole entry: the first live run that meets
an expired token will carry the answer in its own stats, where today there is nothing to read.
The kind comes off the wire, so the key is stripped to `[A-Za-z0-9_.-]` and bounded to 40
characters before it becomes a field in a result that ships out of the sweep.

**The token is in none of it.** Not in `reasons`, not in the counters, not in the halt message
the popup renders verbatim, not in the log line. Asserted three ways in two tests.

## How it composes with what landed before it

| | how it survives |
| --- | --- |
| **765654c's `finish()` ledger** | the refusal arm ends in `finish(noteId, [item])` like every other arm — the note is recorded settled, and a second sighting (a repeat row across a page boundary, a re-ask after a scroll) yields **nothing**. Cover **or** children, never both, never twice. Pinned; bypassing `finish` is a killed mutation |
| **765654c's streaming pass** | untouched. `rednote-source.js` is **not edited**: the tolerance lives inside `attemptNote`, so an absorbed refusal never reaches `expandPage`'s catch at all, and the run that does escalate carries `challenge: true` and routes through the existing `isFatalExpandFailure` arm with nothing rewired |
| **392dc8d's feed-start refusal** | untouched. It fires in `start()`, before anything is pulled from the seam; a refused sweep still opens **zero** notes |
| **d927083's in-page reset** | untouched. Nothing here re-runs it: a mid-sweep reset would throw away the scroll position and re-page the whole feed to chase an unobserved failure, which is the elaborate mechanism this deliberately does not build |
| **33632bd's counters** | `attempted`, `expanded`, `unreachable`, `degraded` unchanged in meaning. `partial` gains one term and loses none |
| **T6c** | `refused` / `streamRefused` still make no sweep partial; `resolveVideo` still decides whether a video note is opened; `<note_id>:v` still registers as an expanded child |
| **R14 / T5b** | unchanged, and still the first arm after the id — a known note is skipped before an open is spent, and before any of this is reachable |
| **`intercept-source.js`** | **not touched.** X's path is byte-identical; every X test passes unedited |

## What was considered and not built

- **Re-resolving the feed when a refusal appears.** The reset exists (d927083) and it works,
  but running it mid-sweep costs a navigation on a site with an active risk-control layer,
  blows away the walk's position, and would be built to repair a failure mode nobody has
  watched. 020's own prescription is already satisfied by the anchor click.
- **Matching a specific "token expired" code.** There is none to match. Inventing one would
  make the honest ambiguity invisible.
- **Making note-detail refusals never fatal**, on the argument that the board feed is the
  session-level canary and would refuse too. Attractive and unproven: the 461 was observed on
  a hand-signed request, not on a flagged session, and risk control could plausibly refuse the
  detail POST while the feed GET keeps working. Absorbing a run of them would be the exact
  "keeps hammering a flagged session" failure 098 R10 exists to prevent.

## Files changed

`extension/src/rednote-detail-client.js` (`RednoteDetailRefusalError`, `refusalReason`, the
`refusalStreak` state and the catch around `openAndRead`, the `detailRefused` counter, one
term in `partial`), `extension/src/config.js` (`NOTE_DETAIL_REFUSAL_STREAK`),
`extension/src/popup-view.js` (one branch in `expansionShortfall`),
`extension/src/bulk-controller.js` (comment only — the wiring is unchanged).

`extension/src/rednote-source.js`, `bulk-rednote.js`, `intercept-source.js` and every
twitter/pinterest/instagram file are **untouched**.

Tests: `rednote-detail-client` 75 → **82** (the isolated refusal, the run, what does and does
not break a run, the ledger through the new arm, the recorded kind, the bounded key, the token
never leaking, and the page-versus-item token), `bulk-rednote-integration` 53 → **54** (one
refused note through the real parser, seam, expander and engine; the run halting at the head
of a page and halfway down a walked one), `popup-view` 29 → **31**.

Two tests changed their claim rather than their wording, and both did so deliberately: "a
refused note-open THROWS a challenge" and "a 461 on a note reached only AFTER a step still
halts" asserted the halt on the **first** refusal, which is the behaviour being revised. Both
now assert the run, and the isolated case gained a test of its own next to each.

## Verification

`npm test` 994 → **1004 total, 1001 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine arms
pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm, which
pre-dates this change.

Thirteen deliberate breakages, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| no tolerance — the first refusal halts again | 11 |
| never escalate — a flagged session is degraded past for ever | 4 |
| the run never resets | 1 |
| the refusal arm bypasses the `finish()` ledger | 1 |
| a refusal is counted as an ordinary degradation | 5 |
| a refusal-only sweep reports `partial: false` | 2 |
| the refusal kind is collapsed away | 1 |
| the reason key is taken from the wire unbounded | 1 |
| the popup stops naming refusals | 2 |
| the open spends the item's checkpointed token, not the page's | 1 |
| a **timeout** resets the run | 1 |
| an **unreached card** resets the run | 1 |
| the refusal log carries the credential | 1 |

**One mutant survived the first round**, and it is the one worth naming: making a **timeout**
reset the run failed nothing. The run counter had tests for what breaks it and none for what
must not, so refuse/timeout alternating indefinitely was a behaviour with no test behind it. A
test was added covering both non-answers at once, and it now kills that mutation and the
unreached-card one beside it.

Every mutation was reverted before committing.

## Migration notes

- **A rednote expansion sweep no longer halts on a single refused note-open.** It keeps that
  note's cover, counts it, and carries on; three refusals in a row with no answered note
  between them halt it resumable, as the first one used to.
- **`result.expansion` gains `detailRefused`.** Every other field keeps its meaning.
  `partial` is true when it is non-zero — a sweep that would previously have **halted** on
  that refusal now **completes partial**, which is a status change for any caller reading
  `status` rather than `expansion`.
- **The halted sweep's message changed** for this cause. `RednoteFeedStartError`'s and
  `RednoteStallError`'s are untouched; the run's is new copy ending in something to do.
- **`createNoteExpander` gains `refusalStreakLimit`.** It defaults to the constant and, like
  the reach and feed-reset numbers and unlike `noteOpen`'s, it is **not** threaded through
  `PLATFORM_PACING`: it describes one SPA's one refusal behaviour, and a second access path
  would add nothing but somewhere for a typo to fall back to a default and look like it
  worked.
- Nothing in the sweep's UI, spec, messages or storage changed.

## Still unverified without a live run

- **What an expired `xsec_token` actually comes back as.** The whole reason this is a rhythm
  rule and not a code match. It may be a refusal body, it may be a 404 route that produces no
  `/v1/feed` at all (in which case it is a **timeout**, counted `degraded`, and this change
  never fires), and it may be something else. `reasons` will name it the first time it
  happens.
- **How long a token actually lives.** Unmeasured, and the reason the window matters at all:
  since 497 the scroll runs while notes are being opened, so feed pages queue up ahead of the
  notes they describe and a page-1 row can be minutes old when its note is clicked. Whether
  minutes is anywhere near the lifetime is unknown.
- **Whether an expired token comes in cohorts.** Tokens in one feed page are minted together,
  so one dying predicts the rest of that page — which would be a run, and would halt. That is
  the intended outcome (a resumable halt whose resume re-pages the feed from the top with
  fresh anchors) but it has never been observed, and if cohorts are real the streak may want
  to be larger so a page boundary is not mistaken for a flagged account.
- **Whether the page's anchors are ever fresher than the feed row.** They are rendered from
  the same response, so in principle they are exactly as old. A board left open for hours and
  swept without a reset — `sawFirstPage` true from the hook's replay buffer, so no reset runs
  — is the one path on which the DOM's token is genuinely stale, and it has not been tried.
- **Whether three is the right number.** Reasoned, not measured. Too low reads a token cohort
  as a flagged account; too high spends extra opens against one. Both failure modes are
  cheap, which is why the number was allowed to be reasoned.
