# 495 — thirteen cards of a hundred and sixteen

## Summary

The rednote board grid is **virtualised**. A console probe on a live board on 2026-09-14
counted the distinct note cards in the DOM and found **13**, while one feed page carries
**37–38** notes and the board holds **116**.

`createPageNoteDriver.findLink` opens a note by finding its card's anchor in the document. A
card that is not mounted has no anchor, so `openNote` returns false, and expansion — which
runs over a whole page of 37–38 notes *after* that page has arrived, by which time the grid
has scrolled on — degrades most of them. **K3b expansion therefore reaches roughly a tenth of
a real board.** It works for the handful currently on screen, which is exactly what "opening
and closing notes is working" looked like.

This entry does **not fix that**. It makes it **visible**. The fix is **2A** — interleave the
opening with the scrolling so a note is opened while its card is still mounted — and it is a
redesign of *when* expansion runs, scheduled separately. What was wrong here and is fixed
here is that expansion **misreported its own coverage**: a sweep that reached 13 of 116
produced the same stats shape and the same terminal sentence as one that reached all of them.

> **Index.** This entry is 495. 488–494 are taken; indices are never reused.

## The two failures that were one number

`no_note_card` — the card was not in the DOM — landed in `degraded` alongside a timeout, an
unparsable body and a throw. They are not the same thing and they do not ask for the same
fix:

| | what happened | what fixes it |
| --- | --- | --- |
| `unreachable` **(new)** | the note's card was never on the page, so no note-open ever happened | nothing the user can do — 2A |
| `degraded` | the note **was** opened and gave nothing back (a timeout, a bad parse) | a longer timeout, a better parse |
| `refused` | a video note the sweep was told not to open | tick *Download full video* |
| `streamRefused` | a video note opened, whose ladder held no decodable stream | nothing — 020's typed skip |

So `unreachable` is now its own counter, and the split is stated in one sentence a reader can
apply: **could not reach it** versus **reached it and it did not answer**.

## Coverage, because the failures alone do not read

`4 kept covers only` is the identical sentence whether the sweep expanded four hundred notes
or none — and on a virtualised board it is none. `attempted` is the denominator that makes
the rest readable, and the stats now carry **`expanded N of M`**.

`attempted` counts every note the pass **set out to** expand: a candidate it opened, one it
could not reach, one the budget never got to, one whose id it could not read. It deliberately
excludes the two the sweep *chose* not to open — a note a previous sweep already expanded
(`skippedKnown`) and a video note with the video toggle off (`refused`). Putting those in the
denominator would report a coverage gap on an 81 %-video board for doing exactly what it was
told to do, which is the failure T5b's `refused`/`degraded` split exists to prevent.

## Where a user meets it

Through `terminalMessage`, the mechanism 493 established for runtime outcomes — no second
string table, no parallel stats object. `expansionShortfall` gains the ratio and the new
clause, and the measured live case now reads:

```
Done, partly expanded — 77 ingested (expanded 13 of 116; 103 had no card on the page
to open — the board only renders what is on screen).
```

The clause says **why**, because the user can do nothing about it and re-sweeping will not
help — unlike the budget clause beside it, which is the one reason with an action attached
(*sweep again for the rest*). A sweep that attempted nothing states **no ratio**: "expanded 0
of 0" is a sentence about nothing.

## `partial` — checked, and kept

Today's rule is `degraded > 0 || budgetExhausted`. Asked of a board where nearly every note
degraded on `no_note_card`: it answered **true**, and that was honest. The dishonesty was
never in `partial`'s truth value — it was in the *magnitude*, which `partial` cannot carry
and `expanded N of M` now does.

So the rule is not changed in meaning; it is **extended to keep the meaning it had**. Pulling
`unreachable` out of `degraded` would otherwise have made a board where *every* note was
unreachable report `degraded: 0, partial: false` — the worst possible expansion wearing the
sentence of a complete one, a new bug manufactured by the repair. `partial` is now
`degraded > 0 || unreachable > 0 || budgetExhausted`, which is the same truth value as before
this commit for every input.

