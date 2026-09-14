# 485 — nine pictures behind one cover

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T5a, the pure half of K3b — `parseNoteDetail`
in `extension/src/bulk-rednote.js`, which turns one intercepted note-detail response
into one `BulkItem` per `image_list[]` entry, plus the sanitized capture it is tested
against. Nothing here opens a note: the driving that produces these responses, the
opt-in popup toggle and the known-set pre-check (098 R14) are T5b's, and this file
still only ever parses what arrived.

The board pass sees one cover per note. The detail response is the first place a
note's other eight images exist at all — so this is where the fan-out that doc 020
expected from the feed finally has data to stand on.

## The challenge recognizer had to grow a second shape without losing the first

`detectRednoteChallenge` was written around `data.notes`. A detail response answers
with `data.items`, so the recognizer had to serve both — and every rule in it was
learned the hard way (a 461 arrives wearing `success: true, code: 0`; the genuine last
page is an empty ARRAY and must not read as a refusal). A second copy would have
inherited only the rules that were true on the day it was made.

So the envelope rules live in one function that takes the payload key as a parameter,
and the two exported recognizers name their own payload. `drift.test.js` pins the
property that makes the generalisation safe rather than merely shared: a board page is
a challenge to the detail recognizer and a detail page is a challenge to the board
one. A single `data.notes || data.items` check would pass both, and that is the defect
the test exists for.

## Three decisions that are decisions, not omissions

- **Live Photos keep their still.** 098 Open question 4 defers them; deferred means the
  MOTION half. The entry's urls serve a perfectly good picture, so the picture is
  captured and `rawMetadata.livePhoto` flags it — dropping the item would have cost a
  user an image for the sake of the part we are not taking, and left nothing to find
  the note by later.
- **Video notes are refused, visibly.** T6 is blocked on a `type: "video"` capture, so
  a video note's `image_list` shape is unverified — and on the likeliest reading it
  holds the poster the cover pass has ALREADY ingested as `<note_id>`. Fanning it out
  would enqueue the same picture again as `<note_id>:0`: two keys, two downloads, and a
  dedup-skip that cannot see the duplicate. `unsupported: "video"` degrades to the
  cover, which for a video note is exactly what K3a captures today, and shows up in the
  degradation count when T6 arrives to lift it. An unrecognised type is NOT refused —
  its images are real and the label rides along in `rawMetadata.noteType`.
- **An empty `data.items` is a missing note, not a refusal.** The asymmetry with the
  board feed is deliberate: there `notes: []` is the terminator, here `items: []` is a
  note that did not come back, and halting a 400-note sweep because one note was
  deleted is a worse failure than continuing. The shape that still halts is a body with
  no `data.items` array at all — which is what the observed 461 actually looked like.

## The contract T5b must honour

`{ items, noteId, unsupported, error }`, and two clauses of it are load-bearing:

- **`items: []` with `unsupported` set means "keep this note's cover item"**, never
  "this note is empty". Expansion must degrade to the cover, not replace it with
  nothing. A test asserts the invariant directly — no items ⟺ a stated reason — because
  the one thing the wiring cannot recover from is an empty list with nothing to explain
  it.
- **`error` must be re-raised, not degraded.** `expandItems` degrades gracefully on a
  throw (098 R7), which is right for a note that would not open and wrong for a
  refusal: degrading past one keeps opening notes against a session rednote has flagged.

`noteId` is returned so the caller can check the response against the note it opened —
the replay-buffer hazard `matchesScope` already guards on the board pass.

## The index is a position, not a count

`sourceId` is `<note_id>:<index>` where the index is the entry's place in `image_list`,
never a running count of items produced. If image 4 of 9 ever loses its url, images 5–9
must keep the keys they had last sweep — a counter would re-key them onto ids a previous
sweep already ingested for different pictures, hiding four new images and pinning four
stale ones forever. Pinned by a test; breaking it fails that test and nothing else.

## The fixture, and the trap it did not fall into

`rednote-note-detail.json` — the live note of 2026-09-13, nine images, sanitized. The
sweep needed **no change this time**: the rednote CDN host, the five-segment path depth
and the `!transform` suffix all survived as it already stood (483 taught it those), and
`audit-capture.js` printed `LEAKED: 0` on the first run. Re-sanitizing the rednote,
Instagram and Pinterest raws still reproduces their committed clean files byte for byte.

`bulk-rednote.test.js` asserts the trap on the INPUT the way the board canary does —
signed host, ≥ 3 segments, a surviving `!` — and adds one the board cannot: the
rewritten key must still be **multi-segment**. On this endpoint a flat key would mean
the drop-two rule had quietly become the last-segment rule again, which is the 404 that
098 T0 shipped to fix. Flattening the fixture's paths fails both live tests.

## `drift.CHECKS["rednote-detail"]`, beside the board's

Registered now rather than waiting for the driving half, for the reason 098 D7 gives:
miss the drift entry and the parser rots silently. It sits next to `rednote` the way
`x-thread` sits next to `x` — a second endpoint on its own clock, which a board capture
can never answer for. The drift it watches is different from the board's, too: there
the fan-out is 1:1 and the signal is a row that stops yielding an image, here the
fan-out IS the feature, so the signals are a count that stops matching the array it came
from, a `sourceId` that stops being positional, and two images collapsing onto one url.

## Files changed

New: `extension/test/fixtures/rednote-note-detail.json` (the canary's note capture, 9
images). Changed: `extension/src/bulk-rednote.js` (`parseNoteDetail`, `mapNoteImage`,
`detectRednoteDetailChallenge` + the shared envelope helper, `NOTE_DETAIL_PATH` /
`isNoteDetailRequest`), `extension/src/drift.js` (`checkRednoteNoteDetail`, `CHECKS`),
`extension/scripts/drift-check.js` (`FIXTURE["rednote-detail"]`),
`extension/test/bulk-rednote.test.js` (+21), `extension/test/drift.test.js` (+7 and the
registry list), `extension/test/fixtures/drift-baseline.json` (a `rednoteNoteDetail`
marker), `extension/test/fixtures/README.md`. `scripts/sanitize-capture.js` is
untouched.

## Verification

`npm test` 729 → 756 total, 753 pass, 0 fail, 3 skipped (the 096 corpus and page-signal
fixtures, still not rednote's). Seven deliberate breakages of `bulk-rednote.js` — a
counted index, no video refusal, a blurred payload check, a dropped `livePhoto` flag, a
silenced `unsupported`, the token moved into provenance, a prefix-matching route — each
fail the tests that name them. `node scripts/drift-check.js` prints
`✔ rednote note detail (committed fixture) — images=9 items=9 noteType=normal` and still
`No drift`; it still exits **2** on the X/Instagram fixture-staleness arm, which
pre-dates this change (098 Risks).

## Migration notes

None. `detectRednoteChallenge` keeps its name, signature and every kind string, so the
board path is unchanged — every existing board-feed test passes untouched. The new
exports are additive and nothing in `src/` calls `parseNoteDetail` yet: T5b is what
gives it a caller.
