# 483 — the canary gets its first rednote page

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T4, the fixture half — the live board
capture of 2026-09-13 is sanitized into two committed fixtures, so the drift canary
stops reporting rednote as `⊘ NEVER VERIFIED` and the four live-capture tests in
`bulk-rednote.test.js` run on a fresh clone instead of skipping.

The sanitizer needed three changes to produce a fixture worth having. All three are
gaps the rednote capture found in the sweep, not rednote-shaped exceptions carved
into it.

## The first sanitized fixture would have proved the opposite

`toRednoteOriginal` returns its input **unchanged** unless the host ends in
`rednotecdn.com`, and it builds the unsigned original by dropping the first two
segments of `/<timestamp>/<signature>/<key>` and stripping the `!transform` suffix.
The sweep normalised the host to `sample2.example.com` and dropped the suffix — so
every cover in the fixture came out un-rewritable, and a canary run over it would
have gone green while exercising none of the rule it exists to guard.

`PLATFORM_HOST` now keeps rednote's hosts for the same stated reason it already kept
`i.pinimg.com` and the pbs/video twimg split — *the mappers branch on them* — and
`syntheticUrl` keeps a `!…` directive beside the file extension. Path depth was
already preserved, and here depth **is** the signing structure.

`bulk-rednote.test.js` now asserts that on the INPUT: every cover url is still on a
signed host, still has ≥ 3 path segments, still carries a `!`. A future re-capture
cannot quietly go vacuous.

## Two leaks the shape rules could not see

- **Display names.** `IDENTITY_KEY` matched `nickname` but not `nick_name`, the
  board feed's spelling (098 D6's trap, biting the sanitizer rather than the
  mapper). The capture carried `Neurobin`, `LEE`, `ruirui`, `snow` — names that are
  shape-identical to the schema constants the sweep deliberately shields, so no
  value rule could ever have reached them. Now collected under `nick_?name`.
- **Counts are not always numbers.** The `_count` rule ran on numbers only; rednote
  ships `interact_info` pre-formatted as strings (`"27.7K"`, `"5,123"`, `"795"`),
  and every one survived verbatim.

`audit-capture.js` went from **LEAKED: 28** to **LEAKED: 0**; the 58 survivors are
enums (`video`, `normal`, `WB_PRV`, `WB_DFT`) and short numerics. Re-running the
sweep over the three other platforms' raw captures reproduces their committed clean
files **byte for byte**, so the change is neutral outside rednote.

## What the capture then said

Verified by parsing the sanitized fixture: 37 notes → 37 items, all distinct, every
`mediaUrl` an unsigned `sns-i27.rednotecdn.com` url with no transform suffix, every
item keeping its signed fallback.

Two facts worth recording, because both contradict what was written down:

- **Board covers are not all single-segment keys.** 098 D2 has the board cover keyed
  `<id>` and only note-detail images keyed `oss-sg/spectrum/<id>`. The live board
  sends **15/37** `<id>`, **16/37** `spectrum/<id>`, **6/37**
  `oss-sg/notes_pre_post/<id>`. The drop-two rule is load-bearing on the cover pass
  too, and the last-segment rule T0 replaced would have 404'd on 22 of 37 rows.
- **The next cursor is literally the last row's `note_id`.** Not documented
  anywhere; it survives sanitization because the sweep memoizes by value.

## The origin host had been typed twice

`drift.js` hardcoded `sns-i27.rednotecdn.com` in the assertion that the extractor's
`ORIGIN_HOST` is where every `mediaUrl` lands — two files that must agree, with
nothing making them. `ORIGIN_HOST` is exported and imported; the check now cannot
outlive the rewrite it checks.

## Files changed

New: `test/fixtures/rednote-board-live.json` (the canary's capture, 37 notes),
`test/fixtures/rednote-board.json` (composed: 3 notes, a FIRST page — `has_more`
true and a populated cursor — so T4's integration test can page over it; its three
cover keys are one, two and three segments deep, every shape the live board sends).
Changed: `scripts/sanitize-capture.js` (hosts, `!` suffix, `nick_?name`, string
counts), `scripts/drift-check.js` (`FIXTURE.rednote`; `CAPTURE_HINT` emptied, kept),
`src/extractors/rednote.js` (export `ORIGIN_HOST`), `src/drift.js` (import it),
`test/bulk-rednote.test.js`, `test/drift.test.js`, `test/fixtures/README.md`,
`test/fixtures/drift-baseline.json`.

## Verification

`npm test` 714 → 715 total, 712 pass, 0 fail, 3 skipped (the 096 T0 corpus and
page-signal fixtures — none of them rednote's). `node scripts/drift-check.js` now
prints `✔ rednote board feed (committed fixture) — notes=37 items=37 hasMore=true`
and the awaiting-a-capture section is gone. It still exits **2**: the X and Instagram
fixtures are past their windows, which pre-dates this change and only a fresh
logged-in capture can clear (098 Risks).

## Migration notes

None. `CAPTURE_HINT` is deliberately left in place as an empty map with its comment
rewritten: it is what makes the NEXT parser start life visibly unverified, and
deleting it because it is momentarily empty would lose that.

One assertion changed meaning rather than value: the "no `xsec_token` in provenance"
test compared the token against the serialized page as a **substring**, which was
safe on the raw capture but not on synthetic sequential ids — `SAMPLE_TOKEN_3` is a
substring of `SAMPLE_TOKEN_30`. It now compares provenance leaf values, which is the
property it always meant.
