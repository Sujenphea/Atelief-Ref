# 481 — the wheel, the cell, and the rhythm

[099 · P12](../.docs/099-mac-backlog-plan.md) is four backlog lines about Spaces. Three
are built here. The fourth is reported, because the two docs the plan sent this phase to
read do not define the thing it asked for — and the plan said, in advance and
deliberately, to report rather than invent when that happened.

The phase opened by settling the question 099 · P12 itself flagged as open, and the
answer decided the shape of everything after it.

## The `reflowGrid` verdict: it is NOT the uniform grid arrange

099 · P12 said the phase should verify *"whether `CanvasArrange.Operation.reflowGrid` is
already this and, if it is, closes the backlog line; if not, adds `.arrangeGrid`."*

It is not, and the codebase says so in its own words at three places.

1. **[076](../.docs/076-spaces-tidy-wraps-plan.md) defines the term, and defines two
   readings of it.** Its "What 'uniform grid' should mean" section says the request is
   ambiguous between *"wrapped rows preserving each tile's size"* and *"a **true**
   uniform grid — every tile forced to one cell size"*, calls the second **"a *different
   verb*"**, and says that if it is wanted *"it belongs beside Tidy in the spacing group
   (`SpaceArrangeGroups.swift`) as **'Grid'**"*. It was scheduled as T3 and left unbuilt:
   076's own status block records open question 3 as *"deliberately deferred pending use
   of the fixed Tidy."*
2. **`reflowGrid` is the FIRST reading, and its implementation says so.** It normalises
   every tile to `gridRowHeight` (240) and derives each width from the tile's own aspect
   — `width: gridRowHeight * max(aspect, 0.01)`. Cells are equal in height and unequal in
   width. That is justified rows, which is what 076 called the reading that is *not* a
   true uniform grid.
3. **[351](351-reflow-into-grid.md) chose reflow's icon to mark the difference.** Its
   glyph is `rectangle.grid.2x2` rather than tidy's squares, and the reason given in
   `SpaceArrangeSymbols` is: *"A grid of RECTANGLES against tidy's squares … **the uneven
   cells are the distinction**, not decoration."* The op that shipped knew it was not the
   even-cell one.

P12's own parenthesis — *"equal cells, `SpaceSpacingPopover`'s gap"* — is 076's second
reading exactly. So the backlog line does not close: `.arrangeGrid` was added, and it is
076's T3 arriving three docs later.

## What `.arrangeGrid` is, and the two decisions behind it

Every tile becomes one `gridCellSide × gridCellSide` square — 240, the same number as
`gridRowHeight`, so an arranged block and a reflowed one share a row pitch. The aspect is
discarded, which 076 called destructive and which is the point; ⌘Z is one keystroke away.

**The column count is `ceil(√n)` — read off the COUNT, not the geometry.** Tidy derives a
wrap bound from total area and reflow re-derives it from the *resized* rects, and both
needed a paragraph of argument to show the bound survives its own output ([342], [351]).
Here there is nothing to stabilise: `n` does not change under the op, so the grid's shape
cannot either, and idempotence stops being an argument and becomes arithmetic. Square-ish
rather than 16:9 because the cells are square, so a square block wastes the least screen.

**The gap is the panel's, not a constant** — which is why the op is offered from
`SpaceSpacingPopover` rather than from the bar's flat op list. `CanvasArrange.Operation`
is `CaseIterable` and a case carrying an associated value cannot be, which is the exact
reason [066](../.docs/066-spaces-gap-arrange-plan.md) gave for keeping `pack` out of the
enum. This takes the middle road pack could not: it **is** a case — so it has an
`actionName` for the ⌘Z menu, a `minimumCount` the panel gates on, a place in
`SpaceBarGroup.spacing`, and all four `allCases` kernel invariants — and it **also** has
`CanvasArrange.uniformGrid(_:gap:)`, a static the model calls with the user's number.
`apply(.arrangeGrid, to:)` delegates to the same function at the default gap, and a test
asserts the two paths agree so they cannot drift into two algorithms.

