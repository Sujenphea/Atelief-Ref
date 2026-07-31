# 306 — hover dims the tile

## Summary

Hovering a grid tile now dims its artwork, the same cue selection already used.
Requested directly.

| State | Dim |
| --- | --- |
| Hovered | 0.10 |
| Selected | 0.18 |
| Both | 0.18 — one dim, not two stacked |

## One layer, not two

The obvious implementation is a second scrim for hover. This reuses the existing
one, renamed `selectionScrimLayer` → `scrimLayer` because the old name would now be
a lie.

Two layers would have meant two blacks that could drift apart in a later edit, and a
cell that is both hovered and selected showing 0.28 of stacked dim — the state that
is hardest to notice is wrong and easiest to ship. With one layer,
``updateScrim()`` is the single writer, selected wins over hovered, and "both" is not
a third case to maintain.

It is called from `applySelectionState(_:)` and `setHovered(_:)`, which are the only
two things that can change either input.

## Hover is half, not equal

The request was "like selected", and the dim is the same gesture — but at roughly
half strength, because `Theme.Colors.hoverRow` already writes the rule down:

> Deliberately a whisper: `selection` marks where you ARE, and hover must not be
> mistakable for it.

A hovered cell also carries no ring and no checkmark, so the two never read alike
even before the depth difference registers.

## Instant, deliberately

No fade. Every other layer mutation in this cell is wrapped in a `CATransaction`
with actions disabled, because implicit CALayer animation on a RECYCLED cell
cross-fades the previous item's state into the new one's. The app's SwiftUI
`HoverHighlight` is instant too, so this matches both its neighbours and its siblings.

`prepareForReuse` already cleared `isHovered` before re-applying state, so a recycled
cell cannot inherit a stale dim — that ordering was load-bearing and is now doing a
second job.

## Files changed

`MasonryGridItem.swift`.

## Not verified

The dim on **media-less card tiles** (bare link / tweet / colour). Those host a
SwiftUI view as a SUBVIEW while the scrim is a SUBLAYER of the container, so the dim
may render behind the card and never show. If so it is pre-existing — the selection
dim and the selection ring have the same relationship to that card — and inherited
here rather than introduced. Worth an eye before assuming either way.

## Verified

`-only-testing:AtelierRefsTests test` → `** TEST SUCCEEDED **`. The visual itself is
unverified from here; 0.10 is one constant if it wants to be heavier or lighter.
