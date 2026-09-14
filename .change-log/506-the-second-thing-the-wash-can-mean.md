# 506 — the second thing the wash can mean

## Summary

P3 of [100](../.docs/100-spaces-group-frame-design.md), and the end of it: ⌘G stops
being silent about bystanders. P1 computed the tiles a new frame **adopts** —
members the user never selected, which a bounding box takes in by construction —
and P2 threw them away. This spends them.

Nothing is drawn that was not drawn before. [062] §6 already built the mechanism
for the resize gesture: a set of ids, a pool of recycled layers, and a **fill**
rather than a border, because the border idiom belongs to selection and these tiles
are not selected. 100 §5's whole argument is that ⌘G has the same defect from the
other end — membership is derived from containment, so a rect the user did not draw
by hand can quietly contain things they did not pick — and therefore deserves the
same remedy rather than a second one. So this adds a *driver*, not a highlight:
`washMembership(_:for:)` writes the same field the resize writes, and
`updateMembershipHighlights` never learns which gesture called.

Only the adopted tiles are washed. Washing the whole membership would say "here is
what is in the frame", which is what looking at the frame already tells you; washing
the adopted ones says "here is what you did not ask for", which is the only new
information the gesture produced. An empty adopted set flashes nothing, and that is
the common case rather than the degenerate one — most selections already *are* their
membership, and ⌘G on them should be as quiet as pressing `F` and dragging.

**One field, two drivers, so precedence had to be decided rather than raced.** They
can genuinely collide: raise a wash, then grab a resize handle before it lapses, and
a timer from the previous gesture is now pending inside a live one. Precedence goes
to the resize in both directions. `beginResize` retracts a standing wash on the way
in — not merely leaving the first tick to overwrite it, because between mouse-down
and the first move the old fill would still be claiming membership for a rect the
user has stopped caring about — and cancelling the pending expiry there is the
load-bearing half: left running, it would wake up mid-drag and blank a preview it
knows nothing about. In the other direction the wash simply refuses to raise while a
handle is down. The asymmetry is not arbitrary: a resize preview is a promise about
a rect the user is actively aiming, and a creation wash is a retrospective note
about one they already committed, so the live gesture outranks the report.

**1.2 seconds**, and it is the first duration this package has ever needed —
everything else in `CanvasRenderer` is either per-frame or bounded by a gesture the
user is holding, so there was no constant to reuse. It is set against two opposite
failure modes. Too short and it is missed outright: ⌘G puts a new frame on the
board, the eye goes to the frame, and an adopted tile is *by definition* somewhere
the user was not looking — the wash has to survive a saccade and a scan of the
frame's interior, not just a glance. Too long and it stops reading as a report and
starts reading as a mode, something the board is now in; a persistent fill on
unselected tiles invites exactly the question ("are those selected?") that the
fill-not-border choice exists to avoid.

The ids survive the round trip, which is the part that looked risky and is not. The
frame is written through an async `enqueue`, so the wash goes up well before the
frame lands — but the adopted tiles are not created by this operation, and
`SpaceContent.reconcile` keeps a surviving row's tile id across a reload precisely
so the renderer's state outlives a write. Nothing the enqueue does can renumber
them. The raise syncs immediately rather than waiting for that reload, so the round
trip's length cannot eat an unpredictable slice of the duration.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — the timed
  driver: `membershipWashDuration`, `washMembership(_:for:)`, the
  `membershipWashExpiry` task it can cancel, and `retractMembershipWash()` called
  from `beginResize`. The expiry checks `Task.isCancelled` *after* the sleep as well
  as relying on the sleep throwing, because a cancel racing the wake-up leaves the
  body to run with the flag already set — and by then the field belongs to whoever
  cancelled it. The retraction syncs only when something was actually drawn, so
  grabbing a handle with no wash up costs a set comparison. `prospectiveMemberIDs`'
  own comment is rewritten to describe a field with two writers and one meaning.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — a one-line
  passthrough. Imperative and one-shot, so it rides the host the app already holds
  rather than becoming a `CanvasView` closure or a piece of SwiftUI state: "show
  this now" as a value is a thing view updates keep re-asserting, and the whole
  point is that it happens once and expires.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `groupInFrame()`, which the ⌘G carrier
  now calls instead of the model directly. Reaches the host through
  `chromeAnchor.host`, the same reference `restoreCanvasFocus()` uses.
- `CanvasRenderer/Tests/CanvasRendererTests/EngineMembershipWashTests.swift` — a new
  suite. The wash raises its set and draws it, clears itself, is a total no-op on
  empty *and* does not retract a wash already up, is retracted by a resize starting
  under it, cannot have its expiry stomp that resize's preview, refuses to raise
  mid-resize, and is replaced cleanly by a second wash. The drawing assertions count
  sublayers by `CanvasChrome.membershipWash` rather than reading
  `prospectiveMembers`, so they pin that the new driver reaches the *existing*
  highlight rather than having quietly grown a parallel one.

## Verification

`swift test` in `CanvasRenderer/` — 477 tests, all green, including the seven new
ones and 062's membership-preview suite unchanged beside them. `./scripts/verify.sh
fast` — all 11 stages. The wash's *appearance* is asserted at the layer level (the
right number of layers with the right fill, attached and then given back); it has
not been watched on screen.

## What 100 leaves standing

Nothing in this design, which is finished. What it deliberately does not fix is
named in 100 §7: membership stays derived, so a resize still changes it silently —
visible mid-gesture, and now visible at creation too, but never stored.