Idempotence falls out in three steps the doc comment spells out: after one pass every
rect is exactly one cell, so pass two's resize is the identity; `n` is unchanged, so the
column count is; and `tidyRows` over the output re-clusters exactly the rows just laid
out, because a row's members share a top edge, the band is one cell tall, and the next row
starts at `+ side + gap` — at or below the band's bottom, so never inside it, even at
`gap == 0`.

### The invariant that had to be narrowed, again

`CanvasArrangeTests.preservesCountAndSize` ran count *and* size over `allCases`, with
`.reflowGrid` already excluded by name. `.arrangeGrid` joins it, with the comment saying
how the two exclusions differ — reflow keeps the aspect, this discards it. **The
invariant was not weakened for the other nine**: "an op moves an origin and nothing else"
is still asserted of them. What each grid op *does* preserve is asserted positively in
`CanvasTidyPackTests` — reflow's aspect, arrangeGrid's uniform cell, and both their
counts. The other three `allCases` invariants (idempotence, no-op below the minimum, the
`minimumCount`/`isDistribute` split) pick the new case up unchanged, and
`SpaceBarModeTests.groupsPartitionEveryOp` required it to land in exactly one group.

## ⌘-wheel zooms about the cursor

`scrollWheel` existed and did one thing: `engine.pan(byScreenDelta:)`. It read no
modifier and never zoomed. Now a bare wheel still pans, byte for byte, and ⌘-wheel zooms
about the cursor.

**It goes through the pinch's bracket, and that is the load-bearing part.** The three
engine calls `magnify(with:)` uses — `beginZoomGesture` / `updateZoomGesture` /
`endZoomGesture` — freeze the LOD tier while the gesture is open, so a sweep re-lays the
layers it already has and asks for its sharper thumbnails once, at settle. Calling
`engine.zoom(by:aroundScreenPoint:)` per event instead would request a decode and cancel
it on the next event, which is exactly the cost [086](../.docs/086-canvas-pinch-smoothing-plan.md)
measured and removed from the pinch. The phase switch mirrors `magnify`'s case for case,
implicit `.began` included, because a wheel gesture has the same shape and the two
drifting apart is how one of them would quietly stop freezing.

**Where they differ is the `default` branch, and it had to.** `magnify`'s falls back to a
bare, unbracketed zoom. A mouse wheel reports no phase at all, so one notch *is* the whole
gesture — `zoomDiscretely` brackets it as one, without starting a `CADisplayLink` there
is nothing to coalesce for. A notch therefore costs one commit, one re-tier and one camera
notification, and a test asserts all three.

**The factor is exponential, not linear, and that is the other load-bearing choice.**
Zoom composes by multiplication — `CanvasZoomGesture.accumulate` takes a product — so the
only rule under which scrolling up by `d` and back down by `d` returns to the scale you
started at is `f(−d) == 1/f(d)`. `exp` gives that; `1 + kd` does not, and
`(1+k)(1−k) = 1 − k²` drifts smaller on every up-down pair — invisible per event, obvious
after a minute of fiddling. `oppositeDeltasCancelExactly` is the test that fails if anyone
rewrites it linearly.

Trackpad points and mouse-wheel lines get different exponents (0.01 and 0.05), because
precise deltas arrive in the tens per event and lines one to three per notch; sharing one
number would make one of the two devices unusable. A non-finite delta yields a factor of
exactly 1, and an absurd one is clamped to ~5× per event — `exp(10_000 × 0.01)` is `+inf`,
and `accumulate` silently discards a non-finite factor, so without the clamp a spurious
hardware event would zoom by *nothing*, which is the one outcome a user cannot explain.

