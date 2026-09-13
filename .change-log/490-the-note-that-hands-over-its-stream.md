# 490 — the note that hands over its stream

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T6c, the wiring half of K4 and the last task in
the plan. `planCapture` grows an ordered `videoCandidates[]`; `ingestOne` walks it, mapping
**HTTP 422 → advance the ladder** (020 rule 2) rather than to a failed item; and
`parseNoteDetail` stops refusing video notes — **without** fanning out their poster, which
was the whole reason T5a refused them.

A video note now contributes its **stream**, keyed `<note_id>:v`, beside the cover the K3a
pass already captured at `<note_id>`. Nothing about 488's selection rule was re-opened: the
ordered list it produces is walked as given.

> **Index.** This entry is 490, not 489. A concurrent, unrelated session had already
> allocated `489-the-poster-that-never-came-down.md` (a Swift `VideoPlayer` fix) by the
> time this landed, and indices are never reused.

## What `resolveVideo` means here, and how it composes with `expandNotes`

`resolveVideo` is the popup toggle that already exists, meaning what it has always meant —
*relay the resolved MP4 instead of the still*. No second toggle was invented. On rednote it
also answers a question the other three platforms never have to ask, because a rednote
ladder exists **only inside a note-detail response**:

| `expandNotes` | `resolveVideo` | the sweep |
| --- | --- | --- |
| off | off | the cover pass. One poster per note. Unchanged. |
| off | on | the cover pass, unchanged — a cover-only sweep never fetches a note detail, so no ladder is ever seen. |
| on | off | notes open; image notes fan out; **video notes are not opened at all** and keep their cover, exactly as T5b shipped. |
| on | on | notes open; image notes fan out; a video note yields its cover **and** `<note_id>:v`. |

So `expandNotes` decides whether notes are opened, and `resolveVideo` decides whether a
*video* note is one of them. That second half is a real escalation on a board that is 81 %
video — roughly five times the note-opens — so the D8 risk gate now re-renders and re-arms
on the video checkbox too, not only on the expansion one. Acknowledging the smaller sweep
must not silently authorise the larger.

## Two decisions, and the evidence for each

### (a) Where the candidate list rides

The tension is real: 488 made the property **non-enumerable** precisely so it cannot be
persisted (020 B3 — the same note served a different ladder on two visits minutes apart, so
a checkpointed `master_url` 404s or hands back a bad rung), while the existing video path is
`bulk-controller.js`'s `item.provenance.rawMetadata.videoUrl` — and **`provenance` is
persisted**.

The ladder therefore never touches provenance. It travels like this:

```
parseNoteDetail → withVideoCandidates(item, ladder)   non-enumerable, frozen
  → expander → intercept-source → engine             by REFERENCE, in one page, no copies
  → bulk-controller relay:  readVideoCandidates(item) read BY NAME, the one reader
  → runtime message field `videoCandidates`          transient, alongside provenance
  → bulk-sw → ingestOne → planCapture
```

Everything that *stores* copies own enumerable properties only, so the engine's checkpoint
write (`JSON.stringify`) drops it, as does any `structuredClone` or spread. 488's guard
test — the real `runSweep`, asserting every byte it saved — still passes untouched, and
there are now two more beside it: one driving the real `runBulkSweep` and asserting no
stream url reaches a saved checkpoint *through the controller*, and one asserting the
relayed `provenance` carries none while the message's own field does.

What the stream item's `rawMetadata` keeps is the rung's **description** — `streamBucket`,
`streamType`, `width`, `height`, `streamRungs` — facts that cannot rot into a dead fetch,
and the only way 488's `stream_type` hypothesis could ever gather evidence.

### (b) The `sourceId`, and the re-open trap

`<note_id>:v`. Checked against the **actual** `knownNoteIndex` predicate rather than a
description of it: that function counts a note as expanded when a known id has a `:` at
index > 0 (`id.indexOf(":") > 0`), so `<note_id>:v` registers as an expanded child for free,
with no change to the function and no migration of anything already ingested. The letter
cannot collide with an image index, so a note that one day carries both a stream and a
carousel keys them apart by construction.

