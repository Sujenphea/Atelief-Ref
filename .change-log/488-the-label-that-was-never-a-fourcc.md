# 488 — the label that was never a fourcc

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T6b, the pure half of K4 — the half that can
exist now that a `type: "video"` note has finally been captured
(`resources/rednote-note-video.json`, 2026-09-14). New
`extension/src/rednote-video.js`: `selectStreamRung`, `videoCandidates`, and the
structural guard that keeps a stream list out of a checkpoint. Plus the sanitized fixture,
a third rednote drift arm, and one more repair to the sanitizer.

Nothing is wired. `capture-plan.js`, `sw.js`'s `ingestOne`, the 422 rung-advance, the
popup, and `parseNoteDetail`'s refusal of video notes are all untouched — T6c's, split the
way T2 → T3 and T5a → T5b were, because it has now worked twice.

## What the capture actually shows, and what it cannot

```
note_card.video.media.stream = { EF5: [], EF7: [], EF4: [1 rung], EF6: [] }
```

**One populated bucket.** The rung is `stream_type: 258`, `format: "mp4"`, 720×960, with
`master_url` on `sns-v11` and one `backup_urls[]` entry on `sns-v27` — same path, different
shard. Those urls are served **already unsigned** (`/stream/1/110/258/<id>_258.mp4`) and
`master_url` was fetched live: **206, `video/mp4`**.

So the rung-level shape is verified and the ordering BETWEEN buckets is not, and cannot be
until a note turns up with two of them populated. That is said in the module's own doc
comment, in the drift-baseline note and in the fixtures README, because it is the sort of
caveat that evaporates the first time someone reads only the code.

Two things the capture settled that D5 had guessed at:

- **`backup_urls[]` exists.** D5 assumed candidates would have to be synthesised from rung
  ordering alone. They do not: a single rung contributes several urls, so exhausting the
  candidate list is no longer the same thing as exhausting the ladder, and a 422 must
  advance WITHIN a rung before it advances between rungs.
- **`video.media_v2` is a JSON *string* duplicating the whole media object.** Two
  representations, one of which will rot silently. `videoLadder` reads the structured form
  and nothing else.

## `ef*` is a fourcc. `EF4` is not. The two are four characters apart

020 rule 1 says *treat `ef*` fourccs as unusable*, and it is easy to re-derive backwards
because rednote's bucket names are also `EF`-prefixed. They are not the same thing at all.
020's undecodable rung was a `_330` whose MP4 **sample entry** carried fourcc `ef51`; the
JSON's `video_codec` in this capture is `"EF4"`, the bucket label. A selector that refused
`EF*` labels would refuse every rung rednote has ever sent — which is exactly what the
mutation run showed: relaxing `isUndecodableCodec` from `/^ef[0-9a-f]{2}$/i` to `/^ef/i`
broke **21** tests, including the live capture selecting at all.

The disambiguation that made the rule expressible: a fourcc is four characters (`avc1`,
`hvc1`, `ef51`); a bucket label is three (`EF4`…`EF7`). So `isUndecodableCodec` matches a
four-character `ef??` label, is applied to `video_codec` only (never to the bucket name, so
a future bucket called `EF51` is not mistaken for a codec), and **no capture has ever
carried a label it matches** — it is a forward guard, exercised by the table test and by
nothing else. The residual risk is stated in the source rather than hidden: if rednote ever
names a real codec `ef??` we refuse a rung we could have taken and the note degrades to its
cover still, which is the direction 020 calls honest. The opposite error is what the 422 is
for.

## The selection rule

1. Drop a rung with no url, and a rung that is not an mp4 — `format` when it is stated, the
   url's extension when it is not, and dropped rather than guessed at when neither says.
   `/ingest-video` takes raw bytes, so a manifest is not ingestable; the same rule
   `pinterest-video.js` applies when it filters down to `.mp4`.
2. Drop a rung whose `video_codec` is a four-character `ef??`.
3. Order what is left: buckets by `STREAM_BUCKET_ORDER` (`EF4`…`EF7`), then any bucket name
   we have never seen, in the object's own key order; within a bucket, **rednote's own array
   order**.
4. Per rung, `master_url` then its `backup_urls[]`, deduped.
5. Nothing left → a typed refusal, never a bare null: `no_ladder`, `empty_ladder`,
   `no_usable_rung`, `undecodable_codec`. Every one means *keep the cover still and record a
   skip*; none of them is a sweep failure (020, Risks & edge cases).

**Never by size.** 020 rule 1, learned by getting it wrong — taking the largest file is what
landed the manual run on `ef51`, and falling back to an h264 rung cost resolution only:
identical duration, same content. The fixture makes that hard to un-learn by accident, since
`size` clears the sanitizer's numeric-id floor and is therefore synthetic — a selector
sorting on it would be sorting on noise.

An **unknown bucket is ordered last but never dropped**: it has never been observed, so it
cannot outrank one that has, but refusing content outright is a worse trade than one 422
against it.