The decision itself is a pure function — `CanvasZoomGesture.scrollIntent(commandHeld:…)`
returning `.pan` or `.zoom` — for 086's reason: a `swift test` process cannot synthesize an
`NSEvent`, so anything reachable only through `scrollWheel(with:)` could only be checked
by hand. `scrollWheel` is now a switch with nothing in it left to get wrong.

## Equal-spacing snapping, and why it is a fallback

While dragging, a guide when the moved tile's gap to a neighbour equals that neighbour's
gap to the next one along. `CanvasSnapping.bestEqualSpacing` is the candidate; `SnapGuide`
gained a `Kind` (`.alignment` / `.equalSpacing`), **defaulted to `.alignment`** so every
062-era call site and every test that spells a guide out keeps meaning what it meant.

The rule, on one axis: take the static boxes that share a band with the moving one, order
them, and look at each **adjacent** pair `(P, Q)` with a real gap `g`. Two positions
continue that rhythm — the moving box's leading edge at `Q.max + g`, or its trailing edge
at `P.min − g`. Nearest within the threshold wins.

Three constraints, each with a test that fails without it:

- **Adjacent pairs, not all pairs.** Every pair would offer the distance between two boxes
  with a third sitting in it — not a gap anybody can see, so a snap to it would look like
  the drag catching on nothing. `onlyAdjacentPairsCount` builds exactly that phantom and
  asserts it is refused while the real adjacent rhythm still fires. It is also O(n log n)
  rather than O(n²).
- **A shared band is required.** Two tiles at opposite ends of the board have a horizontal
  gap arithmetically and not one anybody is looking at. Cross-axis overlap is what makes
  "these three are a row" true, and it is the same rule `tidyRows` uses on the app side.
  `rhythmNeedsASharedBand` is the test.
- **It is a fallback and never a competitor.** `snapOffset` asks for it only on an axis
  where *no* alignment was in range. Alignment is the stronger claim — there is a real
  edge under the line — and the older behaviour. `alignmentOutranksEqualSpacing` puts both
  in range at once, with the rhythm nearer, and requires the alignment to win.

That last constraint is also why the 062 suites did not change: every one of them offers a
single neighbour, and a rhythm needs a pair. `oneNeighbourIsNotARun` pins that as a fact
rather than a coincidence.

An equal-spacing guide draws in the same magenta at two thirds the alpha. Same hue because
both lines mean "snapped" and a second colour would invite decoding a palette mid-drag;
weaker because the claim is weaker — an alignment guide sits on an edge that really
exists, while this one marks a position inferred from two gaps. The colour is now set on
every tick rather than at layer creation, because the guide layers are pooled and a
recycled one would otherwise keep the previous guide's alpha.

## Membership preview on moves: reported, not built

099 · P12 said to read [066](../.docs/066-spaces-gap-arrange-plan.md) and
[076](../.docs/076-spaces-tidy-wraps-plan.md) *"for what 'membership' means on a board"*
and scope the smallest visible preview — *"if the docs do not define it, the agent reports
rather than invents."*

**The docs do not define it.** 066 contains the words "membership", "preview", "contain"
and "frame" **zero times each** — the doc is about Tidy Up and an exact gap, and never
touches frames at all. 076 contains "membership" exactly once, and it means something
else entirely: *"membership is transitive overlap, not overlap with the row"* — a bug
description about `tidyRows`' row-clustering rule, which is about which laid-out row a
rect joins, not about a board relation at all. Neither doc mentions a preview of anything.

So the premise is stale in the same way P8's was. Reporting it is the deliverable. What
the phase found instead, and what a follow-up would need, is worth writing down precisely:

- **Membership IS defined — in code and in [091](091-spaces-frames-text.md), not in 066 or
  076.** `SpaceContent`'s header states it (005 open-Q1): *"Frames are group containers:
  dragging a frame carries the tiles it contains."* The one rule lives in
  `SpaceContent.groupMembers(forTileID:in:)` — every tile whose **centre** falls inside a
  frame's world rect. It is **derived, never stored**; there is no persisted member
  relation anywhere.
