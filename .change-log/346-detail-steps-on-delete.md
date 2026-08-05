# 346 — Delete Takes You To The Next One

[026] I3. The item detail page no longer closes when you delete the item it is
showing: it shows the item that took its place. Deleting the last item in the run
steps back; only an emptied collection closes the page.

## The triage loop this is for

Open an item, judge it, press ⌫ or ⌘⌫, judge the next one. Before this, every
press of that loop threw you back to the grid — and not even to where you were,
but to wherever the grid's cursor happened to be sitting, since `close()` syncs
the lead from the shown id and the auto-dismiss never got that far. So a pass over
forty refs cost forty round trips through the grid and forty re-opens, which is
why nobody made the pass.

[073] bound ⌫ and ⌘⌫ on the page (`339`, `340`) and this is the other half: with
the keys bound but the page still dismissing, the bindings only made it faster to
leave. Both together are what make it a triage surface.

**The step, in one expression** — `newRun[min(oldIndex, newRun.count - 1)]`. The
item that slides into the departed one's slot is "next" for every position in the
run except the last, where the clamp yields the item *before* it. The clamp is not
an off-by-one guard; it is the behaviour, and it is the reason the decision is a
pure function with a test that fails if you drop it.

Two user decisions, from [026]'s open questions: **⌫ steps just like ⌘⌫** (same
loop, same reasoning — remove-from-here is triage too), and **deleting the last
item steps back rather than closing**.

## The gate: an explicit intent, never an inference

`contentsVersion` bumps on every load, move, reorder and delete, and the old
observer closed the page whenever the shown id was not in the reloaded feed:

```swift
// CollectionView.swift (before)
.onChange(of: model.contentsVersion) { _, _ in
    if let id = session.currentID, !model.items.contains(where: { $0.item.id == id }) {
        nav.presentedItemID = nil
    }
}
```

The tempting change is to make that same condition step instead of close. It is
wrong: a move out of this collection, a reorder that drops the item, and switching
collections while the page is up all satisfy it, and inferring a step from it is
how a collection switch leaves the page open showing a stranger from a folder the
user just navigated away from.

So the two verbs the page owns arm a **one-shot `DetailStepIntent`**, and only
those two. Everything else keeps the pre-026 behaviour exactly. The intent carries
pre-reload state on purpose — by the time the reload arrives, `detailRun` has been
replaced and the departed item's position is unrecoverable, so it has to be
captured at the moment the verb is issued.

Three things keep it genuinely one-shot:

- **Consumed on read.** `consumeDetailStepIntent()` clears as it returns, and the
  host calls it on *every* reload, including the ones that ignore it.
- **Consumed on navigation.** Opening a different item or closing the page spends
  it too, so a step armed against the item you left cannot fire against the one
  you arrived at.
- **Disarmed when the verb doesn't happen.** A cancelled ⌘⌫ dialog clears it
  (every dismissal route — button, Escape, the `isPresented` binding — lands on
  `cancelPendingDeletion`), and ⌫ in Unsorted, which only explains itself and
  causes no reload, never arms in the first place.

The intent also carries the **collection its run came from**, re-checked against
`loadedCollectionID` at consume time. That closes the one race the item-id check
alone does not: press ⌫, switch collections before the reload lands, and the shown
id is legitimately gone from a feed that is full of items at every index — without
the folder stamp the page would step to whichever picture occupies that slot in
the folder you just arrived at.

## What did not have to change

`close()` maps `session.currentID` through `displayTile(for:)` to land the grid
cursor on a real tile. It reads the session at close time, not the route, so it
already lands on wherever you stepped to — the same reason the pager's ← / → have
always worked. The step uses `session.step(to:in:)`, the pager's own move, so it
keeps the previous image up until the new one decodes and writes nothing to the
model: the grid behind the overlay does not re-render per press. `nav.presentedItemID`
keeps pointing at the id the page was opened on, exactly as it does for ← / →.

`DetailSession.loadDisplayImage` supersedes by identity re-check
(`self.state?.detail.item.id == targetID`), so a step that lands mid-decode
discards the late image rather than painting it over the new item. Nothing needed
doing there.

## Files changed

- `AtelierRefs/AtelierRefs/DetailStep.swift` (new) — `DetailStepIntent`,
  `DetailReloadOutcome`, and the two pure functions:
  `DetailStep.next(oldRun:oldIndex:newRun:)` (which item takes the place) and
  `DetailStep.outcome(shownID:intent:newRun:runCollectionID:)` (whether a reload is
  a step at all). Its own file, in the shape `DeleteIntent.swift` established — the
  off-by-one and the gate are both decisions worth testing without a window.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — the private `detailStepIntent`
  plus `armDetailStep(for:)` / `consumeDetailStepIntent()`, and the two
  `itemID:`-taking overloads the page calls: `removeFromCurrentFolder(itemID:assetIDs:)`
  and `requestDelete(itemID:assetIDs:)`. The Unsorted guard is checked *before*
  arming. `cancelPendingDeletion()` now disarms. The intent is deliberately not
  `@Published`: no view reads it, and a publish would re-render the grid under the
  overlay.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `CollectionDetailHost`'s
  `contentsVersion` observer switches on `DetailStep.outcome` (stay / step / close)
  instead of closing unconditionally; the `presentedItemID` observer consumes any
  stale intent; the overlay's `removeFromFolder` / `requestDelete` closures route
  through the `itemID:` overloads, which is the only place a step is armed.
- `AtelierRefs/AtelierRefsTests/DetailStepTests.swift` (new) — 23 tests in two
  suites (16 pure + 7 wiring). The pure suite covers middle / first / last (steps back) / run of one /
  emptied run / still-present / out-of-range / a shrink past the index, the three
  intent-flag cases ([026]'s list: set + gone → step, clear + gone → close, set but
  present → no step), a mismatched intent, the collection-switch race, and the
  five-in-a-row loop itself. The wiring suite pins the seam on `CarouselRig`: ⌫
  arms the pre-reload run and index, ⌘⌫ arms at request time, the flag is one-shot,
  Cancel disarms, Unsorted arms nothing, the grid's own verbs arm nothing, and a
  re-home to Unsorted still steps.

## Migration notes

**Behaviour change.** Deleting (⌘⌫) or removing (⌫) the item shown on the item
detail page no longer closes the page — it moves to the next item in the run, or
to the previous one when you were on the last. The page closes only when the
collection has nothing left to show.

Every *other* way the shown item can leave the feed is unchanged and still closes
the page: moving it to another collection, a reorder that drops it, a delete made
from behind the page, and switching collections while the page is up.

No schema, no settings, no API. The pre-existing `removeFromCurrentFolder(assetIDs:)`
and `requestDelete(assetIDs:)` keep their behaviour exactly — the stepping variants
are additional overloads, so the grid, the Edit menu, the space canvas and search
are untouched.
