# 336 — Toast stack: off the "+", flush to the edge

## Summary

The toast stack had two placement faults that compounded into "floating somewhere in
the middle of the corner".

- **Vertical — it sat on the floating "+".** `ToastHostView` is an overlay on the
  SHELL, so its insets measure from the WINDOW, while the "+" and the selection action
  bar are overlays on the PANE and measure from the content panel (itself `Spacing.md`
  in). The stack took a bare `.padding()`, which put its ~40pt-tall card across 16–56pt
  up from the window bottom — straight through the 40pt "+" disc that spans 28–68pt. The
  card is opaque and hit-testable, so for the full 6s TTL it covered the button and ate
  its clicks. The bottom inset is now derived rather than defaulted —
  `md + lg + 40 + sm` = 76 — so toasts rise clear above the disc. Trailing is an
  explicit `Spacing.lg`.
- **Horizontal — a ~90pt phantom margin.** `ToastCard`'s `.frame(maxWidth: 420)` sits
  outside the capsule background, and the host proposes an infinite width down through
  the stack, so the frame always resolved to the full 420 and centred the content-sized
  pill inside it. The dead space is invisible, so a short toast read as being inset by a
  hundred points. The stack's `alignment: .trailing` could not correct it — that aligns
  these frames, not the pills within them. Now `.frame(maxWidth: 420, alignment:
  .trailing)`. The cap keeps its real job: it is the width proposed to the message, so a
  long one wraps to two lines instead of stretching into a banner.

Net: toasts sit flush with the "+" on the trailing edge and stack upward from just
above it. `ToastQueue`, `ToastCenter`, and the action routing are untouched.

## Files changed

- `AtelierRefs/AtelierRefs/ToastHost.swift` — `trailingInset` / `bottomInset` constants
  on `ToastHostView` replacing the default `.padding()`; `alignment: .trailing` on
  `ToastCard`'s width cap; placement rationale documented on the host.

## Migration notes

None. Visual/layout only; no API changes, no behaviour change to queueing, coalescing,
expiry, or the Jump/Undo actions.
