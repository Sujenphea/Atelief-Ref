# 509 — the resume distrusted everything it had done

## Summary

A resumed rednote sweep opened 34 notes it had opened an hour earlier, ingested nothing
from any of them, and explained itself like this:

```
note-level pre-check disarmed — prior sweep was absent
```

The prior sweep was not absent. It was the one being resumed.

098 R14's note-level pre-check exists to stop exactly this. `knownNoteIndex` turns the
app's known-source set into "which notes has a previous sweep already expanded?", and
`createNoteExpander`'s `arm` makes the expansion pass consult it before spending a
note-open — `NOTE_OPEN_PACING_MS` (1800ms) plus up to 1200ms of jitter plus up to an 8s
wait, on a signed request against a site with live risk control. It is the single most
expensive thing a sweep does, and the pre-check is the only thing that stops a re-sweep
doing it 400 times for nothing.

It was switched off on the run that needs it most. The arming read:

```js
const freshStart = !prior;
const lastClean = freshStart && … ? await storage.load(cleanMarkerKey) : null;
const armed = priorClean && armsNotePreCheck(lastClean, sweepMode(spec));
```

A paused or halted sweep leaves a checkpoint. A checkpoint makes `prior` truthy, which
makes `freshStart` false, which means the clean marker is never even READ — so `lastClean`
is null, `priorClean` is false, and the log says "absent" about a marker nobody asked for.
And a resumed sweep is precisely the walk that meets the most already-expanded notes: it
re-walks the board from the top and has to cross everything the halted run finished before
it reaches the first note that owes anything.

The gate itself was not paranoia. `knownNoteIndex` calls a note done when ONE of its
children has landed, so a note that ingested 3 of its 9 images reads as complete — and
arming off a stale clean marker would skip it for ever, because nothing re-opens a note the
index calls done. But on a resume that can only be true AT THE HALT BOUNDARY. Everything in
front of it was walked, relayed and committed by a run that was still healthy.

**So a resume now arms the index, and disarms it from the halt point onward.** The
checkpoint carries the sourceId of the item at its committed watermark; the expander
consults the index until the walk reaches the note that owns that item, and drops it for
that note and every note after. The watermark's own note is RE-OPENED — it is the one note
the halt can have left half-expanded, and an off-by-one here loses six images permanently.

**A boundary, not an exclusion list**, and that is the load-bearing choice. The engine's
`completed` map holds items that finished OUT OF ORDER past the committed watermark. Those
items really were ingested, so their notes are in the app's known-set while being
incomplete — a list that excused only the watermark's own note would skip them. Everything
at or after the boundary is re-opened regardless, which covers them without the engine ever
having to enumerate what it had in flight.

A checkpoint from a build older than this change carries no `mode` and arms NOTHING. That
is `armsNotePreCheck`'s existing rule, unchanged and now asked of a second record: UNKNOWN
is not "cover" and not "expansion". A cover-only checkpoint does not arm an expansion
resume either — the mode trap is the same trap on a checkpoint as on a clean marker, and it
is the same function that answers it.

A fresh start is untouched in every respect: the same clean-marker read, the same rule, the
same log line, and no boundary at all.

## The note in front of the boundary that still owed an image

The boundary covers the halt point and everything past it. It does not cover a note far in
front of it whose 9th image FAILED while the other eight landed — that note is in the app's
known-set on the strength of the eight, `knownNoteIndex` calls it done, and it sits in
territory the halted run genuinely finished.

A fresh sweep has a rule for exactly this: any failure writes `clean: false` and the next
run full-walks and re-attempts the stray. **A resume launders that rule.** It skips the
note, fails nothing OF ITS OWN, completes, and writes `clean: true` — and the next fresh
sweep arms off that marker and skips the note again. The failure that should have forced a
re-walk is erased by the run that walked past it, and the ninth image is gone for good.

So the checkpoint now names every item a sweep could not land, and a resumed sweep excludes
the notes that own them from its pre-check. A note in the exclusion is re-opened wherever it
sits, index or no index, boundary or no boundary.

**The set is seeded from the checkpoint it read**, because the laundering repeats one level
up: run 2 skips the note, fails nothing, and without the seed writes an empty list, so run 3
is back where run 2 started with nothing left that remembers.

**Recorded as failures happen, not over the committed prefix.** An out-of-order failure past
the watermark is still a failure, it costs one short string to carry, and working out which
ones are safe to leave out is the kind of cleverness the boundary above exists to avoid.

**And what this fixes for free is the laundering itself.** The re-opened note re-attempts
its failed item: either it lands, and there is nothing left to launder, or it fails again —
and now the run records a failure of its OWN and writes `clean: false`, which is what should
have happened the first time. The clean-marker rule did not need changing; it needed the
failure to still be there when it was asked.

**At the cap it fails safe.** `CHECKPOINT_FAILED_ID_CAP` is 200 — half `NOTE_OPEN_BUDGET`,
and the size is not the reason for it: 200 rednote ids is ~6 KB in `storage.local`. It is a
threshold of MEANING. A run that stranded 200 items is not a sweep with some stray failures,
it is a sweep against a dead CDN cookie or a full disk, and the right answer for one of those
is the full re-walk. Exceeding the cap sets `failedOverflow`, the reader disarms the
pre-check for that resume entirely, and the flag is as sticky across resumes as the set is
seeded. It never truncates quietly: a dropped id is a note skipped while it still owes an
image, which is the precise loss the set exists to prevent.

