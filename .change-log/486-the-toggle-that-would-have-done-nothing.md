# 486 — the toggle that would have done nothing

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T5b, the driving half of K3b — the part that
makes T5a's `parseNoteDetail` (485) have something to parse. The sweep now opens each
note through the SPA so the PAGE issues its own correctly signed
`POST /api/sns/web/v1/feed`, the MAIN-world hook forwards the response, and the note's
cover item is replaced by one item per `image_list[]` entry.

New: `extension/src/rednote-detail-client.js` — the counterpart to
`twitter-detail-client.js`, and the same shape: everything the feature needs from the
outside world in one file, with the pure shape logic next door. The one difference is
the whole of 098 D1. X's expander ASKS for a conversation; rednote cannot be asked (a
hand-signed request came back HTTP 461, and the signer's `XYW_` prefix does not even
match the `XYS_` the page sends), so this one never issues anything. It drives, and
listens.

Expansion is OFF by default. The cover pass is byte-for-byte the sweep it was.

## The mode trap — R14 as written would have made the toggle inert

R14 settled the known-set pre-check on `new Set([...knownSet].map((id) => id.split(":")[0]))`
— every known id, mapped to its note — armed after a clean prior sweep. That is right
about the cost model and wrong about the keys.

A cover item is keyed `<note_id>`. An expanded image is keyed `<note_id>:<index>`. Map
both to their note and the two become indistinguishable — so after the cover-only
DEFAULT sweep, `knownNotes` contains every note on the board. A user who then enables
the toggle and re-sweeps has every note-open skipped, expansion never runs, and the
sweep reports "complete, 0 new". The toggle silently does nothing on any board already
swept. That inverts the failure R14 exists to cure: R14's problem wastes budget loudly,
this one is silent.

Two changes, both cheap:

- **The clean marker records the sweep's MODE** beside `clean` — `{ clean, mode }`,
  `mode ∈ "cover" | "expansion"`. `armsNotePreCheck` arms the note-level pre-check only
  when the prior clean sweep was at least as rich as this one, which is exactly 098's
  table. A marker written by an older build has no `mode`: that reads as UNKNOWN, arms
  nothing, and leaves the `clean` rule Instagram's early-stop uses exactly as it was.
  The migration row is tested on Instagram itself, not in the abstract.
- **The index counts only expanded CHILDREN** (`knownNoteIndex`). A note is done when a
  previous sweep ingested one of its images, never merely because its cover exists. This
  is where the plan is extended rather than followed: the mode marker is a SWEEP-level
  precondition and this is the per-NOTE one, and the second buys two things the first
  cannot. A note that degraded, and a note the budget never reached, both still owe their
  images — under the literal formula both read as done, so **a board larger than the
  note-open budget could never be finished**: every re-sweep would spend its whole budget
  on the notes already done and never reach the tail. Under this one the next sweep spends
  it exactly where there is work.

The rejected alternative — keying the cover `<note_id>:0` to unify the namespace — stays
rejected, and T5a's evidence against it is unchanged: the detail note's `file_id`s are
`oss-sg/spectrum/<id>` while board covers are 15/37 bare `<id>`, 16/37 `spectrum/<id>`,
6/37 `oss-sg/notes_pre_post/<id>`. `cover == image_list[0]` is not a thing that is true.

## Four ways to lose a sweep silently, and what each costs

- **Correlation.** The hook's replay buffer can hand back an EARLIER note's detail — the
  hazard `matchesScope` guards on the board pass, which cannot be reused here because a
  detail response carries no `board_id`. A body is accepted only when
  `parseNoteDetail`'s `noteId` equals the note that was opened; anything else is
  discarded. Uncorrelated, note B's images save under note A's id: every id, url and
  count wrong, and nothing fails.
- **The return.** A note left open is not untidy, it is a truncated board: the grid sits
  under an overlay, the source's `scrollTo(0, scrollHeight)` pages nothing, and the sweep
  ends reporting a COMPLETE board with half its rows. The close is in a `finally`, the
  scroll position is saved and restored, and a close failure is logged rather than
  swallowed.
- **The refusal.** `expandItems` degrades gracefully on a throw — right for a note that
  would not open, wrong for a 461, because degrading past one keeps opening notes against
  a session rednote has already flagged. `intercept-source.js` gains
  `isFatalExpandFailure`, an injected predicate: when it says an expansion error is fatal
  the seam RE-RAISES it and the engine halts resumable. Omitted, nothing is fatal — which
  is exactly X's behaviour, unchanged.
- **The hang.** A note that never answers costs `NOTE_OPEN_TIMEOUT_MS` and no more. The
  wait is a polling loop over the injected `sleep` rather than a race against a timer,
  because a race against a test's instant `sleep` times out before the response it is
  waiting for can arrive.

## The budget, and `partial` as a real outcome

`NOTE_OPEN_BUDGET = 400` note-opens per sweep, paced at 1800 ms ± 1200 from
`PLATFORM_PACING.rednote.noteOpen`. Exhausting it is **not** a halt: every note past the
ceiling keeps its cover item, the cover pass finishes normally, and the sweep reports
itself PARTIAL. A later sweep picks up where it stopped, because those notes have no
expanded child for the pre-check to skip them by.