- **Half the preview already ships, for the other gesture.** `CanvasEngine.updateResize`
  sets `prospectiveMemberIDs` from that same rule on every tick, and
  `updateMembershipHighlights` washes those tiles in `CanvasChrome.membershipWash` — *"the
  wash over tiles a resizing frame is about to swallow"*. It is tested
  (`EngineResizeTests`, `prospectiveMembers`), and 062's comment says why it delegates:
  *"the highlight shown mid-resize and the set a later drag carries are the same answer to
  the same question, so they cannot disagree."*
- **The move gesture has no equivalent, and the asymmetry is visible.** `beginDrag`
  captures `dragGroupIDs` **once**, from the frame's rect at grab time, and `updateDrag`
  never re-asks. So dragging a frame over other tiles shows nothing, even though on the
  next drag those tiles will be carried — because membership is re-derived from the
  frame's new rect.
- **A preview would be truthful, which is the part worth confirming.** The drop writes
  placements only; the adoption is implicit and automatic. So the honest preview during a
  move is `groupMembers(forTileID:in: frameRectAtTheLiveOffset)`, and it would be the
  resize path's four lines applied at the drag's live rect.

That is a small, fully-specified follow-up. It was not built, because the plan's
instruction was explicit and because the instruction's *purpose* — do not invent a feature
from a phrase — is best served by handing back a specification rather than a guess about
which gesture, which set and which moment the line meant.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/CanvasZoomGesture.swift` — `CanvasScrollIntent`,
  `scrollIntent(commandHeld:…)`, `wheelZoomFactor(scrollDeltaY:precise:)` and the three
  exponent constants.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `scrollWheel`
  dispatches the intent; `applyWheelZoom(_:phase:anchor:)` mirrors `magnify`'s phase
  switch; `zoomDiscretely(by:aroundScreenPoint:)` brackets an unphased notch.
- `CanvasRenderer/Sources/CanvasRenderer/CanvasSnapping.swift` — `SnapGuide.Kind` with a
  defaulted initializer parameter; `bestEqualSpacing`; the per-axis fallback in
  `snapOffset`; three private edge/band helpers.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasChrome.swift` —
  `equalSpacingGuide`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — the guide layer takes
  its colour from the guide's kind, every tick (the pool recycles layers).
- `AtelierRefs/AtelierRefs/CanvasArrange.swift` — the `.arrangeGrid` case,
  `uniformGrid(_:gap:)`, `gridCellSide`, and `apply`'s doc naming two resizing ops.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `arrangeGrid(gap:)` beside `pack`, taking
  its undo name from the op rather than a literal; two comments that named reflow as the
  sole resizing op.
- `AtelierRefs/AtelierRefs/SpaceArrangeGroups.swift` — `.arrangeGrid` joins `.spacing`;
  `square.grid.2x2.dashed` as its glyph; the group tooltip names the fifth op.
- `AtelierRefs/AtelierRefs/SpaceSpacingPopover.swift` — a "Grid" section below "Reflow",
  and `onArrangeGrid`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — hands the panel's gap to the model.
- `CanvasRenderer/Tests/CanvasRendererTests/CanvasWheelZoomTests.swift` — new, 14 tests.
- `CanvasRenderer/Tests/CanvasRendererTests/CanvasSnappingTests.swift` — an
  `EqualSpacingSnappingTests` suite, 11 tests.
- `AtelierRefs/AtelierRefsTests/CanvasTidyPackTests.swift` — a uniform-grid section,
  14 tests.
- `AtelierRefs/AtelierRefsTests/SpaceArrangeTests.swift` — the model contract, 3 tests.
- `AtelierRefs/AtelierRefsTests/CanvasArrangeTests.swift` — the size half of the
  `allCases` invariant excludes the second grid op too.

## Verification

`@Test` count: **4387 → 4429**, +42 — which is exactly the 42 tests added, so nothing was
removed or renamed away. `CanvasRenderer` alone: **462 tests in 54 suites**, up from 437.

