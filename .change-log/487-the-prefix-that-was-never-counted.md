# 487 — the prefix that was never counted

## Summary

`toRednoteOriginal` decided whether to strip a signing prefix by asking **"are there
≥ 3 path segments"**. That is not the invariant. It is the same family of fault as
[098](../.docs/098-rednote-sweep-plan.md) D2 (changelog 467/468) one level up: 467 got
the KEY right — everything after the first two segments — and left the question of
*which URLs have a signing prefix at all* answered by a count.

rednote's video streams and subtitles are served **already unsigned**, with real path
where the prefix would sit:

```
in : http://sns-v11.rednotecdn.com/stream/1/110/258/01ea96475c7839f001037001a05b180502_258.mp4
out: http://sns-i27.rednotecdn.com/110/258/01ea96475c7839f001037001a05b180502_258.mp4
```

Verified live 2026-09-14 with ranged GETs: the input is **206 `video/mp4`**, the rewrite
is **404**. A poster from the same note rewrites correctly — 206 `image/jpeg`, matching
the API's own `file_id` — so the rule is right for images and wrong for streams.
`stream/1` is not signing material; it is path.

The guard is now the SHAPE of the first two segments — 10–14 digits, then a 32-char hex
digest, with at least one segment left over to be the key. An already-unsigned URL is
returned untouched.

## Shape, not host, and not count

Host family would have worked on today's corpus (`sns-web-i10` serves every signed URL
in it, `sns-v11`/`sns-v27`/`sns-subtitle-s10` the unsigned ones) and is the wrong rule
for the same reason an enumerated CDN list is always the wrong rule: one new shard and it
is silently wrong. Host stays corroboration, asserted in tests, not a condition of the
rewrite.

The two failure directions are not symmetric, which is why the shape test is strict
rather than generous. Declining to strip returns the signed URL — it still loads, just
resized. Stripping what is not a signature returns a URL that does not exist. So the
predicate fails **closed**: an unrecognised prefix is left alone.

## What the corpus says

Measured over all three live captures (`rednote-board-page2.json` 37 board rows,
`rednote-note-02.json` 9 images, `rednote-note-video.json` the video note), 235 CDN URL
occurrences / **138 distinct**:

| | distinct |
| --- | --- |
| stripped (all `sns-web-i10`) | 94 |
| returned untouched | 44 — 38 avatars, 3 subtitles, 2 streams, 1 translate render |
| **answers changed by this commit** | **5** — the 2 stream URLs and the 3 subtitle URLs |

No image URL changes. 098's recorded **184** is the occurrence-level count over the two
2026-09-13 captures and it reproduces exactly — 148 board + 36 detail — every one of them
still stripped, plus the 4 occurrences of the video note's poster.

Where the API publishes its own `file_id` (40 URLs across the two note captures) the
stripped key equals it **40/40**. Board covers carry `file_id: ""` and are checked by
shape and by the existing tests, as before. The rewrite is idempotent on all 138.

The subtitles are worth keeping in the record even though nothing will ever ingest one:
they are a SECOND unsigned family from a different host, signed — when at all — by a
`?sign=` query rather than by path. One unsigned family could be a quirk of the video
endpoint; two say the signed-in-path form is the special case.

## The sanitizer was erasing the thing the guard now reads

`syntheticUrl` replaced every non-final path segment with `00`. That kept path DEPTH,
which was all the old rule needed — and `00/00` is not a `<timestamp>/<signature>`, so
every sanitized fixture would have passed straight through the new one. Exactly the trap
483 and 485 already recorded for the host and the `!transform` suffix: a fixture that
proves the opposite of what the canary asks.

So a signing prefix is now replaced by same-shaped filler
(`/000000000000/00000000000000000000000000000000/`), still all-zero, and the three
committed rednote fixtures carry it (196 URLs rewritten in place; no `SAMPLE` id moved,
so no assertion had to be rewritten). The vacuity guards in `bulk-rednote.test.js` —
the ones that assert on the INPUT so a re-capture cannot go quiet — now check the SHAPE
instead of `≥ 3 segments`, because `≥ 3` is precisely the test that a `/stream/1/110/…`
passes.

