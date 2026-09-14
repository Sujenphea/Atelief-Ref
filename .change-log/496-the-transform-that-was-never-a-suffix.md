# 496 — the transform that was never a suffix

## Summary

`toRednoteOriginal` strips rednote's rendering directive when it rides on the **path**
(`!nd_dft_wlteh_webp_3`) and passed it straight through when it rides in the **query**
(`?imageView2/2/w/540/format/jpg/q/75`). A url carrying the query form was returned
unchanged and stored as the capture — a thumbnail.

Found by **reading a live `board/info` response**, not by a test. Every cover url in it
carries the query form. Measured with real requests on 2026-09-14; both bare forms return
**200 `image/jpeg`**:

| url | with the directive | bare | loss |
| --- | --- | --- | --- |
| `sns-i11…/1040g2sg324inl1490mgg4a95jgo5csvndo95q4o` | 35,900 B | **1,266,867 B** | **35×** |
| `sns-i11…/spectrum/1040g34o324ieufpe0m105pj9n4ngu8ggrsklugg` | 18,241 B | **1,038,214 B** | **57×** |
| `sns-avatar-qc…/avatar/1040g2jo3240vjp0jn4005pj9n4ngu8ggrcvp4mo` | 1,013 B | **86,223 B** | **85×** |

For scale: T0 ([098](../.docs/098-rednote-sweep-plan.md) D2, changelog 467/468) was a **5×**
loss and was treated as a shipped bug worth its own phase.

**Not latent.** `harvest.js` collects every `<img>` src on the page and `rednote.extract`
takes `largestMedia(harvest, CDN)`, where `CDN` matches any `rednotecdn.com` url. One
"Save to Atelier" on a page rendering these covers stored the 18 KB render with the 1 MB
original one query-string away. `mediaUrlFallback` is what kept it quiet: the thumbnail
always loads, so nothing ever errored — the same mechanism that hid 467.

> **Index.** This entry is 496. 488–495 are taken; indices are never reused.

## The rule is "remove transforms", never "remove the query"

487 established that rednote has **unsigned-in-path** families whose authorization rides in
the query — `/subtitle/1/110/1/<id>_12.srt?sign=…&t=…`. A blanket query drop breaks those,
and it is not hypothetical: **4 of the 138 distinct CDN urls in the corpus carry a query**
and **all four are `?sign=`** (three subtitles, and one translate render that carries a `!`
suffix *and* a `?sign=` query at once). Dropping the query string would have changed the
answer on four urls that work today, every one of them for the worse.

So the query is filtered **one `&`-separated component at a time**, and a component is
removed only when it is a **named transform directive**:

```
/^image(View2?|Mogr2)\/[^=]*$/i
```

`imageView2` is the only spelling live traffic shows; `imageView` and `imageMogr2` are its
two siblings in the same documented resize family. Everything else is left alone. `sign=`
and `t=` are kept because neither begins with a directive name — that half of the predicate
is the one the tests can see, and both directions are pinned. The `[^=]*$` clause says a
directive is a bare path rather than a key/value pair; it is belt-and-braces and is
**recorded below as a deliberate surviving mutant** rather than defended with an invented
case.

The predicate fails the same direction `hasSigningPrefix` does. An unrecognised directive is
left in place, which costs a thumbnail; removing something load-bearing costs the whole url.

## De-transformed in place, NOT rehosted

A query-transformed url keeps the host it arrived on. That is a decision, and the
measurement settles it rather than the principle:

```
https://sns-avatar-qc.rednotecdn.com/avatar/<key>   →  200, 86,223 B
http://sns-i27.rednotecdn.com/avatar/<key>          →  404
```

Rehosting is only sound where the path is known to be a **bare object key**, and the only
thing that proves that is the signing prefix — which these urls (1–2 segments) do not have.
Removing the directive in place already recovers the full-resolution original on the
original host, so rehosting would buy nothing and risk a 404. 487's migration note already
reads the invariant as "lands on `ORIGIN_HOST` *if it was signed*"; this keeps it that way.

The query directive does come off **wherever it rides**, including on `ORIGIN_HOST` itself
and on a signed path — it is a request for a rendering and nothing else in the url depends
on it. On the signed branch that is a no-op in practice, since the rewrite already rebuilt
the url from the key alone.

## What the corpus says

Re-run over the same three live captures 487 validated against
(`rednote-board-page2.json`, `rednote-note-02.json`, `rednote-note-video.json`), 235 CDN url
occurrences / **138 distinct**:

| | distinct |
| --- | --- |
| rewritten onto `ORIGIN_HOST` (signing prefix stripped) | 94 |
| returned untouched | 44 |
| **answers changed by this commit** | **0** |

Every one of the 138 answers is **byte-for-byte identical** to the pre-496 answer, the
rewrite is idempotent on all 138, and where the response publishes its own `file_id` the
stripped key still equals it — 20/20 distinct urls (487 counted the same agreement at
occurrence level and recorded 40/40). No capture in `resources/` is a `board/info` response,
which is exactly why the corpus could not have found this.

## The canary asked about one spelling of two

`checkRednoteBoard` and `checkRednoteNoteDetail` tested `mediaUrl.includes("!")` — a
transform surviving in the query is the same class of failure and was unasserted. Both now
ask `hasTransform`, **exported from `rednote.js`**, so the canary and the rewrite cannot
disagree about what a directive is. That is the same construction `ORIGIN_HOST` already uses
and the reason it is exported: a hardcoded copy in `drift.js` goes on passing after this
module moves.

The drift the check can actually catch is a rewrite that never **reaches** the url — 483's
scenario, where a moved CDN host switches `toRednoteOriginal` off wholesale and it hands the
thumbnail back untouched. A *correct* rewrite cannot emit a surviving directive on a url it
recognises, so that half is pinned on the predicate itself in `extractors.test.js`.