098 R7 put a first-class `partial` on the K3b ship list, and it is here: the expander's
stats ride out on `runBulkSweep`'s result, and `terminalMessage` says
`Done, partly expanded — N ingested (4 kept covers only)` where it used to say the same
`Done — N ingested.` as a sweep where every note gave up its photos.

Four outcomes are counted apart, and only two make a sweep partial:

| outcome | partial? |
| --- | --- |
| expanded | — |
| degraded (would not open, did not answer, unreadable) | **yes** |
| refused (video) | no — expansion was never possible; T6 lifts it |
| skipped (already expanded) | no |

The video row matters more than it looks: **a video note is never opened at all.**
`parseNoteDetail` refuses every one of them, and 30 of the 37 rows of the sampled board
are video — opening them would buy a guaranteed refusal at the price of 81 % of the
budget. Counting those refusals as shortfalls would also have made every sweep of that
board report partial for doing exactly what it was designed to do.

## The hook forwards two responses now, and a test that nearly did not notice

`rednote-hook.js` retypes `isNoteDetailRequest` beside `isBoardFeedRequest` and installs
their union; the controller routes by URL, so the board pages reach the source and a
detail body reaches the expander's waiter. Routing on the url rather than the payload is
load-bearing: fed to `parseBoardFeedPage`, a detail body has no `data.notes` and reads as
a REFUSAL, which would halt the sweep.

`hook-sync.test.js` compares the hook's retyped matcher against the parser's — and
reverting the install to the board matcher alone still passed every one of those
assertions. The constants were right; the wrong one was installed. So the test now also
RUNS the hook on a host it matches, with hook-core's installer stubbed, and asserts the
matcher that was actually handed over. Both domains are covered, and a lookalike host is
asserted not to install.

## Files changed

New: `extension/src/rednote-detail-client.js` (the waiter, the expander, the known-note
index, the live page driver), `extension/test/rednote-detail-client.test.js` (34).
Changed: `extension/src/intercept-source.js` (`isFatalExpandFailure`),
`extension/src/rednote-source.js` (threads `expandItems` + the predicate),
`extension/src/rednote-hook.js` (the note-detail matcher and the union it installs),
`extension/src/bulk-controller.js` (`expansion` collaborator, `sweepMode`,
`armsNotePreCheck`, the mode marker, detail routing in `buildRednoteDriver`),
`extension/src/bulk-messages.js` (`expandNotes` in `START_FIELDS`),
`extension/src/config.js` (the note-open knobs + `PLATFORM_PACING.rednote.noteOpen`),
`extension/src/popup-view.js` (`expansionOption`, `expansionShortfall`, a mode-aware
warning, a partial terminal message), `extension/src/popup.js` +
`extension/src/popup.html` (the toggle row), `extension/src/bulk-context.js` (the
comment that says why a toggle is not the resolver's business). Tests:
`bulk-rednote-integration.test.js` (+6), `bulk-controller.test.js` (+9),
`intercept-source.test.js` (+4), `popup-view.test.js` (+9), `hook-sync.test.js` (+3),
`platform-registry.test.js` (+2), `bulk-messages.test.js` / `bulk-dispatch.test.js` (the
new START field).

## Verification

`npm test` 756 → 823 total, 820 pass, 0 fail, 3 skipped (the 096 corpus and page-signal
fixtures, still not rednote's). Fifteen deliberate breakages, each failing the tests that
name it and no others: R14's literal `split(":")[0]`; opening video notes; dropping
correlation; closing the note only on success; not marking a refusal fatal; not enforcing
the budget; arming off a marker with no mode; dropping `mode` from the marker; re-emitting
the cover for a pre-check skip; installing the board matcher alone; dropping `expandNotes`
from `START_FIELDS`; correlating a refusal like any other body; removing the wait's
ceiling; a mode-blind risk gate; a partial sweep reporting a clean Done.

One of those is worth spelling out: removing the wait's ceiling HANGS the suite rather
than failing it, and a hanging suite reports nothing at all. So both expansion test
helpers now throw out of `sleep` after 50 polls, which turns "it never gave up" into a
legible failure instead of a stalled run.

`node scripts/drift-check.js` still prints `No drift` and still exits **2** on the
X/Instagram fixture-staleness arm, which pre-dates this change (098 Risks).

## Migration notes

- The clean marker's stored value grows from `{ clean }` to `{ clean, mode }`. An
  existing marker is read as mode-UNKNOWN: it arms no note-level pre-check and changes
  nothing else, so Instagram's `STOP_AFTER_CONSECUTIVE_SKIPS` behaves exactly as before.
  No stored value is rewritten; the next completed sweep writes the richer one.
- `expandNotes` joins the START message. A launcher that omits it gets the cover pass,
  which is the default and the previous behaviour.
- **A board already swept cover-only will re-ingest on its first expansion sweep** — the
  cover keeps `<note_id>` and the images arrive as `<note_id>:<index>`. That is 098's
  settled `sourceId` scheme, not a regression, and the popup copy says as much.

## Unverified, and needs a live capture

`createPageNoteDriver` is the only part of this that a capture could not answer. It
clicks the note's card link (`a[href*="<note_id>"]`) and closes with Escape, falling back
to `history.back()` when the SPA routed instead of overlaying. The card's link shape and
the overlay's close affordance are both inferred. Everything above them is injected and
tested; if either is wrong, every note-open degrades to its cover — loudly, in the
degradation count and the partial status line — and the cover pass is untouched. That is
why expansion is opt-in.
