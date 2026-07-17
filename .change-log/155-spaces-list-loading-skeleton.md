# 155 — Spaces list: skeleton instead of false-empty flash (034 P2)

## Summary

The Spaces list rendered its "No spaces yet" empty state on first appear because
`model.spaces` is empty until `.task { refreshSpaces() }` loads — so a user who
actually has spaces saw the empty state flash before their cards appeared.

Fix: track a `didLoad` flag set when the first refresh completes. While
`model.spaces` is empty *and* not yet loaded, show a redacted skeleton grid of
cover cards ("content loading") instead of the empty-state message. Once loaded, a
genuinely empty library still shows "No spaces yet". A revisit with spaces already
in memory shows the grid immediately (the empty branch isn't taken at all).

With this + the onboarding token row (changelog 154), the P2 "loading flashes empty
states" item is closed.

## Files changed

### AtelierRefs
- `SpacesListView.swift` — `didLoad` state; empty branch shows `loadingState`
  (redacted `CoverCard` skeleton) until the first `refreshSpaces` completes.

## Migration notes

None.

## Verify

- With at least one space, navigate to Spaces → the cards fade in from a skeleton;
  the "No spaces yet" message never flashes.
- With no spaces, the skeleton resolves to the "No spaces yet" empty state.