Confidence, honestly: **high** on steps 1, 2, 4 and 5 — each is either forced by the data or
by the transport. **Low** on the ordering among `EF5`/`EF6`/`EF7` in step 3. The guess is
that `EF<n>` is a codec-generation index and that the lower generation is the more
universally decodable, which is the rule `pinterest-video.js` applies for H.264 over HEVC;
that correspondence is unverified here. `EF4` first is not a guess — it is the only bucket
ever seen populated and the only rednote stream anyone has fetched.

## The `stream_type` hypothesis: recorded, not acted on

The working rung is `_258` / `stream_type: 258`; 020's undecodable one was a `_330`. That is
n=1 good and n=1 bad, which is not enough to select on — and no JSON signal is trustworthy
enough on its own, which is the entire reason the 422 is the designed backstop. So
`stream_type` rides on every rung descriptor and is **never sorted on**, with a test pinning
that a non-numeric one is reported as absent rather than coerced and does not affect
selection. It is how the hypothesis would ever earn a promotion: T6c's rung-advance can
report which types 422'd.

The sanitizer change below exists partly for this — without the `_<n>` suffix on the
filename, the hypothesis would have been out of reach of any future evidence.

## Never checkpoint a stream list — structurally, not by comment

020 B3: the same note offered a **different ladder on two visits minutes apart**, so a
persisted `master_url` comes back 404 or hands over a rung that is no longer the right one.

The primary defence is that `videoCandidates` is a pure function of a response that the page
fetches anyway, so re-resolving on resume is free. The backstop is structural:
`withVideoCandidates` defines the property **non-enumerable**, and every way a sweep could
persist or ship an item copies own *enumerable* properties only —

| | |
| --- | --- |
| `JSON.stringify(item)` | what a checkpoint value is serialized by |
| `structuredClone(item)` | what `chrome.storage.local` and `postMessage` use |
| `{ ...item }` | what any copy in between uses |

— so the list is legible to code that asks for it by name and invisible to everything that
merely copies the item. It is frozen and non-configurable besides. The test that guards it
runs the **real `runSweep`** over items carrying attached candidates and asserts every byte
it saved: no candidate url, and no `rednotecdn.com/stream/` path, in any checkpoint value.
Flipping `enumerable` to `true` fails it.

## The sanitizer, a fourth time

483 the CDN host, 485 the `!transform` suffix, 487 the `<timestamp>/<signature>` shape — and
the video capture walked into the same trap from the other side. rednote serves streams with
**no** signing prefix and real route where one would sit, and `syntheticUrl` flattened
`/stream/1/110/258/<id>_258.mp4` to `/00/00/00/00/SAMPLE.mp4`. The fixture still parsed and
the canary would still have gone green, while proving nothing about either property the
ladder rests on: that the chosen url is one `toRednoteOriginal` leaves alone (487), and that
the filename's `_<n>` agrees with the rung's `stream_type`.

So there is now a second branch beside the signing-prefix one: on a rednote CDN path with no
signing prefix, a segment that is a bare lowercase word or a number under six digits is
ROUTE and is kept verbatim — it cannot carry identity by construction, being the same two
classes the value sweep already treats as schema — and the filename keeps its
`_<stream_type>`. Everything else in those positions is still replaced.

`audit-capture.js` also learned that `mp4` is a container literal: a bare word with a digit
in it, so the lowercase rule could not reach it and every rung's `format` reported as a leak.
Enumerated rather than loosened — `^[a-z][a-z0-9]*$` would re-excuse `testing2` and
`mariosworld343`, the two the lowercase rule was tightened for in the first place.

**Neutrality.** Re-sanitizing the Instagram and Pinterest raws reproduces their committed
files byte for byte. The two rednote fixtures change by **one segment each**: an avatar url
now reads `/avatar/SAMPLE1` instead of `/00/SAMPLE1`, since `avatar` is a route word under
the new branch. They were re-sanitized so that "re-run the sweep and it reproduces" stays
true — a spurious diff is how the next agent's neutrality check gets ignored. No `SAMPLE`
id moved, so no assertion had to be rewritten. `rednote-board.json` is a hand-composed,
deliberately frozen fixture and was left alone. X has no raw in `resources/` and could not be
re-checked.

## Drift: a third rednote arm, not a bigger second one

`rednote-video` sits beside `rednote-detail` the way that sits beside `rednote`, and the way
`x-thread` sits beside `x`: a different capture on its own clock. Folding it into
`rednote-detail` was rejected on evidence rather than taste — the video capture *fails*
`checkRednoteNoteDetail`, on a rule that is correct there. A video note's one-entry
`image_list` is a poster, not a carousel, and `parseNoteDetail` deliberately refuses to fan
it out (T5a).

`checkRednoteVideo` asserts the ladder path still exists, that the chosen rung is a fetchable
mp4, that the candidate list starts at its `master_url`, that every candidate is on the
rednote CDN and passes through `toRednoteOriginal` unchanged (a 487 regression tripwire),
and that the poster survives — the cover pass already ingested it as `<note_id>`, so a note
whose `image_list` empties has nothing to degrade to. The **codec assertion** 020 asked for
by name is written as a synthetic probe rather than as a claim about the capture: asserting
that the *chosen* rung is not an `ef??` would be unreachable, because the selector filters
those out before it chooses, and an assertion that can never fire is not an assertion. What
the probe checks is that it still filters. The rung labels are reported as a `codecs` signal
so a change is visible in the canary line even when nothing breaks.