Two mutation checks, both run:

- `bestEqualSpacing` promoted from the `else if` fallback to a competitor fails
  `alignmentOutranksEqualSpacing` and only it.
- `uniformGrid`'s column count re-derived from `tidyMaxRowWidth` (reflow's
  area-derived bound) instead of `ceil(√n)` fails exactly four:
  `gridColumnsFollowTheCount`, `gridUsesTheGivenGap`, and the two model-contract tests
  `arrangeGridRoundTripsSizesAtTheGivenGap` / `arrangeGridAtANewGapIsAnEdit`, which read
  the grid's shape through the store. Notably it does **not** fail
  `gridIsStableUnderItsOwnOutput` — an area-derived bound happens to be stable once every
  cell is identical — which is why the column rule needs a test of its own rather than
  leaning on idempotence to catch it.

The gate, `./scripts/verify.sh full`:

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
  ✓ App target (Release)
  ⚠ Extension
  ✗ App target

1 stage(s) failed.
```

`⚠ Extension` is the expected staleness warning (464's two-arm split), not a failure.

**`✗ App target` is red on `cf5d501` itself, and this diff did not make it red.** That
was established rather than assumed, because "a stage the phase turned red" and "a stage
that was already red" are the same colour:

| run | failing test | duration |
|---|---|---|
| gate 1 (sibling's gate running concurrently) | `PaletteDragSourceTests.anUnloadedCollectionFeedCarriesTheSentinel` | 60.000 s |
| gate 2 (App-target stage re-run alone) | `GridReadOnlyTests.hasSelectionIsFalseWhenReadOnly` | 60.000 s |
| gate 3 (quiet machine, nothing else running) | `SwitcherNavigationTests.overlayPopsBeforeTheRouteChanges` | 60.000 s |
| **HEAD check — work stashed, tree clean at `cf5d501`** | **`SwitcherNavigationTests.overlayPopsBeforeTheRouteChanges`** | **60.000 s** |

A different test each run, every one a **bounded wait hitting the 60.000 s ceiling** —
exactly the pattern 099 recorded for P8 (*"failed a DIFFERENT set each run, every member a
bounded wait — 60.000 s hang timeouts"*) and [479](479-the-phase-that-had-already-shipped.md)
reported as *"a different timing flake each time, green in isolation."*

The last row is the one that settles it: **with this phase's work stashed and the tree
byte-identical to `cf5d501`, the stage fails on the same test at the same 60.000 s.** The
red is the branch point's, not this diff's — the P4 precedent, which pinned its blocker
the same way ("fails on `HEAD` too").

Two corroborating facts:

- **The two suites that failed in gates 1 and 2 pass in isolation** — 34 tests,
  `** TEST SUCCEEDED **`, exit 0. `anUnloadedCollectionFeedCarriesTheSentinel` is three
  synchronous lines (construct a `CollectionReadModel`, read two properties) and cannot
  legitimately take 60 seconds.
- **The starvation is visible in the timings, and it is not machine load.** In every run,
  including the clean-HEAD one with nothing else on the machine, trivial tests in the
  affected worker took 4–7.6 seconds — `AtelierRefsTests/example()`, the boilerplate
  placeholder, took **7.603 s**. Disk was 18–20 GB free throughout, so this is not
  [478](478-the-colours-learn-to-say-and.md)'s disk-pressure cause either.

**None of the three tests touches anything in this diff.** They exercise
`CollectionReadModel` / `AssetDragPayload` (P3, P6) and the switcher's navigation (P5);
this diff touches `CanvasRenderer`'s snapping, zoom, chrome and host, and the Spaces
arrange path. The stage is left red and reported rather than chased, per the phase rules.

Worth a human pass, since three of the changes are view-level and compile-only: that
`square.grid.2x2.dashed` renders on macOS 26 and reads as distinct from reflow's
`rectangle.grid.2x2` at 15pt; that the **five-section** spacing panel is not too tall now
(it was four, and `SpaceBarGroup`'s note asks that the three group panels keep matching
frames); and that the equal-spacing guide at 0.6 alpha is still legible against a light
board without reading as an alignment guide.

## Migration notes

No schema change — `arrangeGrid` writes through `setSpaceItemPlacements`, the path a drag,
a resize and every other arrange already use.

Three behaviour changes worth knowing:

- **`SnapGuide` gained a stored property.** Its memberwise initializer defaults `kind` to
  `.alignment`, so existing call sites compile and mean what they meant — but `Equatable`
  now compares it, so a test asserting `guides == [SnapGuide(isVertical:position:)]`
  against an equal-spacing guide will fail rather than pass by accident. That is the
  intent.
- **⌘-wheel is no longer a pan.** Anyone who had learned to hold ⌘ while scrolling and get
  a pan will get a zoom. This is the behaviour the backlog line asked for; the bare wheel
  is untouched.
- **`arrangeGrid` resizes text elements too**, exactly as reflow does and for the same
  reason: the kernel is identity-agnostic and sees only rects. An auto-width text box
  arranged into a 240 square keeps its stored geometry until the next restyle or resize
  re-derives it. Recorded rather than special-cased, following 351; if it becomes a
  complaint the fix is to exclude auto-sized elements from the resize half rather than
  from the op.

## What is still NOT covered

- **`App target` is still red, and this phase did not fix it.** It is red on `cf5d501`
  too (measured above), so it is inherited, not caused — but it is inherited *unfixed*,
  and it is now four phases running (473, 477, 479, this one) that have reported it
  rather than closed it. The cause is not identified here: the affected worker starves
  badly enough that a three-line synchronous test hits a 60 s ceiling, on a quiet machine
  with 18 GB free, which is neither the signing blocker (470) nor the disk pressure (478).
  Somebody has to own it; the evidence table above is the starting point.
- **The membership preview on moves is not built** — specified above, not implemented.
  The resize half still ships and the move half still shows nothing, so dragging a frame
  over tiles gives no hint that the next drag will carry them.
- **⌘-wheel momentum is a run of discrete gestures, not one.** After `.ended` closes a
  trackpad scroll's gesture, AppKit's momentum events carry no `phase`, so each is
  bracketed on its own. Every one is individually correct — frozen across its commit,
  re-tiered once — but a momentum tail pays one re-tier per event instead of one for the
  tail. Bounded and cheap; not free. Closing it needs `momentumPhase` read alongside
  `phase`, which nothing in the codebase does yet.
- **No wheel-zoom rate limiting, and no zoom bounds beyond the transform's own.**
  `CanvasTransform.zoomed` clamps to its min/max scale, so a clamped sweep is safe, but a
  very fast wheel still commits per vsync rather than being throttled further.
- **The equal-spacing guide is a LINE, not a measurement.** Figma draws the two matching
  gaps with end caps and a number; this draws one line at the edge that landed. That is
  what `SnapGuide` can express, and growing it into a span is a renderer change (a guide
  would need an extent, not just a position) rather than a snapping one.
- **Equal spacing applies to MOVES only.** `updateResize` goes through `snapPoint` and
  `snapAspectFrame`, which were not touched, so a resize still snaps to edges and centres
  and never to a rhythm. P12 asked for it "while dragging" and that is where it is.
- **The candidate scan is still O(visible) per drag tick**, sorted per axis per tick. That
  is the same bound `dragSnapCandidates` already had, and P14's spatial index is the phase
  that changes it — deliberately not pre-empted here.
- **`.arrangeGrid` is reachable only from the spacing popover**, not from a keystroke.
  `KeyMap.swift` carries no arrange bindings at all today (checked; none of the eleven ops
  has one), so adding the first would be a new pattern rather than an entry in an existing
  table, and P12 did not ask for it.
