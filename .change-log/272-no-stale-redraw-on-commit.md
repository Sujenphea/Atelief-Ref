# 272 — Committing an edit no longer flashes the old text

## Summary

Finishing an inline edit showed a subtle flicker: the box redrew with the **old** string
at the **old** height for a turn, then reflowed to the new one.

`CanvasTextEditController.finish()` does four things in order — removes the live
`NSTextView`, reports the outcome, restores the stored height, un-blanks the tile's
committed glyphs. The last two each `sync()`, and a sync re-reads
`provider.content(for:)`. So whether the redraw is correct depends entirely on whether
the app has written the new text by the time step 2 returns.

`finish()` already assumed it had — its own comment says *"Hand the height back to the
stored geometry AFTER the outcome is applied: a commit has by then written the derived
height, so the box holds still."* But `SpaceView` deferred:

```swift
onFinishEditingText: { tileID, outcome in
    Task { @MainActor in applyEditOutcome(outcome, tileID: tileID) }
}
```

Measured against a provider that records every string it hands over:

```
deferred:     served during teardown ["old", "old"]  → then "NEW" a turn later
synchronous:  served during teardown ["NEW", "NEW", "NEW"]
```

## The fix

`SpaceView` applies the outcome where it is told about it. That is safe because
`SpaceModel.applyRestyle` mirrors into the live `SpaceContent` synchronously — only the
*persistence* is enqueued — so by the time the height is restored the provider already
has both the new string and its newly derived height. No new state, no extra sync.

## …except on teardown, and the host is the only side that knows

`onFinishEditingText` can fire from inside a SwiftUI view update, where publishing is
undefined. Two paths, and they are not alike:

- **An edit request preempting an open edit.** Unreachable in practice — creating a text
  box takes a press, which already committed any open edit on mouse-down.
- **Teardown** (`viewWillMove(toWindow: nil)`, `willTerminate`). Real: the commit would
  publish into the very view update removing the host. It is also the one case where the
  stale redraw is invisible, because the canvas is going away.

So `endEditingForTeardown()` sets a flag that makes `editorDidFinish` deliver the outcome
off the current turn. The edit still **ends** synchronously; only the report is deferred.
This keeps the hazard handled where the knowledge is, rather than making the app defer
everywhere to be safe in a case it cannot detect.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceView.swift` — `onFinishEditingText` applied synchronously
  (`onEditingChanged` stays hopped; it publishes and does fire during a view update)
- `CanvasRenderer/.../Host/CanvasHostView.swift` — `endEditingForTeardown()` and the
  deferred report
- `CanvasRenderer/Tests/.../HostEditingTests.swift` — the stale-redraw contract; the
  window-teardown case now awaits its outcome

## Tests

`TextProvider` records every string the renderer asks it for, so a test can assert what
the canvas actually **drew**, not merely what it settled on. The new case commits an
edit whose handler updates the provider, then requires that the redraws which follow
never contain the old string — the failure being a flicker, not a wrong end state, this
is the only shape of assertion that catches it.

Both suites green: 366 in `CanvasRenderer`, and `AtelierRefsTests`.