`platform-registry.test.js` keys on the platform-level `rednote` entry, so it is satisfied
already; the new arm is wired the same way `rednote-detail` is — `CHECKS`, `FIXTURE` in
`scripts/drift-check.js`, and a dated `rednoteNoteVideo` marker in `drift-baseline.json`.

## What T6c still has to handle

- **The poster is the trap.** The cover pass ingests it as `<note_id>` (`mapBoardNote`).
  The video note's `image_list` is one entry — the SAME picture — so fanning it out as
  `<note_id>:0` is one picture, two keys, two downloads and a dedup-skip that cannot see
  the duplicate. That is exactly why T5a refuses video notes, and lifting the refusal must
  not lift it by fanning out `image_list`.
- **`parseNoteDetail` still refuses them** (`unsupported: "video"`), by design. Nothing in
  this commit changes it.
- Where the candidate list should ride, and whether a video note produces a new item or
  upgrades the cover item in place, is an open decision — `withVideoCandidates` only makes
  sure that wherever it rides, it cannot be persisted.
- `planCapture` must grow an ordered `videoCandidates[]` (one element for every existing
  platform, behaviour-identical) and `ingestOne` must walk it, mapping **422 → advance the
  ladder**, never `permanentFailed` (020 rule 2). `sw.js:269` is a single try today.
- Exhausting the list is the `ef*`-only outcome in practice, and it is a typed skip with the
  cover kept — not a failed item.
- `media-hosts.js` and `manifest.json` already permit the `sns-v*` hosts (487 checked);
  nothing to add there.

## Files changed

New: `extension/src/rednote-video.js`, `extension/test/rednote-video.test.js` (26 tests),
`extension/test/fixtures/rednote-note-video.json`.

Changed: `extension/src/drift.js` (`checkRednoteVideo`, `CHECKS`),
`extension/scripts/drift-check.js` (`FIXTURE`),
`extension/scripts/sanitize-capture.js` (the unsigned-path branch),
`extension/scripts/audit-capture.js` (container literals),
`extension/test/drift.test.js` (+7),
`extension/test/fixtures/drift-baseline.json` (`rednoteNoteVideo`),
`extension/test/fixtures/rednote-board-live.json`,
`extension/test/fixtures/rednote-note-detail.json` (one avatar segment each),
`extension/test/fixtures/README.md`.

## Verification

`npm test` 826 → **859 total, 856 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all three
rednote arms pass — `noteType=video buckets=4 populated=1 rungs=1 candidates=2 codecs=EF4
bucket=EF4 streamType=258 posters=1` — and it still exits **2** on the X/Instagram
fixture-staleness arm, which pre-dates this change.

Twenty-four deliberate breakages, each failing the tests that name it. The ones worth recording:
`isUndecodableCodec` relaxed to `/^ef/i` breaks 21 (the EF-label/fourcc distinction is
load-bearing everywhere); the bucket order reversed breaks 3; sorting rungs by `size` or by
`width` breaks the 020-rule-1 test; backups before master, and dropping the per-rung dedupe,
each break one ordering test; `enumerable: true` and dropping `Object.freeze` each break the
checkpoint test; collapsing `empty_ladder` or `undecodable_codec` onto `no_usable_rung`
breaks the drift check's own probes, which is what they are for; a `videoLadder` that falls
back to parsing `media_v2` breaks the ladder test; and `hasSigningPrefix` reverted to a
depth test (the 487 regression) breaks the drift arm and the fixture's input-shape guard.

**Three mutants initially survived and each one was a real gap, now closed.** Sorting the
`decodable` list by `size` changed nothing, because `size` was not on the rung descriptor —
the size test was re-aimed at `orderRungs`'s own entries and at the candidate ORDER, not
only at which rung is chosen. Dropping the per-rung url dedupe changed nothing, because
`videoCandidates` deduped the flat list afterwards — the test now also asserts
`rung.urls`, which is the list a within-rung advance walks. And a `videoLadder` that fell
back to `media_v2` when the structured form was absent changed nothing, because the fixture
always has the structured form — asserted directly now, against a card carrying `media_v2`
and nothing else.

One survivor is recorded rather than chased: deleting an input-independent probe from a
drift check is not detected by any test, since a healthy capture exercises none of them.
That is true of the two probes already in `checkRednoteBoard` and `checkRednoteNoteDetail`,
and the probes are shown load-bearing the other way round — changing the rule they check
does fail the tests.

## Migration notes

- Nothing at runtime. No production code path imports `rednote-video.js` yet; the sweep is
  byte-for-byte the sweep it was, and a video note still degrades to its cover.
- Re-running `sanitize-capture.js` over the rednote raws no longer reproduces the pre-488
  clean files: one avatar path segment per fixture. The Instagram and Pinterest raws are
  unaffected.
- A stream list must never be put on a `BulkItem` by plain assignment. Use
  `withVideoCandidates`, or the next checkpoint write will carry a url that the note may
  already have stopped serving.
