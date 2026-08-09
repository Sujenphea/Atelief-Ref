# 354 — ⌘⌫ On The Page Reaches The Page

[346] made the item detail page step to the next item instead of closing when you
delete the one it is showing. In the app it never did: ⌘⌫ pressed on the page was
never the page's ⌘⌫. It is now, and while it was being routed it stops destroying
the wrong picture.

## Why the shipped feature never fired

`Edit ▸ Delete` carries `.keyboardShortcut(.delete, modifiers: .command)`, and
`NSMenu` matches a key equivalent **before** the event reaches the first responder.
`DeleteCommands` says so in its own doc comment — it is the reason a bare ⌫ is
deliberately *not* registered there, and the platform behaviour that killed the
page's arrows in [069]. The same reasoning was never carried to ⌘⌫.

So the press never reached `DetailKeyCatcher`'s ⌘⌫ branch. It reached whatever
`DeleteVerbs` was published, which — with the page up over a collection — was the
**grid's**:

```swift
// CollectionView.swift (before)
.focusedSceneValue(\.deleteVerbs, DeleteVerbs(
    …
    destroy: { model.requestDeleteSelected() }))
```

`requestDeleteSelected()` lands on the plain `requestDelete(assetIDs:)`, which arms
no `DetailStepIntent`. The reload then found no intent, `DetailStep.outcome` fell
through to `.close` exactly as designed, and the page dismissed — the pre-026
behaviour, from code that had every appearance of having replaced it. The page's
overflow menu ▸ Delete, which calls the `itemID:` overload directly, stepped
correctly the whole time; only the key did not.

**And it deleted the wrong item.** `requestDeleteSelected()` targets
`keyboardActionTargets` — the selection, or the *lead cursor's* post. Stepping with
← / → writes nothing to the model on purpose (that is what keeps the grid from
re-rendering per step), so the lead stays parked wherever the page was opened. Page
three items along, press ⌘⌫, and the picture that went to the Trash was the one the
grid was pointing at, not the one on screen. Undoable, and silent.

⌫ was unaffected throughout: no bare-⌫ key equivalent exists, so it reached the key
catcher and the arming overload, which is why the triage loop half-worked and the
gap read as "delete closes the page".

## One publisher at a time, not an override

The page now publishes its own verbs, targeting the item it is SHOWING (`session.state`,
not the route — the same thing `close()` reads, and the only thing that survives any
number of steps), routed through the `itemID:` overloads the overflow menu already
used. One rule for the page's two verbs whichever surface raises them.

Which leaves the question of who wins when two views in one scene publish the same
focused value. Nothing here relies on the answer: `CollectionView` publishes the
grid's verbs **only while the route is empty**, so exactly one of the two is ever
live. The gate is `nav.presentedItemID`, for [069]'s reason — it is the published
truth that body already observes to hand the keyboard over, where `isDetailPresented`
is deliberately un-`@Published` and written from the host's `onChange`.

## The second gate, behind the first

Fixing the routing alone would still have closed the page. SwiftUI writes `false`
into a dialog's `isPresented` binding when it dismisses — **including on the way out
of the Delete button** — so `ContentView`'s bridge called `cancelPendingDeletion()`
on the *confirm* path too, a moment after the confirm cleared the pending state and
long before the delete's asynchronous reload landed. That disarmed the intent the
press had just armed, for the very reload it was armed for.

`cancelPendingDeletion()` now returns early when nothing is pending. Nothing staged
means nothing was called off: the trailing write is a no-op, and Cancel / Escape —
which arrive with the deletion still staged — disarm exactly as before.

## Why 23 tests did not catch it

`DetailStepTests` pins the model seam and the two pure functions, and calls
`model.requestDelete(itemID:assetIDs:)` directly. It could not see who calls it, and
nothing exercised the confirm path end to end — `requestDeleteArms` consumes the
intent to assert it, which destroys the thing the next step would have needed. Both
failures live in the wiring above that seam: a menu key equivalent and a SwiftUI
binding write, neither reachable from a test without a window.

The four tests added below close what is closeable at the seam. The routing itself
is verified by pressing the key.

## Files changed

- `AtelierRefs/AtelierRefs/CollectionView.swift` — `CollectionDetailHost` publishes
  `\.deleteVerbs` while `session.state != nil`, via `pageDeleteVerbs(for:)`, on the
  `itemID:` overloads; `CollectionView`'s own publisher (extracted to
  `gridDeleteVerbs`) is gated on `nav.presentedItemID == nil`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `cancelPendingDeletion()` guards
  on a staged deletion before disarming.
- `AtelierRefs/AtelierRefsTests/DetailStepTests.swift` — four tests: the page's ⌘⌫
  and ⌫ target the shown item while the lead is parked elsewhere; the dialog's
  dismissal write after Delete leaves the intent armed; Cancel with a deletion
  staged still disarms.

## Migration notes

**Behaviour change.** ⌘⌫ on the item detail page now deletes the item on screen and
steps to the next one, which is what [346] documented. Before this it deleted the
grid's cursor item and closed the page.

Edit ▸ Remove from Collection / Delete now name the page's verbs while the page is
up, and the grid's while it is down. No schema, no settings, no API.
