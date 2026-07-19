# 037 — Grid bake-off: measurement protocol and pre-registered decision rule

Written BEFORE any measurement exists, deliberately. `036` committed to a 1–2
week `NSCollectionView` rewrite (035 Option B) over the half-day equatable-cell
fix (035 Option A), on the strength of profiling taken at **under 200 items**
for a workload targeting **2000**. This document fixes the thresholds and the
decision rule in advance so the outcome can't be rationalised after the fact.

Companion to `035-grid-scroll-perf-research.md` (the original profiling) and
`036-grid-smooth-plan.md` (the plan under test).

## 1. What is actually being decided

**Is the SwiftUI grid structurally incapable of smooth scrolling at 2000 items,
or is it just carrying avoidable per-cell cost?**

If the latter, Option A fixes it for half a day and Workstream A1–A4 (~9 days)
is moot. That is the only question this bake-off answers. It does NOT evaluate
the detail-view work (Workstream B) or the thumbnail pipeline (Workstream C),
both of which stand on their own.

## 2. The confound that would have invalidated this

The naive bake-off is **apples to oranges** and would have unfairly favoured
AppKit:

- The SwiftUI grid's per-cell tree carries `.draggable` (incl. `dragPreview`),
  `.dropDestination`, `.contextMenu` (incl. `cellMenu`), `.onHover`, and
  `.animation` — see `CollectionView.masonryCell`.
- 035 §4 measured exactly these as the dominant residual: `dragPreview` 230ms
  and `cellMenu` 122ms per 20s, on top of `masonryCell` 763ms.
- The A1 spike is specified as **read-only** — no selection, no drag, no menu.

Comparing a fully-wrapped SwiftUI cell against a bare AppKit cell measures the
wrappers, not the framework, and would "prove" AppKit wins regardless of truth.

**Correction — each SwiftUI mode is measured in two configurations:**

| Config | Wrappers | Answers |
|---|---|---|
| `full` | production `.draggable`/`.dropDestination`/`.contextMenu`/`.onHover` | the real-world number today |
| `stripped` | none | the substrate number, comparable to the AppKit spike |

This yields a third possible finding, invisible to the naive design: if
`stripped` SwiftUI ≈ AppKit but `full` SwiftUI is far worse, then the cost is
the **eager per-cell wrappers**, and the cheap fix is deferring them
(`.contextMenu` built lazily, drag registered on press) — not a framework
rewrite. That outcome would make A1–A4 moot for a reason 036 never considered.

## 3. Controlled variables

Any of these silently invalidates a run:

1. **Release build, not Debug.** SwiftUI body evaluation and `ForEach` diffing
   are dramatically slower unoptimised; a Debug measurement would unfairly damn
   SwiftUI and is the single most likely way to reach a wrong conclusion.
2. **Cache state.** Each mode runs twice — cold (fresh launch, empty thumbnail
   cache) and warm (immediately repeated). Both reported. Cold exercises the
   decode path; warm isolates layout/render.
3. **Fixed window size**, identical across modes — window size sets the visible
   cell count, which is the independent variable being controlled.
4. **Identical scroll ramp** — same duration, same constant velocity, same
   start/end offset, driven programmatically. Never hand-scrolled.
5. **Quiescent machine** — no concurrent `xcodebuild`, no Xcode indexing, no
   orphaned app instances (one was found running 23h during the merge).
6. **Power state** — plugged in, and note whether the display is ProMotion, as
   adaptive refresh changes the frame budget.
7. **Same seeded collection** — the 2000-item "Bakeoff" set, identical items and
   aspect ratios for every mode.

## 4. Metric and thresholds

Frame intervals sampled via display link over the scroll ramp. Let `P` be the
display's refresh period (8.33ms at 120Hz, 16.7ms at 60Hz) — thresholds are
expressed relative to `P` rather than absolute, so ProMotion doesn't skew them.

| Verdict | Criteria |
|---|---|
| **Smooth** | p99 ≤ `P`, zero frames > `2P` |
| **Acceptable** | p95 ≤ `P`, fewer than 5 frames > `2P` |
| **Not smooth** | anything worse |

Reported per run: frame count, duration, mean, p50, p95, p99, longest frame,
count > `P`, count > `2P`.

Rationale for hitch counts over averages: 035 §4 characterises the residual as
"a periodic per-screenful hitch rather than continuous lag". A mean would hide
exactly the artifact under investigation; the band-crossing hitch lives in the
tail.

## 5. Pre-registered decision rule

Fixed now, applied mechanically to the numbers:

| Option A (`full`) | AppKit spike | Decision |
|---|---|---|
| Smooth | — | **Ship A. Drop A1–A4.** ~9 days saved; B unnecessary at target scale. |
| Acceptable | Smooth | **Ship A now**, revisit B only if 2000 proves to be the floor rather than the ceiling. |
| Not smooth | Smooth | **Option B confirmed.** Proceed with A1–A4 as planned, now with evidence. |
| Not smooth | Not smooth | **Neither is the fix.** Bottleneck is cell content or thumbnail decode → do Workstream C first, re-measure before any grid rewrite. |

Additional rule from §2: if `stripped` SwiftUI is Smooth while `full` SwiftUI is
not, and the gap is comparable to the AppKit spike's advantage, the finding is
**"defer the per-cell wrappers"** — a days-not-weeks fix — and A1–A4 stays
unjustified regardless of the spike's absolute numbers.

## 6. Scope limits, stated honestly

- The AppKit spike is read-only. A favourable spike number is an **upper bound**
  on Option B, not a delivered result — selection, drag, drop, context menu,
  marquee, and GIF hover all still have to be built (A2/A3) and each adds cost
  back. The spike proves the ceiling, never the shipping number.
- 2000 items is the stated target. If the real ceiling is 10k, the rule above
  changes and the bake-off should be re-run at that count before deciding.
- Frame time measures the scroll path only. Multi-select smoothness (root cause
  2) and detail open/step/close (root cause 3) are separate measurements and are
  not decided here.
