# 464 — the gate tells its two arms apart

P0 ran `./scripts/verify.sh full` — the first time anything on this branch had — and
found the Extension stage red. It had been red since **2026-08-28**, and nothing in the
repo had noticed, because `fast` mode has eleven stages and `full` has twelve: the
Extension stage is the one `fast` skips, and `fast` is what everyone runs.

The stage was red for a reason no commit could clear. `drift-check.js` ended in

```js
process.exit(failed || stale ? 1 : 0);
```

and those two variables mean unrelated things. `failed` is drift: a parser disagrees with
a committed fixture, or the extension's host table disagrees with the phone's. A code
change fixes it, and the whole file exists to catch it. `stale` is a calendar fact: the
Instagram fixture was captured on 2026-08-14 with a 14-day window, so on 2026-08-28 it
aged out. Only a fresh capture from a logged-in session clears that, so no automated run
ever can.

Sharing one exit code, the second permanently masked the first. The run P0 hit printed

```
✔ Instagram saved feed (committed fixture) — posts=3 items=4 videos=3 endOfFeed=false
No drift — every check that COULD run satisfied its invariants.
```

and then exited 1. A gate that reports "no drift" and fails anyway teaches its readers to
ignore it, which is exactly the state a drift canary must never reach — and with twenty
phases still to run, every one of them would have reported the same known failure, and a
real regression in the extension would have arrived inside that noise.

## What changed

**`drift-check.js` splits the codes.** `1` is drift and always fatal. `2` is staleness and
never fatal. Drift wins when both hold, because the actionable signal is the one worth
surfacing. The reminder text is unchanged and still prints in full.

**`verify.sh` learns one new concept, narrowly.** A `WARN_STATUS=2` and a
`run_warnable_stage` that buckets into a third list, `WARNED`, rendered `⚠` in the summary.
The opt-in is per stage and only the Extension stage takes it: a plain `run_stage` still
treats every non-zero exit as a failure, so a tool that happens to exit 2 for its own
reasons cannot have a real error quietly downgraded. `extension_tests` stops using `&&`
and passes drift-check's code through untouched, with the node suite still a hard failure
above it.

The summary gained a line for the case that now exists — all stages passed, some with a
warning — so a warned run reads differently from a clean one at a glance, and the script
still exits 0.

## Why not the other two

Re-capturing the fixture was the obvious move and is not a fix: it resets a 14-day clock,
and the phases ahead do not fit in fourteen days. It remains worth doing on its own merits
— the fixture really is stale and live Instagram sweeps really may be broken — but as
maintenance, not as a gate repair. Widening the window to 30d would have gone green in one
line and put a false number in the data: the 14 is deliberate and `drift-check.js:116`
says why (Instagram drifts faster than X and Pinterest). The window is still 14. What
changed is what the repo does when it lapses.

## Verified

The exit arms were exercised directly rather than reasoned about:

- **stale only** → `2`, both from `node scripts/drift-check.js` and through
  `npm run drift-check` (npm propagates the code rather than collapsing it to 1 — checked,
  because the whole design rests on it).
- **drift, while also stale** → `1`, forced by making a fixture unreadable. This is the
  precedence test as well as the drift test: staleness was true throughout and did not win.
- **the fixture restored** → `git diff --stat test/fixtures/` empty.

`./scripts/verify.sh full` now reports:

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ CanvasRenderer
  ✓ AtelierExport
  ✓ App target
  ⚠ Extension

All 12 stages passed, 1 with a warning above.
```

Exit 0. Twelve stages, not eleven — the count is the point: the stage still runs, still
prints the staleness reminder in full, and no longer stops the gate.

One caveat on this run, stated because the two commits are separate and the run was not.
The tree carried **both** this change and P0's uncommitted work, so what is verified above
is the pair. 17A was not run against a tree without P0 in it.

## What this found and did not fix

Forcing the drift arm turned up a **gap in the Instagram check itself**: emptying every
`items` and `edges` array in `instagram-saved-live.json` produced

```
✔ Instagram saved feed (committed fixture) — posts=0 items=0 videos=0 endOfFeed=false
```

A pass, on a fixture with nothing in it. The check reports its counts as signals but
asserts nothing about them being non-zero, so a fixture that a future re-capture truncates
— an expired session returning an empty feed is the ordinary way this happens — would be
committed and pass. The other checks were not probed for the same hole and may share it.
This is left for **P11**, the phase that owns `extension/`, and is recorded here because
the probe that found it belongs to this entry.

## What is still NOT covered

The staleness warning is now a warning, which is the point and also the risk: nothing
forces the fixture to be re-captured, and the repo's only pressure is the line in the
summary. If that line stops being read, the fixture rots exactly as before — the failure
mode moved from "a gate nobody can pass" to "a warning nobody reads", and only the second
one is survivable.

Nothing verifies that the live Instagram route still matches the stale fixture; the
canary's whole claim is about the committed fixture, and it says so. The `2` convention is
known to `drift-check.js` and `verify.sh` and to nothing else — `ci.yml` is untouched
(decision 9C) and would still read a stale fixture as a failure if it ever ran again. No
test covers `verify.sh` itself; it has none, and this entry did not add the harness that
would be needed.
