# 431 — numbers in, a post out

The first of [096](../.docs/096-tier3-plan.md) § T0: focal-post selection, built the way it
ships rather than as probe throwaway, so T0's day on a phone produces a fixture corpus
instead of three numbers.

## Summary

iOS Safari has no context menu, so tier 3 has no `info.srcUrl` telling the extension which
post the user means (094 § 2). 096 § D1's answer is that the phone viewport already does
that disambiguation. This is the code that reads it.

**Split the way `harvest.js` splits, not the way the plan's first draft said.** 096 T3
originally specified "a DOM fixture in, a post id out"; the review (096 § T3, decision 10A)
corrected it, because `harvestSignals()` returns *plain values* and `harvest.test.js` builds
them with a helper — no DOM anywhere. So:

- `readPostCandidates()` runs in the page, self-contained, and returns geometry:
  `{ url, host, matchedSelector, viewport, candidates: [{ index, postUrl, top, bottom, area,
  visibleArea }], containerCount, linklessCount }`. It classifies nothing.
- `chooseFocalPost(reading, { band, insetTop, insetBottom })` is pure — numbers in, one
  candidate out — and holds every rule.

**A candidate carries its post URL, not a parsed id.** Each extractor already derives its id
from a URL: `firstPostURL([context.linkUrl, …], isPost)` in `twitter.js:24`,
`instagram.js:21`, `pinterest.js:27`. Threading the chosen `postUrl` through as
`context.linkUrl` reuses that path unmodified, so no id regex is copied into a fourth place.

**The selectors are a fallback list and the reading names which one fired.** Three SPAs'
mobile DOM is exactly what this file cannot know from a desk, so `matchedSelector` is output
rather than assumption. `linklessCount` is tracked apart from `containerCount` because "the
selector matched 25 things and 3 had no permalink" and "the selector matched nothing" are
different failures — a distinction a live Pinterest feed immediately justified (25 pins,
22 linked).

**The band, not the centre line.** A line makes a post boundary landing on the centre a coin
flip and gives no way to say a call was close. A band scores every candidate on a continuum,
which is what lets `margin` and `runnerUp` exist — and 096 § T0's bar is that misses are
*adjacent* rather than wild, which is a judgment `margin` makes possible. Ties break
explicitly: greater visible area, then DOM order, so a reading always yields the same post.

`basis` is reported too: `centre-band` normally, `visible-area` when the band fell in a gap
between posts. A run of `visible-area` decisions in the corpus means the band is mistuned,
which is a thing to learn from data rather than from a bug report.

## Tests

15 cases, plain objects, no DOM stub — every edge 096 § T3 names: a post taller than the
viewport, two posts split exactly at centre (tie → visible area → DOM order, asserted
stable across runs), a sticky header via `insetTop`, a band landing in a gap, zero
candidates, everything off-screen, a zero-height viewport, insets that swallow the viewport,
a candidate merely *touching* the band edge, a scrolled-past post with a negative top, and
the band as a knob.

Plus `replayCorpus` — the harness for 096 § T0's second bar (100% of the captured corpus, in
CI, from T3 onward). It **skips with a sentence** while the fixture is absent rather than
passing quietly, which is `drift-check.js`'s "⊘ NEVER VERIFIED" discipline: a check that has
never seen a real observation proves nothing and should say so.

## Files changed

- `extension/src/safari/focal-post.js` — new. The reader and the chooser.
- `extension/test/focal-post.test.js` — new. 15 cases + the corpus replay harness.

## Migration notes

None — new code, nothing imports it yet. The popup that will (096 § T3) does not exist.

**The corpus format is now fixed**, and T0 must write it:
`{ reading, options?, expectedPostUrl }[]` at
`extension/test/fixtures/focal-post-observations.json`. `reading` is exactly what
`readPostCandidates()` returns, so the probe records its own output verbatim and a human
supplies `expectedPostUrl`. Deciding this before T0 rather than during T3 was the point —
the alternative was capturing ninety observations into a shape the tests could not consume.