**T6c is not reversed.** A video note refused unopened (`refused`) and one opened to an empty
ladder (`streamRefused`) still make no sweep partial, and neither is in `attempted`'s
exclusions by accident: `refused` is excluded, so it cannot depress the ratio either. The one
interaction worth naming is `streamRefused` — those notes **are** attempted and are not
`expanded`, so a board of video notes with empty ladders and one unreachable card reads
`expanded 0 of 31`. That is literally true (the sweep set out to expand 31 and produced no
expansion from any), `reasons.empty_ladder` names which nothing it was, and the ratio is shown
only when something else has already made the sweep partial — never on its own.

## Where the cause is written down

In `findLink`'s own doc comment, which is where the next reader — and 2A — meets the
`return null` that starts all of this: the probe, the three numbers, why no selector can fix
it, and that the fix is a redesign of the source's page loop rather than of that function.
Shorter notes sit on the `unreachable` counter and on `attempted`, and on the controller's
result comment where the stats ride out.

## Files changed

`extension/src/rednote-detail-client.js` — `attempted` and `unreachable` counters, the
`UNREACHED` sentinel that lets `openAndRead` return three outcomes instead of two, `partial`
extended, and the measurement recorded on `findLink`.
`extension/src/popup-view.js` — `expansionShortfall` gains the ratio and the unreachable
clause.
`extension/src/bulk-controller.js` — comment only; the stats spread through unchanged.

`extension/src/intercept-source.js` is **untouched**. Nothing about *when* or *how* a note is
opened changed: `findLink`'s strategy, the budget, the pacing, the correlation, the close and
the video arms are all exactly as 494 left them. **3B** (per-page expansion batching) stays
deferred pending 2A.

Tests: `rednote-detail-client` (+5, the split and the coverage through the real expander),
`popup-view` (+4, the sentence a user actually reads).

## Verification

`npm test` 947 → **956 total, 953 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine arms
pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm, which
pre-dates this change.

Eleven deliberate breakages, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| `UNREACHED` counted as `degraded` again (the split undone) | 2 |
| `partial` forgets `unreachable` | 2 — including the pre-existing no-card test |
| `attempted` never counted for a candidate | 3 |
| `attempted` counts notes the sweep deliberately passed over | 3 |
| a note the budget never reached drops out of the coverage | 3 |
| `attempted` not counted for a note with no id | 1 |
| the coverage ratio dropped from the status line | 3 |
| the ratio stated even when nothing was attempted | 1 |
| unreachable notes reported as "kept covers only" | 3 |
| the unreachable clause stops saying why | 1 |
| the unreachable clause dropped entirely | 3 |

No mutant survived, and no mutation failed a test outside the two files above. Every mutation
was reverted before committing.

## Migration notes

- **A rednote expansion sweep of a real board now reports a shortfall where it used to report
  a success.** Nothing about what it captures changed — the same notes expand and the same
  notes keep their covers. The terminal line, and `result.expansion`, now say how many.
- **`result.expansion` gains two fields**, `attempted` and `unreachable`. `degraded` is
  **narrower** than it was: unmounted cards have moved out of it into `unreachable`, and any
  caller adding them up wants `degraded + unreachable`. `reasons.no_note_card` is unchanged
  and still counts the same events.
- `partial` is unchanged for every input.
- A cover-only sweep still reports `expansion: null` and none of this appears.

## Still unverified without another live run

- **The 13 is one probe of one board at one scroll offset.** How many cards mount will vary
  with viewport height, zoom and where the grid happens to be; what has been established is
  that it is a fraction of a page, not that it is thirteen.
- **What the ratio actually reads on a full sweep of that 116-note board.** Expected around
  `expanded 13 of 116` per the probe, but the number this commit exists to surface has not
  yet been read off a real run — which is also the check that the counters are wired to what
  actually happens rather than to what the tests simulate.
- **Whether any note is unreachable for a reason other than virtualisation.** A card that is
  mounted but whose anchor the SPA renders differently would land in `unreachable` too, and
  would be a different bug wearing this one's counter. Nothing observed suggests it; nothing
  rules it out.