## The sanitizer, for the fifth time

`syntheticUrl` rebuilt every url as `protocol//host/segments` and therefore dropped the
**whole query string**. That is right for everything that normally rides in one — `?sign=`
and `xsec_token` are credentials — and wrong for the one thing in a query that is not
identity at all. A `board/info` fixture sanitized by it would have proved the opposite of
what the canary asks, after 483 (the CDN host), 485 (the `!` suffix), 487 (the signing
prefix) and 488 (the unsigned `/stream/` route).

A query component that is a transform directive is now kept **verbatim**; every other
component is still dropped. The predicate is `isTransformDirective`, **imported** from
`src/extractors/rednote.js` rather than respelled — a private copy there is precisely how
the fixture and the rewrite come to disagree, which is the entire content of the four
entries above.

Re-sanitizing **all 15 files in `resources/`** reproduces what the pre-496 sweep produced,
byte for byte: no capture there carries a query transform yet. This is coverage for the next
`board/info` capture, not a rewrite of the current fixtures. **No fixture was added** — the
live `board/info` response is not in `resources/`, and inventing one and presenting it as
captured is the thing the fixture rules exist to prevent.

## Files changed

`extension/src/extractors/rednote.js` — `TRANSFORM_QUERY`, `isTransformDirective`,
`withoutTransformQuery`, `hasTransform`, the de-transform in `toRednoteOriginal`, and the
doc comment (the two spellings, the measurements, and why the host is kept).
`extension/src/drift.js` — both rednote transform assertions now call `hasTransform`.
`extension/scripts/sanitize-capture.js` — a transform directive survives the query sweep.
`extension/test/extractors.test.js` (+4), `extension/test/drift.test.js` (+1),
`extension/test/fixtures/README.md`.

`ORIGIN_HOST` and `rednoteNoteId` are untouched and nothing was copied out of them.
`PageExtractor.swift` mirrors `toOrigName`/`toOriginals` only — there is no Swift copy of
the rednote rewrite to carry this to, and `ShareCapture.swift`'s rednote entry is a
host → platform row that is unaffected.

## Verification

`npm test` 956 → **961 total, 958 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine
arms pass, and it still exits **2** on the X/Instagram/Pinterest fixture-staleness arm,
which pre-dates this change.

Eight deliberate breakages, each failing the tests that name it and no others:

| mutation | fails |
| --- | --- |
| no query de-transform at all (**the shipped defect**) | 3 |
| blanket query drop instead of directive removal | 3 — including 487's own `?sign=` subtitle test |
| the directive NAME anchor dropped | 1 |
| `hasTransform` blind to the query form | 2 |
| `hasTransform` blind to the `!` suffix | 1 |
| a de-transformed url also rehosted onto `ORIGIN_HOST` | 2 |
| the canary back to `.includes("!")` | 1 |
| the `[^=]*$` half of the directive shape dropped | **survived — recorded, not chased** |

The survivor is deliberate: with components judged one at a time and anchored on a directive
name, no live shape reaches the `=` clause, and pinning it would mean writing a test around
an invented url. It is kept because it costs nothing and states the shape the name list
stands in for — the same treatment 487 gave its two survivors.

No mutation failed a test outside the files above, and every one was reverted before
committing. `sanitize-capture.js` still has no exports and no test; the trip-wire remains
the input-shape assertions in `bulk-rednote.test.js`, plus the imported predicate, which now
makes a silent divergence from the rewrite impossible rather than merely detectable.

## Migration notes

- **A rednote CDN url carrying `?imageView2/…` now comes back de-transformed**, on the host
  it arrived on. Callers that treated `toRednoteOriginal` as a no-op for unsigned urls get a
  different string for this one family — the same string minus the directive.
- **No previously-correct answer changed**: all 138 distinct corpus urls, `?sign=` included,
  rewrite exactly as before.
- **`drift.js`'s rednote transform problem is reworded** — `a transform directive survived
  the rewrite (…)` rather than `a transform suffix survived the rewrite`. It is a canary
  message, not an API.
- **`sanitize-capture.js` now imports from `src/extractors/rednote.js`.** It was previously
  free-standing apart from `node:fs`.
- If a `board/info` capture is ever committed as a fixture, `checkRednoteBoard`'s
  `onOriginHost` rule will need reading as "signed ⇒ `ORIGIN_HOST`" — those covers are
  unsigned and legitimately stay on `sns-i11`. No such fixture exists today and the rule is
  correct for every one that does.

## Still unverified

- **Whether note pages render `?imageView2` srcs in the DOM.** The note-detail JSON uses `!`
  suffixes on signed urls, but the rendered `<img>` may differ, and that would widen the
  blast radius from board pages to every note. Attempted live on 2026-09-14 and not
  answerable anonymously: `www.rednote.com/explore/<id>` 302s and `xiaohongshu.com` answers
  `error_code=300031` on a signed-out fetch. It needs a logged-in DOM probe.
- **Whether the `!` suffix should also come off an UNSIGNED path.** It does not today, on
  either side of this change. The one live example is the translate render
  `…/cloudrender-translate/<uuid>.jpg!1080jpg?ap=…&sign=…`, measured 86,943 B with the
  suffix against 132,665 B bare — a 1.5× loss on a url nothing ingests. Left alone: it is a
  different family with a different question (that url's `?sign=` covers a path the suffix is
  part of), and no swept url reaches it.
- **Whether `imageView` and `imageMogr2` ever appear.** They are included as the same
  documented resize family; only `imageView2` has been seen.
- **The live `board/info` response itself is not committed.** The three urls in the new tests
  are verbatim from it and were each re-fetched for this entry's byte counts, but nothing in
  `resources/` can re-derive them.
