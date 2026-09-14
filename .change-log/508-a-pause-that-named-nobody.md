# 508 — a pause that named nobody

## Summary

A halted sweep told the user the one thing they already knew:

```
Paused (resumable) — 2 ingested.
```

Nothing failed. No error string existed anywhere in the result. The app had flipped
the job to `paused` underneath a healthy sweep — `classifyIngestResult`'s `saved` arm
reads `jobStatus: "paused"` off the next relay, raises `signal: "halt"` and carries
the intent out as `haltStatus`, and the engine stops on purpose. That is correct
behaviour end to end, and the only way to find it out was to read the engine's
source.

`terminalMessage` had three arms and this outcome fell through all of them. An
explicit Cancel (`haltStatus: "halted"`) gets "Stopped". A runtime halt gets
`haltReason(result)`, which renders the error the source threw — 493's feed-start
refusal, a stall, a 461. An app Pause carries no error at all, so `haltReason`
returns null and the line ended there. Its own doc comment named the case ("an app
Pause, a media auth wall") as if something downstream handled it; nothing did.

[507](507-a-sweep-that-only-breathed-when-it-spoke.md) removed the *cause* that made
this common — a sweep that relayed nothing for 90 seconds was paused by the app's
staleness reconciler, so a quiet dedup run paused itself. It did not make the
outcome unreachable, and it should not: **Pause is a button in the Sweeps tab.**
A user who presses it lands in exactly this branch, with exactly this silence.

The line it gets instead:

```
Paused (resumable) — 2 ingested. The app paused this sweep — nothing here failed.
Start the sweep again: it continues the same job and re-skips everything already
imported.
```

**The copy does not say WHICH pause it was, because the extension cannot know.** A
user pressing Pause and `IngestionModel.pauseStaleOpenJobs` (90s) both write the
same `job.status`, and the relay reply carries a status and no provenance. Guessing
would be wrong about half the time about the thing the sentence exists to state, so
it states what is on the wire — the app paused this sweep — and stops.

It ends in an action, which is this codebase's standing rule for a halt a human
reads; `RednoteFeedStartError`'s message carries the argument for it. The action is
cheap and worth saying out loud, because the silence made it look expensive: a
second run reopens the SAME job (`JobRoutes.openOrReopen` takes the checkpoint's
`resumeJobId` and accepts a `paused` one) and P14's known-set re-skips everything
already imported. The run that produced the line above had skipped 82 notes it
already had; the user had no way to know a second one would not re-download them.

**The action is Start, not the app's Resume button**, which is the answer the Sweeps
tab makes look obvious and is the wrong one. `IngestionModel.resumeSweep` is a
one-liner that sets `job.status` to `.open` and nothing else — no browser run
continues from it, because the run that halted is gone and only the popup can begin
another. And a run begun from the popup does not need it: `openOrReopen` flips the
paused job back to `.open` itself. Naming the tab would have sent the user through a
click that does nothing on the way to the one that works.

An explicit reason still wins. Both facts can be true of one result — an app Pause
racing a stall — and the error is the specific one; appending both would make a user
read a generic pause line to reach the refusal that matters.

## Files changed

- `extension/src/popup-view.js` — `APP_PAUSE_MESSAGE`, exported, and the arm in
  `terminalMessage` that falls back to it when `haltReason` is null and
  `haltStatus === "paused"`. Exported rather than inlined for the same reason the
  rednote refusal lives on its error class: one copy, so the test pins the string the
  popup renders instead of a second one that could only drift. `haltReason`'s doc
  comment no longer lists an app Pause as an unanswered null case — it points at what
  answers it.
- `extension/test/popup-view.test.js` — the app-pause branch, the precedence of an
  explicit reason over it, and three properties of the copy itself (it names the app;
  it ends in an action; it claims no particular pause) asserted against the exported
  constant, so
  rewording stays free and hollowing it out does not. The existing "reads exactly as
  it always did" case moves to `haltStatus: null` — a media auth wall, which is what
  that assertion was always about — and the Cancel and clean-`complete` arms are
  pinned unchanged beside it.

## Migration notes

None. Extension-only, no schema, no route, no wire change: the same result object
renders a longer line. A sweep that halts with an error, an explicit Cancel and a
clean completion all read exactly as they did.

## What this leaves

The distinction the copy refuses to draw is a real one, and it is absent from the
wire, not from the extension. `GET /jobs/{id}` returns a status with no note of who
set it, and the relay reply carries less than that. If the app ever recorded a pause
reason — a user's Pause against the reconciler's — this sentence is where it would
land, and it would be a better sentence for it.
