# 039 — Grid bake-off DECISION GATE: results and verdict-per-rule

The step-4 gate of `036` §5. Re-measures `swiftUIWindowed/full` at 200 and 2000
items against the unchanged `appKit` mode, **after** Workstream C landed
(C1 pipeline `176`, C3 call-site migration `177`, C4 container menu `178`), per
the pre-registered protocol `037` §3–§4 and its thresholds. Methodology,
environment discipline and library isolation match `038` (the baseline being
re-measured against).

**This document produces evidence and the mechanical verdict-per-rule. It does
NOT make the A1–A4 call — a human does.** Read `037` §4/§5, `038`, and the `036`
§5 amended blocks ("Harness skew", "Widened after C1", "Consequence for the
gate, binding") before acting on it.

Raw JSON envelopes — every controlled variable, every run, and **every frame
interval** so any percentile is recomputable — are in `.docs/039-results/`
(32 envelopes: `gate-*.json`).

---

## 1. Environment

`MacBookPro18,3`, macOS 26.5 (25F71), **Release build** (mandatory; verified via
each envelope's `buildConfiguration=RELEASE`). Fixed **1100×852** window
(1100×660 grid viewport), **backing scale 2**, window pinned to the **built-in
"Built-in Retina Display", 60 Hz** panel → **P = 16.67 ms**. A second display
(DELL U2419H, 60 Hz) was connected but the window never landed on it (recorded
in every envelope's `screenName`). All identical to `038`.

Library isolation: the runs opened **only** `bakeoff-library` (2000 items in the
"Bakeoff" collection) and `bakeoff-library-200` (200 items), both in the app's
sandbox container `~/Library/Containers/sujenphea.AtelierRefs/…/Application
Support/`, selected via `-library-root`. Verified empirically: all 32 envelopes
record `libraryRoot ∈ {bakeoff-library, bakeoff-library-200}`, never the real
`ref-atelier`; and the real library's `library.sqlite` MD5 was **identical
before and after** the entire run (`c8b37598bf6f56306a438807e2fbb6d5`). The
user's real library was never touched.

Driver: the same headless autorun that produced `038`
(`-grid-bakeoff -grid-bakeoff-autorun mode=…,wrappers=full,duration=10,repeats=3`),
one process per launch, run 1 cold / runs 2–3 warm, 3 launches per cell →
**n=3 cold, n=6 warm**. **No UI tests were run.** Every launch exited 0.

### 1.1 Controlled variables I could NOT hold — stated plainly

Two `037` §3 variables broke, both in the **pessimistic-for-SwiftUI** direction
(they can only make the janky mode look worse, never better):

1. **Power state changed mid-session.** The machine started **on battery**
   (65%, discharging) and was **plugged in (AC) partway through**. `037` §3.6 and
   `038` require plugged-in. I therefore **re-ran the entire SwiftUI matrix on AC
   after the plug-in**, drift-controlled and interleaved (a-launch, b-launch, …),
   and treat those AC runs as the **primary dataset** (§2); the earlier battery
   runs are reported as **secondary/corroborating** (§4) and reach the same
   verdicts.
2. **Xcode was running** (the editor plus SourceKit/indexing XPC services and a
   backgrounded `make run`). `037` §3.5 wants a quiescent machine. SourceKit was
   idle at sampling and no other `AtelierRefs.app` instance was live, but I did
   not kill the user's Xcode session.

**Progressive within-session thermal/sustained-load drift (the main caveat at
200).** The **appKit anchor was Smooth on every run, cold/warm, battery/AC** —
so vsync/WindowServer/GPU throttling is ruled out. But appKit barely uses the
CPU, so it **cannot** detect CPU-clock throttling under sustained SwiftUI load.
The SwiftUI @200 numbers **degraded across the session**: the earliest
cold-machine @200 warm was p99 ≈ 37 ms / >2P ≈ 20; later AC @200 warm settled at
p99 ≈ 52 ms / >2P ≈ 26; `038` was p99 34 / >2P 8. The tight within-cell spread
of the later runs (not high variance — a stable ~52) points at a **regime shift
with cumulative runtime (heat)**, not random noise. Consequence, stated up front:
**the @200 absolute magnitudes and the @200 delta-vs-`038` are unreliable
(inflated)**; the @2000 numbers were stable across every power state and launch
order and are trustworthy. The **verdicts do not depend on this** — every SwiftUI
cell is Not smooth by a wide margin at both scales.

---

## 2. Primary results — AC (plugged in), drift-controlled interleaved

Median across runs (n=3 cold, n=6 warm). Times in ms. P = 16.67 ms.
Verdict per `037` §4: **Smooth** = p99 ≤ P and 0 frames > 2P; **Acceptable** =
p95 ≤ P and < 5 frames > 2P; else **Not smooth**.

| scale | mode / config | state | mean | p50 | p95 | p99 | worst | >P | >2P | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| 200  | windowed **(a)** as-measured | cold | 17.9 | 16.67 | 21.7 | 47.5 | 64.3 | 39 | 20 | **Not smooth** |
| 200  | windowed **(a)** as-measured | warm | 18.1 | 16.67 | 24.6 | 51.7 | 57.7 | 42 | 26 | **Not smooth** |
| 200  | windowed **(b)** buckets | cold | 18.2 | 16.67 | 24.7 | 48.9 | 72.2 | 46 | 26 | **Not smooth** |
| 200  | windowed **(b)** buckets | warm | 18.1 | 16.67 | 26.5 | 52.6 | 55.6 | 40 | 27 | **Not smooth** |
| 200  | **appKit** (reference) | warm | 16.67 | 16.67 | 16.67 | 16.67 | 16.67 | 0 | 0 | **Smooth** |
| 2000 | windowed **(a)** as-measured | cold | 31.1 | 23.1 | 53.9 | 62.2 | 76.0 | 427 | 234 | **Not smooth** |
| 2000 | windowed **(a)** as-measured | warm | 31.1 | 32.5 | 46.2 | 54.7 | 68.7 | 498 | 289 | **Not smooth** |
| 2000 | windowed **(b)** buckets | cold | 30.3 | 22.4 | 52.1 | 57.3 | 89.0 | 432 | 232 | **Not smooth** |
| 2000 | windowed **(b)** buckets | warm | 30.2 | 29.9 | 44.3 | 49.2 | 64.1 | 471 | 282 | **Not smooth** |
| 2000 | **appKit** (reference) | warm | 16.67 | 16.67 | 16.67 | 16.67 | 16.67 | 0 | 0 | **Smooth** |

appKit cold rows are identical to warm (one @200 cold launch logged a single
frame > P, p99 still 16.67, >2P 0 → still **Smooth**). Frame counts 599–600/run;
warm ramp wall-clock ~10.8 s @200 and ~18.6 s @2000 (the janky mode stretches
real time; frame count and travel are held constant, per `175`).

**As-measured `>16.7ms` / `>33.4ms` and mean/p50 for every individual run are in
the raw envelopes; percentiles there are recomputable from `intervalsMs`.**

---

## 3. Verdict-per-rule (applied mechanically)

- **Config (a), harness as-measured — Not smooth** at 200 and 2000. `appKit` —
  **Smooth**. This is the directly-`038`-comparable configuration.
- **Config (b), harness passing production buckets — Not smooth** at 200 and
  2000. `appKit` — **Smooth**.
- **(a) and (b) AGREE** (both Not smooth, near-identical magnitudes). So the
  `036` §5 "(b) governs / disagreement is a finding" branch does **not** fire in
  the direction of a numeric split — but see §3.1: (a)≈(b) is itself a finding,
  and not the reassuring one it looks like.

**How this must be read (binding, `036` §5).** Config (b) Not smooth means the
shipping thumbnail *size* did not rescue scroll. Per the "Widened after C1" /
"Consequence for the gate, binding" blocks, this is recorded as
**"Not smooth with C complete"** and is **NOT an automatic framework verdict**.
Reasons the gate under-states the shipping config are in §3.1–§3.2; the reason
it nonetheless does not plausibly hide a Smooth result is in §3.3. The A1–A4
decision is left to the human. **This document does not say "Option B confirmed,
start the rewrite."**

### 3.1 (a) ≈ (b) because the C3 bucket lever has NO HEADROOM at this viewport

The two configs are near-identical not because bucketing was tried and failed,
but because **at the bake-off's fixed 1100 pt / 3-column geometry every masonry
cell is ≥ 269 pt on its long side**, and `thumbnailPixelBucket(≥269 pt, scale 2)`
= ≥ 538 px, which **clamps to the 512 tier ceiling for every cell**. Config (b)
therefore requested **512 for every cell — the exact size config (a) already
used by default**. (Verified against the six cell rectangles in the AppKit
coordinate-check trace: long sides 269–403 pt → 538–807 px → bucket 512 in all
cases; the smallest possible long side at this density is the 269 pt column
width → still 512.)

So the gate's config (b), **at this window size, does not actually exercise
C3.** Bucketing pays off where cells are small (drop rail 128, stack 192, dense
sheets 256–384); a 3-column grid of 269 pt cells already sits at the ceiling.
Config (a) is thus already the correct shipping thumbnail size (512) for this
geometry, and it is Not smooth. **The gate cannot answer "does smaller-bucket
decoding reach Smooth?" — there is no smaller bucket to request here.** A future
gate that wanted to test C3 would have to widen the window / raise the column
count so cells fall below the 512 tier.

### 3.2 The gate also does not reflect C4 (the harness keeps the per-cell menu)

C4 (`178`) removed production's eager per-cell `.contextMenu` in favour of one
container-level menu. The harness's `SwiftUIWindowedBakeoffGrid` still attaches
`BakeoffCellFidelity.cellMenu` **per cell** (only the bucket edit was permitted,
`036` §5). `038` §3.3 measured the per-cell wrappers — the context menu among
them — as the **largest** SwiftUI-side effect. So the gate measures **C1 only**
in practice (off-main decode, inherited by both configs via the real
`CollectionCell`), and neither **C3** (§3.1, no headroom) nor **C4** (retained
per-cell menu). Both omissions push the gate **conservative** — production ships
strictly less per-cell work than the harness pays.

### 3.3 Why Not-smooth is nonetheless robust to those omissions

`038` already measured the **wrappers-fully-stripped** SwiftUI ceiling — no
drag, drop, context menu or hover at all, which removes **more** than C4 does —
and it was **still Not smooth** at both scales (2000 warm p99 34.7 / >2P 8;
200 warm p99 33.3 / >2P 7; Smooth needs p99 ≤ 16.67). Since C4 removes only the
menu (a subset of "all wrappers"), config (b) + C4 would land **between** config
(b) and that stripped ceiling — and the stripped ceiling is itself Not smooth.
The omitted C3/C4 levers therefore **cannot** carry SwiftUI to Smooth here.
"Not smooth with C complete" stands; what it is *not* is a clean isolation of
framework-vs-content, for the reasons above.

---

## 4. Secondary results — battery (exploratory, early session)

Same code, same libraries, before the plug-in. Reported for corroboration; same
verdicts throughout.

| scale | config | state | p95 | p99 | worst | >P | >2P | verdict |
|---|---|---|---|---|---|---|---|---|
| 200  | (a) | warm | 16.67 | 37.0 | 51.1 | 29 | 20 | Not smooth |
| 200  | (b) | warm | 24.0 | 52.8 | 55.5 | 35 | 26 | Not smooth |
| 2000 | (a) | warm | 55.1 | 57.6 | 61.2 | 421 | 284 | Not smooth |
| 2000 | (b) | warm | 55.2 | 58.0 | 61.1 | 424 | 284 | Not smooth |
| 200/2000 | appKit | warm | 16.67 | 16.67 | 16.67 | 0 | 0 | Smooth |

The one place battery vs AC visibly diverges is @200 config (a) warm
(battery p99 37 / >2P 20 vs AC p99 52 / >2P 26) — the thermal-drift regime shift
of §1.1, not a power-direction effect (AC "faster" would predict the opposite).
@2000 is flat across power states.

---

## 5. Delta against `038` (the "did C improve it?" question)

`038` windowed/full warm medians vs this gate (AC config (a), the comparable
cell):

| scale | metric | `038` (pre-C) | gate (a) AC | change |
|---|---|---|---|---|
| 2000 | p99 | 60.3 | 54.7 | −9 % |
| 2000 | worst | 97.7 | 68.7 | −30 % |
| 2000 | >2P | 314 | 289 | −8 % |
| 2000 | verdict | Not smooth | Not smooth | unchanged |
| 200 | p99 | 34.2 | 51.7 | +51 % (see caveat) |
| 200 | >2P | 8 | 26 | +225 % (see caveat) |
| 200 | verdict | Not smooth | Not smooth | unchanged |

- **@2000: marginal improvement, same verdict.** C shaved the worst frame and a
  little off the tail (consistent with C1 moving ~0.9 ms/newly-visible-cell of
  decode off main, `176`), but did not change the order of magnitude or the
  verdict. This matches the `036` §5 "Widened after C1" prediction that C1 is a
  contributor, not the whole story.
- **@200: apparently worse, but this is the §1.1 thermal-drift artifact, not a
  regression.** The earliest cold-machine @200 warm (p99 37 / >2P 20) is much
  closer to `038`; the number inflated as the session went on. **Do not read a C
  regression into the @200 row** — read it as "@200 could not be measured
  cleanly this session." The honest @200 statement is: **C shows no improvement
  over `038` at 200, and the absolute magnitude is contaminated.**

Net: **C (as the gate can see it — effectively C1 only, §3.1–§3.2) did not
materially move SwiftUI scroll smoothness at either scale, and did not approach
Smooth.**

---

## 6. Caveats, consolidated

1. **Power state changed mid-session** (battery → AC); primary dataset is the
   post-plug-in AC re-run. Skew direction: pessimistic for SwiftUI.
2. **Within-session thermal/sustained-load drift** inflated the @200 SwiftUI
   magnitudes (§1.1); @200 delta-vs-`038` is unreliable, @2000 is stable.
   appKit's perfect anchor rules out vsync/GPU throttling but not CPU-clock
   throttling (appKit does not stress the CPU).
3. **Xcode running** (SourceKit idle at sampling); not fully quiescent per §3.5.
4. **Config (b) does not actually exercise C3** at the harness's 3-column
   geometry — every cell clamps to the 512 ceiling, so (b) requested the same
   sizes as (a) (§3.1). (a)≈(b) is expected, not informative about bucketing.
5. **The harness reflects C1 but not C3 (no headroom) or C4 (retained per-cell
   menu)** (§3.2). The gate is conservative; `038`'s stripped ceiling bounds the
   best case and it is still Not smooth (§3.3).
6. **Cross-scale comparison is not like-for-like** (`038` §7): fixed-duration
   full travel means 2000 scrolls ~9.8× faster than 200. Compare within a scale.
7. **The config-(b) harness edit** was **two lines** in
   `AtelierRefs/AtelierRefs/Debug/SwiftUIWindowedBakeoffGrid.swift`, config-(b)
   build only: one `@Environment(\.displayScale)` stored property and one
   `bucket:` argument on the measured `.full` cell (placed after `gifURL:` to
   satisfy `CollectionCell`'s init order), value
   `thumbnailPixelBucket(pointLongSide: max(frame.width, frame.height), scale:
   displayScale)`. The `.stripped` control and the `appKit` reference were
   untouched. Config (a) was built from the file byte-identical to `038`, and
   **the edit was reverted after the run** — the committed harness stays
   byte-identical to `038` (canonical config (a)); this two-line diff is the
   record needed to reproduce config (b).

---

## 7. Single clearest sentence, framed as evidence

**With Workstream C landed, the SwiftUI grid is still Not smooth at 200 and 2000
items while the AppKit `NSCollectionView` reference is perfectly Smooth
(0 missed vsyncs) — but at this bake-off's geometry the gate effectively
exercised only C1 (C3 has no bucket headroom, C4 is not reflected in the
harness), so this is evidence of "Not smooth with C complete," not a clean
framework verdict; the A1–A4 go/no-go remains a human call, informed by `038`'s
already-measured result that even a fully-wrapper-stripped SwiftUI cell — a
better case than C4 delivers — did not reach Smooth either.**

> `036` plan-of-record is unchanged beyond this pointer; the human makes the
> A1–A4 call.
