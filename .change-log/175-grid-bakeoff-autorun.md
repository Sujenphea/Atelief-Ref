# 175 — Grid bake-off headless autorun + two harness fixes

## Summary

Adds launch-argument automation to the 037 bake-off harness so the full matrix
(5 configurations × 2 scales × cold/warm × repeats) can be scripted, and fixes
two harness defects that made an unattended run impossible — and that would have
silently produced wrong or missing numbers.

**Autorun.** `-grid-bakeoff-autorun mode=<m>,wrappers=<w>,duration=<s>,repeats=<n>,out=<path>[,screen=<i>]`
runs the scripted scroll `n` times in one launch (run 1 cold, 2+ warm), writes a
self-describing JSON envelope, and exits with a meaningful code
(`0` success, `64` bad arguments, `65` no Bakeoff collection, `66` no scroll
target, `67` zero frames, `68` write failed). Without the flag the interactive
window behaves exactly as before.

**Controlled window size (037 §3.3).** The window is now a fixed 1100×820
content rect, non-resizable under autorun, and placed on an explicitly chosen
`NSScreen` instead of wherever `center()` lands it. Window size sets the visible
cell count — the independent variable the protocol requires held constant — and
the display sets the refresh period `P`, which IS the §4 threshold.

**Provenance in every export.** Build configuration, mode, wrappers, library
root, item count, duration, repeats, window + viewport size, screen name /
refresh / backing scale, machine, OS version, per-run cold/warm and verdict, the
full `FrameTimeStats`, and every raw frame interval. A run that cannot be
audited from its own file is useless; the raw intervals additionally let any
percentile or `P`-relative count be recomputed without re-running the matrix.

## Fixes

- **`loadBakeoffCollection` hung forever.** It awaited `model.$isReady.values`,
  and an `AsyncPublisher` that has already passed the awaited value never
  delivers it again. Replaced both waits with bounded polling of the state.
  The collection load is also re-issued until it sticks: `bootstrap()` loads
  Unsorted on its own schedule and `loadContents` discards any load older than
  the newest, so a Bakeoff load requested just before it was silently dropped.
- **SwiftUI modes registered a zero-height scroll target.** Both memoize their
  masonry layout under a constant version (correct — the item set is fixed for a
  run), so a grid that first laid out while the collection was still loading
  cached a zero-height layout and never recomputed. `contentHeight` stayed at
  the viewport, the driver had no travel, and the run aborted with "no scroll
  target". Interactive use hid this because switching the picker after the load
  forces a new identity; an automated launch does not. The grid's `.id` now
  includes the item count.
- A 1.5s settle after the last measured ramp (strictly after every sampled
  frame) so the AppKit mode's 2Hz idle poll can publish its scroll-tick and
  cell-restock counters — without it the process exited before the only
  available evidence that the scripted scroll actually moved the collection
  view was ever printed.

## Files changed

- `AtelierRefs/AtelierRefs/Debug/BakeoffAutorun.swift` — new; argument parsing,
  exit codes, export envelope, environment capture.
- `AtelierRefs/AtelierRefs/Debug/GridBakeoffWindow.swift` — fixed window size and
  screen placement, autorun sequence, JSON export with sandbox-tmp fallback,
  stderr progress tracing, the two fixes above.

## Notes / gotchas

- **The app is sandboxed**, so `out=` outside the container fails with EPERM.
  The export falls back to the container's `tmp` and prints `RESULTS=<real path>`
  on stdout; a driving script should collect from there.
- Run wall-clock is not the requested duration. The driver integrates each
  frame's NOMINAL duration, so every mode is sampled over the same ~600 frames
  and the same scroll distance, but a janky mode's ramp takes longer in real
  time (10s requested → up to 21s observed).
- Scroll VELOCITY is not constant across scales: the ramp covers full travel in
  a fixed duration, so 2000 items scrolls ~9.8× faster than 200
  (15095 vs 1533 pt/s). Mode comparisons within a scale are valid; comparisons
  ACROSS scales are not like-for-like.

## Migration notes

None. Additive; the interactive harness path is unchanged.
