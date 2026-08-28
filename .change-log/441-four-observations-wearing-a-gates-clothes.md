# 441 — four observations wearing a gate's clothes

[096](../.docs/096-tier3-plan.md) § T0 names two bars for focal-post selection:

- the **design** bar, live: ≥27 of 30 unplanned popup openings, per platform, three
  platforms;
- the **regression** bar, forever: 100% of the captured corpus, in CI, from T3 onward.

The second one was implemented in `focal-post.test.js` and has been passing. It was passing
on **four observations, all x.com** — [438](438-a-list-of-opaque-ids.md) discarded the other
four as guesses, correctly, and the corpus has not been refilled since.

So CI showed a green corpus gate covering 4.4% of the intended corpus and one platform of
three. Pinterest — the platform where the rule is known to be shaky, winning by 15px and
46px on a 2-column grid against 274–350px elsewhere — contributes nothing.

## The test handled absence and had no idea about thinness

It already does the right thing when the fixture is missing: `t.skip` with a sentence
citing `drift-check.js`'s "⊘ NEVER VERIFIED" idiom, rather than passing quietly. There was
no equivalent for a corpus that exists and is too small to mean anything — and that is the
worse case, because a missing fixture reads as missing while a thin one reads as green.

This is `host-table.js`'s `FLOORS` applied to a fixture instead of a parser, for the reason
that file already gives:

> A regex that silently stops matching passes forever, so "we parsed something plausible"
> is itself an invariant.

Here the invariant is *we captured enough to be a gate*.

## Two tests, because they fail for different reasons

**The regression bar stays as it was** and still runs against whatever exists. A thin corpus
is worth defending — four x.com readings with 350px margins are real data, and this is the
half that will keep failing usefully once T3 lands.

**The coverage bar is new** and skips, with the tally, until every platform reaches 30:

```
ok 24 - T0 corpus: broad enough to be a regression gate # SKIP corpus is not yet a gate —
x.com 4/30  instagram.com 0/30  pinterest.com 0/30. 096 § T0 asks for 30 unplanned
observations per platform; still short on x.com (4), instagram.com (0), pinterest.com (0).
```

The tally also goes to stdout, because the count is the thing worth watching scroll past on
every run — it is what makes "we are at 4 of 90" impossible to mistake for "green".

It converts into a real gate by itself the moment T0 finishes. No edit, and nothing to
remember.

## Platforms are a table, not a `reading.host` group-by

Bucketing by the raw host would let a corpus that only ever saw `pinterest.com` report no
`pinterest` platform at all, and would let an unplanned host (a `www.` prefix, a ccTLD)
invent a fourth platform that then looks fully covered at n=1. So the three platforms are
named, with the hosts that count towards each, and anything else lands in a visible
`other:<host>` bucket.

Matching is `hostIs` — equal to the domain, or a subdomain of it — the same predicate
`focal-post.js`'s reader and `extractors/base.js` use, so a corpus bucket and a live
selector agree about what counts as pinterest.

## Files changed

- `extension/test/focal-post.test.js` — `PLATFORMS`, `platformOf`, `tally`,
  `REQUIRED_PER_PLATFORM`, and the new coverage test. The regression test is unchanged
  apart from sharing a `readCorpus` helper.

## Verification

`node --test test/focal-post.test.js` → 24 tests, 23 pass, 1 skip (the new coverage gate,
reporting `x.com 4/30  instagram.com 0/30  pinterest.com 0/30`).

Full suite: `node --test` → 608 tests, 607 pass, 1 skip, 0 fail.

## Migration notes

None. The skip is the intended state until T0's corpus is captured; a green run before then
would have been the bug.