The rejected alternative was **upgrading the cover item in place**. It leaves no expanded
child, so `knownNoteIndex` never learns the note is done and every video note is re-opened
on every future sweep — burning the 400-note budget forever on a board that is 81 % video.
That is the exact failure the T5 addendum exists to prevent, and the test that pins the fix
arms the pre-check from a real known-set and asserts the note-open never happens.

**And an `ef*`-only note?** It yields no stream, registers nothing, and **is re-opened on
the next expansion sweep.** That is deliberate, not an oversight, and the reason is 020 B3
again: a refusal is a fact about *one visit's ladder*, not about the note. Recording it as
permanently done would wall the note off forever on the strength of a list that demonstrably
rotates. The cost is one paced note-open per refused note per sweep, bounded by
`NOTE_OPEN_BUDGET`, and it is counted (`streamRefused`) and named (`reasons.empty_ladder`,
`reasons.undecodable_codec`) rather than silent. It is also, today, unreachable in the wild:
no capture has ever carried a fourcc in `video_codec` at all.

## 422 advances. 404 advances. A dead network does not

`downloadAndIngestVideo` used to throw bare `Error`s, which is not something to re-parse, so
every throw is now tagged with `videoStage` (`"download"` | `"ingest"`) and `httpStatus`
where there is one. `videoCandidateVerdict` reads them:

| failure | verdict | why |
| --- | --- | --- |
| **422** from `/ingest-video` | **advance** | 020 rule 2 by name — the undecodable-rung signal. The bytes arrived and the app could not read them; nothing about the next rung is implied. |
| any other ingest status | stop | 401/403 is a bad token (session-wide); 5xx is our own app; 413 means the next rung is likelier bigger, not smaller. |
| **404 / 410** from the CDN | **advance** | This candidate is *gone*. 020 B3: the ladder rotates, so retrying the same url cannot help and the fix is next in the list — a backup shard carrying the same object, or the next rung. Deliberately **not** "retryable": that would spend the item's four backoff attempts re-fetching a url that no longer exists. |
| any other CDN status | stop | 429/5xx is the CDN's state, not this rung's; 401/403 is an auth wall the engine halts on. |
| a 200 whose body is not a video, or an over-cap clip | advance | The response was fine and *this candidate's* body is unusable. |
| the fetch threw (DNS, timeout, abort) | stop | It says nothing about the rung. Walking on would be N dead requests instead of one — and the engine already has the right mechanism: the item is re-relayed with backoff, which **re-resolves the ladder**, which is what 020 B3 wants anyway. |

**Within a rung before between rungs.** That ordering is 488's, walked as given rather than
re-derived — D5 predates the discovery that `backup_urls[]` exists, so a rung contributes
several candidates and exhausting the list is not the same as exhausting the ladder.

**Bounded** at `MAX_VIDEO_CANDIDATES = 4`. Each attempt is a whole download (up to the
512 MB cap), so the ceiling is about bytes as much as requests: four admits the only ladder
ever captured (one rung, two urls) plus a second rung's master and backup — two genuine
codec attempts. Past that, the honest answer is 020's.

## Exhausting the ladder is a typed skip, with the cover kept

020, Risks & edge cases: *"the honest outcome is cover-still-only for that note; record it
as a typed skip, do not fail the sweep."*

For X, Instagram and Pinterest this never fires — their video items carry a poster, so the
existing fail-open falls back to it and the item saves as an image, unchanged. It fires for
a rednote stream item, which deliberately carries **no still at all**: its poster is a
separate item at `<note_id>`, and giving this one the poster as a fallback would re-download
the same picture under a second key — precisely the one-picture-two-keys duplicate T5a
refused video notes to avoid.

So `ingestOne` returns `{ status: "skipped", reason: "video-ladder-exhausted" }`, and
`classifyIngestResult` gains a `skipped` arm mapping it to `OUTCOMES.skipped`. Not
`permanentFailed` (which marks the sweep unclean and disarms the *whole board's* pre-check
next run) and not `retryableFailed` (which spends four backoff attempts re-walking a ladder
that just said no). A test drives the real `runSweep` and asserts the sweep still closes
with zero failures of either kind.

