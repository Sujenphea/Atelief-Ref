# 229 · Chrome button hover states + sidebar toggle tooltip

## Summary

Only the selection action bar's glyphs had a hover state — its `SelectionBarIcon`
was the codebase's one and only hover implementation (an ad-hoc `@State isHovering`
+ `.onHover` driving a rounded `Color.primary` fill). Every other chrome button used
`.buttonStyle(.plain)`, which gives no hover feedback on macOS, so the sidebar toggle,
sort, trash, section controls, nav rows, and the search × controls all read as inert.

This promotes that recipe into one reusable primitive and applies it across the app
chrome. It also fixes the sidebar collapse toggle's tooltip: `.help("Collapse sidebar")`
was present but never appeared because the label was a bare template `Image` whose only
hit-testable area was its opaque glyph pixels — the padded `.contentShape` the new style
adds gives `.help()` a real tooltip-tracking area.

## New primitive

`HoverButtonStyle.swift`:

- `HoverHighlight` (`ViewModifier`) — the core: pads the content, fills a rounded rect
  at `Color.primary.opacity` on `.onHover`, over a `.contentShape(Rectangle())` hit area.
  Disabled-aware via `@Environment(\.isEnabled)`.
- `.hoverHighlight(cornerRadius:opacity:padding:)` — for views that can't take a
  `ButtonStyle` (the sort `Menu`, whose `.menuStyle` ignores button styles).
- `HoverButtonStyle` (`ButtonStyle`) — the same fill plus a pressed dim, for `Button`s.

Matches the action bar's look (`0.10` primary fill); tuned per site for smaller targets.

## Files changed

- **`HoverButtonStyle.swift`** (new) — the shared hover style + modifier.
- **`SidebarView.swift`** — `collapseToggle`, `trashButton` → `HoverButtonStyle(padding: 5)`;
  `sortMenu` → `.hoverHighlight(padding: 5)`; section disclosure + `+` →
  `HoverButtonStyle(cornerRadius: 6, padding: 4)`; nav rows → `.hoverHighlight` with
  `padding: 0` so the hover sits behind the existing selection fill (reads only when
  unselected). The collapse toggle's enlarged hit area is also the tooltip fix.
- **`LibrarySearch.swift`** — search clear `×` and token-remove `×` → `HoverButtonStyle`;
  `SearchModeToggle`'s `segment(...)` extracted to a `ModeSegment` view so an inactive
  segment picks up a subtle hover fill (previously only the active one had a fill).
- **`FloatingAddButton.swift`** — the AppKit `RoundButton` gains an `NSTrackingArea`;
  `mouseEntered`/`mouseExited` animate a subtle lift (stronger shadow + `1.06` scale),
  the AppKit analogue of the SwiftUI hover fill.

## Notes / follow-ups

- Sidebar row hover (follow-up): `SidebarRowView` (the shared AppKit row for BOTH the
  Spaces and Collections trees) gained pointer-over feedback — a white-at-6% rounded
  fill (`Color.primary.opacity(0.06)`, the SwiftUI nav rows' hover) drawn only on an
  unselected, non-draft row. Implemented via a per-row `NSTrackingArea`;
  `updateTrackingAreas` reconciles hover against the live pointer so recycled rows never
  keep a stale highlight.
- Sidebar section spacing (follow-up): the "Spaces"/"Collections" headers + their `+`
  buttons went `padding: 4 → 6` for a roomier tap/hover block; to keep density, the
  header→rows gap dropped `md (12) → sm (8)` and the section→section gap dropped
  `xl (24) → lg (16)`. Row-to-row spacing inside the lists is AppKit `NSOutlineView`
  and untouched.
- Per decision, the sidebar toggle keeps its current leading position (no `Spacer`).
  The enlarged hit area extends the hoverable region below/right of the glyph, clear of
  the traffic lights. If the tooltip still proves hard to land in the expanded layout,
  the fuller fix is to trailing-align it (add a `Spacer`), which also matches the code
  comment's stated intent ("the collapse toggle, trailing").
