# 484 — the parts had never met

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T4, the integration half —
`extension/test/bulk-rednote-integration.test.js`, 14 tests that drive the real
parser through the real push→pull seam into the real engine. Every piece under it
was already unit-tested alone (`bulk-rednote.test.js` 28, `intercept-source.test.js`
the seam generically); nothing asserted that they COMPOSE, and two of rednote's
load-bearing properties are invisible to a per-page test by construction.

The pages are the committed captures where one exists, and composed from live ROWS
where a second page is needed — rednote's next `cursor` is literally the last row's
`note_id` (483), so a composed page threads exactly as the real one did.

## What only the composition can show

- **`cursor: ""` does not loop** (098 R12). A per-page test can assert
  `endOfFeed === true`; only a sweep can watch the alternative — three further pages
  are armed behind a `has_more: true, cursor: ""` page and must never be swept up.
  Removing `|| !cursor` from the parser fails this test and nothing else.
- **A 461 halts, and halts RESUMABLE.** The parser returns the refusal as `error`,
  the seam re-raises it on the pull side, the engine halts. The board must not close
  `complete` with half its rows, and the checkpoint must survive — with a `cursor` of
  `null`, because an intercept source declares `resumable: "scroll"` and cannot seek
  to one (098 R1). This is the fatal route's first execution outside its own test.
- **`has_more: false` and the live empty terminator both stop the sweep**, each with
  an unreached page armed behind it, so "it stopped" is proved by an item that must
  not exist rather than by a count.
- **An EMPTY page with `has_more: true` is NOT the end** — the mirror case, and the
  reason `endOfFeed` cannot simply mean "no rows".
- **Dedup-skip on re-sweep**, which is the only thing that makes a scroll-driven
  resume affordable: the first page already known costs skips and no relay at all.
  A note repeated across two pages is likewise relayed once.
- **Scope** — another board's replayed page is ignored, and so is another board's
  REFUSAL, which would otherwise let one stale buffer entry halt every later sweep
  in the tab.

Each of these was checked by mutation: eight deliberate breakages in
`bulk-rednote.js` and `bulk-engine.js` (drop the empty-cursor guard, blind the
challenge detector, accept every scope, skip the original-URL rewrite, ignore
`has_more`, enqueue coverless rows, ignore `resumable: "scroll"`, ignore the
known-set) each fail the tests that name them and no others.

## One behaviour pinned rather than expected

**A refusal pre-empts pages already queued behind it.** When the hook's replay
buffer hands over page 1 and the refusal that followed it before the sweep pulls
anything, `pendingError` is checked at the TOP of each iteration — so it wins over a
non-empty queue and page 1's items are never yielded. That is the opposite of the
intuitive reading, and it is the safer half of the trade: halting on sight loses
nothing, because the sweep halts resumable and a resume re-walks those pages with
dedup-skip making the overlap idempotent, whereas draining a backlog of ~37 relays
against an account rednote has just flagged is not recoverable the same way.
`intercept-source.test.js` pins the same rule on fakes; this pins it on real pages,
where the cost of the discarded queue is visible.

## Files changed

New: `extension/test/bulk-rednote-integration.test.js` (14 tests). Nothing in `src/`
was touched — every property asserted here already held.

## Verification

`npm test` 715 → 729 total, 726 pass, 0 fail, 3 skipped (the 096 corpus and
page-signal fixtures, unchanged and not rednote's). `node scripts/drift-check.js`
still prints `No drift` and still exits **2** on the X/Instagram fixture-staleness
arm, which pre-dates this change (098 Risks).

## Migration notes

None — test-only.