## Files changed

- `extension/src/config.js` — `CHECKPOINT_FAILED_ID_CAP`, with why the number is a
  threshold of meaning rather than a size limit, and why exceeding it must fail safe.
- `extension/src/bulk-engine.js` — the checkpoint records the sourceId of the item at the
  committed watermark beside its cursor. `completed` entries carry it, `checkpoint()`
  advances it over the contiguous prefix exactly as it advances the cursor (an item that
  finished out of order must not name the boundary), and — unlike the cursor — it is NOT
  nulled for a `resumable: "scroll"` driver: it is not a resume token, and on the platform
  that has no cursor it is the only thing the checkpoint knows about how far the run got.
  Beside it, `failed` + `failedOverflow`: every `retryableFailed` / `permanentFailed`
  sourceId, seeded from the checkpoint that was read so it survives a chain of resumes, and
  capped. The checkpoint READ now happens on every platform — a scroll-resumable driver
  skips only the cursor, because the failed set is not a resume token and this is its only
  copy. The engine stays platform-blind throughout: it persists opaque ids and reads
  nothing into them.
- `extension/src/bulk-controller.js` — the checkpoint wrapper folds in `mode` beside
  `jobId`. The arming asks `armsNotePreCheck` of the clean marker on a fresh start and of
  the CHECKPOINT on a resume, passes the watermark sourceId through as `resumeFrom`, maps
  the checkpoint's failed sourceIds to notes through `noteOfSourceId` as `excluded`, and
  disarms entirely when the checkpoint says its failed set overflowed. The disarmed log line
  no longer says "absent" about a marker it never read, and names the overflow case as its
  own.
- `extension/src/rednote-detail-client.js` — `noteOfSourceId`, the cut `knownNoteIndex`
  already made, now named once and shared with the boundary and the exclusion (a watermark
  or a failed item can be a cover's `<note_id>` or a child's `<note_id>:3`, and both name
  the same note). `arm` takes `resumeFrom` and `excluded`; `attemptNote` drops the index the
  first time it meets the boundary note, ahead of the known-set check, so that note is
  re-opened rather than skipped, and an owing note beats the index wherever it sits. Notes
  the index does skip go on counting into `skippedKnown`, so the expansion stats stay honest
  about a resume and an exclusion never reads as a skip.
- Tests: `bulk-engine.test.js` (the watermark's sourceId, a skipped item as a watermark,
  that it never runs ahead of the contiguous prefix, both failure kinds named, the set
  seeded across a chain of resumes, the cap flagging rather than truncating, and a sticky
  overflow), `bulk-controller.test.js` (a resume arms up to its watermark; a mode-less
  checkpoint arms nothing; a cover-mode checkpoint does not arm an expansion resume; failed
  ids reach the expander as notes; an overflowed set disarms; a pre-509 checkpoint excludes
  nothing; every checkpoint records its mode; a fresh start passes no boundary),
  `rednote-detail-client.test.js` (the watermark note is re-opened, a cover watermark names
  its note, the index is DROPPED rather than stepped over, a boundary the walk never meets,
  an owing note re-opened in front of the boundary, an exclusion with no armed index, and
  `noteOfSourceId` itself), and `bulk-rednote-integration.test.js` (the halted scroll-source
  checkpoint keeps its sourceId beside its null cursor).

## Migration notes

None. Extension-only: no schema, no route, no wire change. A checkpoint written by the
previous build has no `mode`, no `sourceId` and no `failed` list, and reads as UNKNOWN —
such a resume full-walks, which is exactly what it did before. The first sweep after upgrade
writes all three.

## What this leaves

**A boundary the walk never reaches leaves the index armed for the rest of the walk** — the
note was deleted, or the board reordered under the resume. That is accepted, and the
reasoning is written where `arm` takes the parameter: what the boundary guards is a note the
halt left half-expanded, and a note with no landed child is not in the index in the first
place, so it cannot be wrongly skipped however far the walk runs. What survives is the
residual R14 already names and already accepts — a note an EARLIER run expanded partially —
and the answer to that is unchanged: a fresh sweep arms only after a clean completion.

**A resume is not asked whether the run before it was clean**, and that is deliberate rather
than an omission. A blunt "no failures" gate would read the checkpoint's counts and disarm
on any stray — which would disarm on an app-unreachable or auth-wall halt, both of which
record a `retryableFailed` BY CONSTRUCTION. That is most resumable halts there are, so the
gate would switch the pre-check off on exactly the runs it exists to serve. The failed set
is the precise form of the same rule: not "something failed, distrust everything", but
"these notes failed, re-open those".

**An exclusion is never dropped once it is in the set**, even after the item lands. A
resumed run that re-opens the note and ingests the missing image keeps carrying the id for
the rest of the resume chain, because the re-ingest the rule would key off cannot happen a
second time — the known-set covers it by then. The cost is one re-opened note per resume for
a note that no longer owes anything, and any clean completion clears the checkpoint and the
whole set with it.

**A note that never landed a SINGLE image is still invisible to all of this.** It is not in
the known-set, so the index cannot skip it and nothing has to exclude it. That is the happy
version of the same asymmetry — and the one thing that would sharpen the rest is the app
knowing which notes are COMPLETE rather than merely started, which is a fact only the app's
ledger could hold.