`sanitize-capture.js` has no exports and no test; the input-shape assertions are the
trip-wire that fires the next time a fixture is regenerated.

## Two things this turned up, neither of them fixed here

- **The host tables already cover video.** `media-hosts.js` gates rednote on
  `hostIs(host, "rednotecdn.com")` and `ShareCapture.swift` lists the same apex, so
  `sns-v11` / `sns-v27` are already allowed on both sides and `drift-check.js`'s
  `Producer host tables` arm stays clean (`cdnHosts=5`, `swiftOnly=1`). `manifest.json`
  already permits `*://*.rednotecdn.com/*`. T6 needs no host-table work for the stream
  to be reachable.
- **This was NOT purely latent.** `parseNoteDetail` refuses video notes, so the bulk
  path could not reach it — but the single-capture path can. `rednote.extract` picks
  `largestMedia(harvest, CDN)`, `mediaMatching` filters on the URL pattern alone, and
  `harvest.js` emits a `kind: "video-src"` entry for any non-`blob:`/`data:` video src.
  A rednote note page whose player exposes a direct mp4 therefore hands a stream URL
  straight to `toRednoteOriginal`; before this commit that stored a 404 as `mediaUrl`
  with the working URL demoted to `mediaUrlFallback`. Whether rednote's web player uses
  a direct src or an MSE blob is unverified — no live DOM capture answers it — so the
  reachability is by construction, not observed.

## Files changed

Changed: `extension/src/extractors/rednote.js` (`hasSigningPrefix`, the guard, the doc
comment), `extension/scripts/sanitize-capture.js` (shape-preserving signing filler),
`extension/test/extractors.test.js` (+3 tests; the synthetic `1717000000/9f3c1d` and
`1/s/` prefixes replaced with live-shaped ones),
`extension/test/bulk-rednote.test.js` (the two input vacuity guards now test shape; two
truncated live signatures restored to their full 32 chars),
`extension/test/drift.test.js` (synthetic prefixes),
`extension/test/fixtures/rednote-board-live.json`, `rednote-board.json`,
`rednote-note-detail.json` (196 signing prefixes reshaped),
`extension/test/fixtures/README.md`.

## Verification

`npm test` 823 → **826 total, 823 pass, 0 fail, 3 skipped** (the 096 corpus and
page-signal fixtures, still not rednote's). Seven deliberate breakages of
`rednote.js`, each failing the tests that name it and no others: the count-only guard
(fails both new tests, and nothing else — the shipped defect); an unbounded signature
length; a timestamp that merely starts with a digit; a lowercase-only hex test; dropping
the `≥ 3` half; dropping the empty-key guard; dropping both at once. Two mutants survive
deliberately and are recorded rather than chased: pinning the timestamp to exactly 12
digits (the live width — the 10–14 bound is slack, not a claim), and the `≥ 3` half alone
(it and the empty-key guard overlap, and each still catches a case the other does not).

`node scripts/drift-check.js` prints `No drift`, both rednote arms pass, and it still
exits **2** on the X/Instagram fixture-staleness arm, which pre-dates this change.

## Migration notes

- None at runtime for images: 184/184 of the previously-verified URLs rewrite exactly as
  before, and no stored provenance changes meaning.
- A rednote CDN URL with no signing prefix now comes back **unchanged** rather than
  rehosted onto `ORIGIN_HOST`. Any caller that assumed the output always lands on
  `ORIGIN_HOST` must read it as "lands there *if it was signed*" — which is what the
  drift canary already asserts, since every URL it sweeps is a signed image.
- Re-running `sanitize-capture.js` over the rednote raws no longer reproduces the
  pre-487 clean files byte for byte: the signing prefix changes from `00/00` to the
  shaped filler. The Instagram, Pinterest and X raws are unaffected — no capture of
  theirs has a segment pair matching the signing shape.