## `partial`, re-examined rather than inherited

T5b excluded video refusals from `partial` so an 81 %-video board did not report partial on
every sweep. Now that video notes genuinely expand, there are two different things that
looked like one, and they are counted apart:

- **`refused`** — a video note the sweep was told not to open (the video toggle is off).
  Expansion was never on offer for it.
- **`streamRefused`** — a note that *was* opened, at the price of a paced note-open, and
  whose ladder held no decodable stream.

Neither is `partial`, and the second is the one worth arguing. A sweep that opened the note,
read its ladder and found nothing decodable **did everything it set out to do**; the content
is not there in a form `/ingest-video` can take. Calling that "partly expanded" would put an
`ef*`-heavy board straight back where T5b's split took it out of. Both are counted, both
appear in `reasons`, and `degraded` still means what it meant: a note that would not open or
would not answer.

`counts.streams` is also split from `counts.images` — a board reporting "37 images" for 30
videos and 7 carousels would be telling the user something false.

## `capture-plan.js`: additive, and identical for the other three

The shared tier-3 seam (096 D7) gains one optional input and one output field:

```
planCapture(provenance, { mp4Url, content, isAllowedHost, videoCandidates })
  → { kind, videoUrl, videoCandidates, urlCandidates, content, blocked, reason }
```

`videoCandidates` is always an array, `videoUrl` is always its head, and the list is
`[mp4Url, ...ladder]` deduped. X, Instagram and Pinterest pass a single `mp4Url` and no
ladder, so their plan carries a **one-element** list whose head is the url they resolved:
`videoUrl` is byte-for-byte what it was, and the walk runs once. The three existing
`deepEqual` result assertions in `sw.test.js` pass **unchanged** — the saved result shape
deliberately grew no `attempts` field, which is the cheapest possible proof of the identity
claim.

The host guard is *not* applied to video urls inside `planCapture`. It never was for
`mp4Url`, and moving it there would change what a tier-3 caller (the only kind that passes
`isAllowedHost`) gets back. The guard stays where it is — one gate for the whole item, in
`bulk-sw.js`'s relay — and now covers **every rung**, not just the first, because a ladder
is exactly as page-supplied as the still urls beside it and the SW fetches it with
`host_permissions`.

## Files changed

`extension/src/capture-plan.js` (the ordered list),
`extension/src/sw.js` (`videoCandidateVerdict`, the bounded walk, tagged throws, the
`skipped` badge), `extension/src/config.js` (`MAX_VIDEO_CANDIDATES`),
`extension/src/bulk-engine.js` (the `skipped` arm),
`extension/src/bulk-sw.js` (guard + thread), `extension/src/bulk-controller.js`
(`readVideoCandidates` into the relay message, `resolveVideo` into the driver),
`extension/src/bulk-rednote.js` (`videoSourceId`, `mapNoteVideo`, `parseNoteDetail`'s
`resolveVideo` + `noteKind`), `extension/src/rednote-detail-client.js` (the expander's
ordering, counters and toggle), `extension/src/rednote-video.js` (`readVideoCandidates`),
`extension/src/drift.js` (the T6c half of `checkRednoteVideo`),
`extension/src/popup-view.js` + `extension/src/popup.js` (the gate follows both toggles).

Tests: `capture-plan` (+5), `sw` (+8), `bulk-engine` (+1), `bulk-sw` (+3),
`bulk-controller` (+3), `bulk-rednote` (+7), `rednote-detail-client` (+7),
`bulk-rednote-integration` (+2), `rednote-video` (+1), `popup-view` (+2) — 39 in all.

## Verification

