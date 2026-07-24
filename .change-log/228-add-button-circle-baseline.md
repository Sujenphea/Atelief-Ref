# 228 — Floating add button: true circle + action-bar baseline

## Summary

Fixed the floating "+" add button rendering as a vertical oval/rounded rectangle, and
aligned its bottom edge with the floating action bar.

- **Shape**: the `NSButton` cell lays out slightly taller than its nominal diameter, so
  a bounds-derived `cornerRadius` produced a rounded rectangle rather than a circle.
  The visible disc (fill + drop shadow) now lives in a dedicated `CALayer` sublayer
  kept as a **centered square** sized to `min(bounds)`, so it stays a perfect circle
  regardless of the frame the SwiftUI host hands the view. The "+" glyph rides in a
  sibling sublayer on top (a plain sublayer would otherwise cover the cell-drawn image),
  rendered as a tinted `CGImage` and aspect-fit for crispness at any backing scale.
- **Sizing**: the call site now pins a hard `.frame(width: 40, height: 40)` instead of
  `.fixedSize()`, which had adopted the button cell's non-square fitting size.
- **Baseline**: the button's uniform `Spacing.xxl` (40) padding is split into
  `.padding(.trailing, 40)` + `.padding(.bottom, 16)` so its bottom edge matches the
  action bar's baseline (`selectionBarChrome`'s 16pt bottom inset) when both are on
  screen. It stays bottom-trailing; the action bar stays centered.

## Files changed

- `AtelierRefs/AtelierRefs/FloatingAddButton.swift` — centered-square `disc`/`glyph`
  sublayers; `plusGlyphImage` helper; removed bounds-derived `cornerRadius` and the
  cell image.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — `.frame(40×40)` + split trailing/bottom
  padding on `floatingAdd`.

## Migration notes

None. Visual/layout only; no API changes.
