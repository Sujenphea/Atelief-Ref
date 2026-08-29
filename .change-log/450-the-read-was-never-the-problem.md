# 450 — the read was never the problem

`CollectionFeed.load` reads every row of a collection into `[CollectionItemDetail]` and holds
it for as long as the screen is on the navigation stack. Unsorted is where every share lands,
nothing auto-files it, and it is the screen the phone opens on — so it is both the collection
most likely to grow without bound and the one on the launch path.

093 § 3's laziness gate is cited in 092 as run and passed: 2,010 items, **8 tile bodies** at
launch. That proves the VIEW is lazy. It says nothing about the array behind it, and the two
had been quietly conflated.

The review's options were: page the read now, measure first, or do nothing. Paging round-robin
masonry is genuinely hard — `MasonryColumns` decomposes as `stride(from: c, to: n, by: C)`, so
column membership depends on the total, and a growing `n` reshuffles columns as pages arrive.
That is 3–5 days against a problem nobody had measured.

## Measured

Three tests in `BrowseScaleTests`, seeding through the real `AppServices.ingest` funnel:

| | |
|---|---:|
| read 5,000 items | **0.293s** |
| one read / two concurrent | 0.286s / **0.327s** |
| 5,000 thumbnail path resolutions | **0.088s** |

**The read is linear and fast.** Two concurrent reads of a 5,000-item collection cost 1.14×
one, not 2× — the pool absorbs the second. Extrapolating, 20,000 items is around 1.2s on this
machine and a few seconds on a phone, off the main actor, on a library four times larger than
any that exists here.

So: **paging is not needed, and now that is a finding rather than an assumption.** 14C — do
nothing — is the right answer, and the evidence is in the suite rather than in a changelog
sentence nobody can re-run.

## The third test is the one that will earn its keep

`gridThumbnailURL(for:)` documents a promise:

> Not stat'ed. A grid scrolls past hundreds of these and a missing thumbnail is something the
> image loader finds out anyway.

That is a claim about complexity on the scroll path, and nothing checked it. 5,000 resolutions
against a library with **no thumbnail files at all** take 0.088s. A `fileExists` sneaking in
would break no test and no behaviour — it would only make scrolling worse on exactly the
libraries where scrolling matters, which is the kind of regression that arrives without a
symptom anyone can name.

## Why 5,000 and not the 20,000 the review asked for

Seeding goes through the real ingest funnel, one transaction per item, because a hand-built
table would measure a hand-built table. 20,000 of those is minutes on every CI run forever.
5,000 is four times the largest library here, and the curve is the same one: if the read is
linear at 5,000 it is linear at 20,000, and if it is not, this is where that shows first.

The suite costs ~15s, up from ~0.2s. That is the price of measuring the real path, and it is
paid once per CI run.

## The bounds are ceilings, not targets

A wall-clock assertion on a CI runner of unknown load is honest only if it is generous enough
that a slow afternoon cannot trip it and a change of ALGORITHM must. The budgets sit roughly
an order of magnitude above observed: 5s for a read that takes 0.29s, `4× + 0.5s` for a
concurrency comparison, 1s for resolutions that take 0.09s. What they catch is an N+1
appearing in the read, a sort moving out of SQL into Swift, or a stat per tile.

## Files changed

- `AtelierBrowse/Tests/AtelierBrowseTests/BrowseScaleTests.swift` — new, 3 tests.

No production code changed, and that is the outcome: 096 review 14A asked whether the feed
needed paging, and the answer is no.

## Verification

`swift test` in AtelierBrowse → **43 tests in 5 suites**, all passing (was 40). The three
measurements print on every run, because a number nobody reads is a number nobody notices
moving.

## Migration notes

None.