`npm test` 859 → **898 total, 895 pass, 0 fail, 3 skipped** (the 096 corpus and page-signal
fixtures, still not rednote's). `node scripts/drift-check.js` prints `No drift`, all nine
arms pass — `rednote video ladder … noteType=video buckets=4 populated=1 rungs=1
candidates=2 codecs=EF4 bucket=EF4 streamType=258 posters=1` — and it still exits **2** on
the X/Instagram fixture-staleness arm, which pre-dates this change.

Twenty-six deliberate breakages, each failing the tests that name it and no others. The
ones worth recording:

- `videoCandidateVerdict`'s three arms, mutated one at a time — 422 no longer advancing, 404
  no longer advancing, a transport failure advancing, an unusable body stopping — each break
  the table test **and** the `ingestOne` test that walks that path, plus the
  `downloadAndIngestVideo` test that proves the tags exist on the real throws.
- Removing the `MAX_VIDEO_CANDIDATES` slice breaks exactly the bound test.
- `skipped` → `fetch-error` in `ingestOne`, and `OUTCOMES.skipped` → `permanentFailed` in
  the engine, each break the tests that name the outcome, including the one asserting the
  sweep still closes clean.
- `VIDEO_SOURCE_SUFFIX` changed to `"0"` breaks four tests (it becomes an image index);
  `videoSourceId` collapsed to a bare `<note_id>` — the rejected upgrade-in-place — breaks
  five, including the `knownNoteIndex` test that is the whole reason for the choice.
- Giving the stream item the poster as its `mediaUrl` breaks two tests **and the drift
  arm**. Putting a `masterUrl` into `rawMetadata` breaks the 020-B3 test and the drift arm.
  Ignoring `resolveVideo` in the parser breaks eight, including two pre-existing T5a tests.
- Moving the expander's known-set check back behind the video check, dropping a video note's
  cover, and counting a refused ladder as a degradation each break one test apiece.
- Clearing the relay's `videoCandidates`, or relaying it regardless of `resolveVideo`, each
  break the controller tests; skipping the SSRF guard for the ladder breaks the guard test.

**Three mutants initially survived and all three are now closed.** Appending `mp4Url` after
the ladder instead of leading it changed nothing, because every test passed an `mp4Url` that
was already the ladder's head — the ordering test now also passes a resolved url that is
*not* in the list. Dropping `planCapture`'s dedupe changed nothing for the same reason — the
ladder now repeats its head. And reordering the expander's known-set check was invisible
because every re-sweep test had the video toggle on; there is now one with it off, asserting
`skippedKnown` rather than a spurious `refused`.

## Migration notes

- **Nothing changes for X, Instagram or Pinterest.** One-element ladder, one attempt, same
  result object, same fail-open to the poster.
- **Nothing changes for a rednote cover-only sweep**, with or without the video toggle: the
  ladder lives in a note-detail response that pass never fetches.
- A rednote **expansion** sweep with the video toggle on is a materially heavier sweep than
  one without — every note is opened, not just the image ones. The risk gate says so and
  resets the acknowledgement when the box moves.
- `parseNoteDetail` now returns a `noteKind` field, and its `unsupported` vocabulary can
  carry the four `STREAM_REFUSAL` strings. A caller that switched exhaustively on the old
  set will fall through on those.
- `ingestOne` can now return `status: "skipped"`. Any consumer mapping its result must
  handle it; `classifyIngestResult` and `presentation` both do.

## Still unverified without a further capture

- **Only `EF4` has ever been populated**, in the only `type: "video"` capture that exists.
  Between-bucket ordering and the 422-advance **between rungs** have therefore never run
  against a real multi-rung ladder — every test that exercises them uses an invented shape,
  labelled as such. The within-rung advance (`master_url` → `backup_urls[]`) is the one the
  live capture can speak to, and it does: one rung, two urls, both on `sns-v*` shards.
- **No capture has ever carried a fourcc in `video_codec`**, so the `ef*` refusal — and with
  it the whole `streamRefused` / re-open path above — is exercised by tests and by nothing
  else.
- `createPageNoteDriver` still infers the board card's link shape and the overlay's close
  affordance (098's own "Unverified without a live run"), and T6c now drives it over video
  notes as well. If either is wrong, every note-open degrades to its cover loudly and the
  cover pass is untouched.
- A live run is the only thing that can say whether rednote's stream urls stay fetchable
  from the extension's SW context with `credentials` as the default cross-origin fetch sends
  them. `master_url` was fetched live at capture time (206, `video/mp4`) from a browser.
