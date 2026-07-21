# 179 — Grid bake-off DECISION GATE (036 §5 step 4)

Re-ran the `037` bake-off after Workstream C (C1 `176` / C3 `177` / C4 `178`) to
decide whether the SwiftUI grid now reaches Smooth or the AppKit rewrite
(A1–A4) is warranted. **Evidence + mechanical verdict-per-rule only — the A1–A4
call is left to a human, per `036` §5's binding blocks.**

## Summary

- **`swiftUIWindowed/full` is Not smooth at 200 and 2000** in both configs;
  **`appKit` is perfectly Smooth** (0 missed vsyncs). P = 16.67 ms (60 Hz).
- Two configs, both reported: **(a)** harness as-measured (byte-identical to
  `038`); **(b)** harness passing production per-cell buckets. **(a) and (b)
  agree** (both Not smooth, near-identical numbers).
- **(a) ≈ (b) is a finding, not reassurance:** at the harness's 1100 pt /
  3-column geometry every masonry cell is ≥ 269 pt long-side → ≥ 538 px →
  **clamps to the 512 tier ceiling**, so config (b) requested the same size as
  (a). The **C3 bucket lever has no headroom here**, and the harness still
  carries the eager per-cell context menu (**C4 not reflected**). So the gate in
  practice exercised **C1 only**.
- Because of that, the result is recorded as **"Not smooth with C complete,"
  NOT a framework verdict**. It is not, and does not say, "start the rewrite."
- **vs `038`:** @2000 marginally better, same verdict (p99 60→55, worst 98→69,
  >2P 314→289); @200 delta is unreliable (thermal drift, below). C did not
  materially move smoothness or approach Smooth.

## Robustness

`038` already measured a **fully-wrapper-stripped** SwiftUI cell (strictly less
per-cell work than C4 delivers) as **Not smooth** at both scales. So the omitted
C3/C4 levers cannot plausibly reach Smooth; the Not-smooth verdict is robust to
them even though the gate under-states the shipping config.

## Environment / honesty

- Release build (verified per-envelope), MacBookPro18,3, macOS 26.5, window
  1100×852 on the built-in 60 Hz panel — all identical to `038`.
- **Library isolation verified:** runs opened only `bakeoff-library` (2000) and
  `bakeoff-library-200` (200) in the sandbox container; the real `ref-atelier`
  library's SQLite MD5 was unchanged before/after. Real library never touched.
- **Two controlled variables broke, both pessimistic-for-SwiftUI:** machine
  started on battery then was plugged in mid-session (primary dataset is the
  post-plug-in AC, drift-controlled interleaved re-run; battery runs corroborate);
  Xcode was running (SourceKit idle at sampling).
- **Thermal/sustained-load drift** inflated the @200 SwiftUI magnitudes across
  the session (appKit's perfect anchor rules out vsync/GPU throttling but not
  CPU-clock throttling). @2000 was stable across all conditions. Verdicts do not
  depend on the drift.
- No UI tests were run. Every launch exited 0.

## Files changed

- `.docs/039-grid-bakeoff-gate-results.md` — new; full tables (both configs,
  both scales, cold+warm), environment, verdict-per-rule, (a)-vs-(b), delta vs
  `038`, all caveats.
- `.docs/039-results/` — new; 32 raw JSON envelopes (every frame interval
  preserved, per `038`).
- `.docs/036-grid-smooth-plan.md` — §5 step 4 gets a one-line pointer to `039`;
  plan-of-record otherwise unchanged (the A1–A4 call is the human's).

**No source files changed in this commit.** The config-(b) harness edit (one
`@Environment(\.displayScale)` property + one `bucket:` arg on the measured
`.full` cell of `Debug/SwiftUIWindowedBakeoffGrid.swift`, mirroring C3's
production `masonryCell`) was applied for run (b) then **reverted**, so the
committed harness stays byte-identical to what produced `038` (canonical config
(a)). The exact two-line diff is recorded in `039` §6 caveat 7 for
reproducibility.

## Migration notes

None. No production code changed; the harness is unchanged from `038`.
