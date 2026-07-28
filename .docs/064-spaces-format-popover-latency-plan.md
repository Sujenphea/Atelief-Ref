# 064 — The text format popovers open instantly

> Why picking a font on a board was "sometimes very slow, not instant", and what the
> measurements said — including the two places the obvious fix would have made it worse.

## 1. The problem

Opening the format bubble's "Aa" popover (and the same font control in
`ElementInspector`) was visibly delayed rather than instant, intermittently.

## 2. What was measured

Everything below is measured on the development machine, which has **402 font families
installed**. That number matters: every cost here scales with it, and a machine with 40
fonts would not have shown the bug at all.

| call | cost |
| --- | --- |
| `NSFontManager.availableFontFamilies` — **first call in the process** | **384 ms** |
| `NSFontManager.availableFontFamilies` — every call after | 0.04 ms |
| `CTFontManagerCopyAvailableFontFamilyNames()` | 58 ms — **every** call |
| `NSFontManager.font(withFamily:traits:weight:size:)` | 6.5 ms cold, 1.7 ms warm |
| build an `NSMenu` of 402 items | 0.5 ms |
| **`NSPopUpButton.sizeToFit()` over 402 items** | **160 ms** |

### Two independent costs, not one

**(a) The enumeration — 384 ms, once.** Both font controls held the list as a *stored
property on a SwiftUI `View`*:

```swift
// SpaceFormatChrome.swift:411  and  ElementInspector.swift:40 — identical line
private let families = NSFontManager.shared.availableFontFamilies
```

A stored `let` on a `View` is re-evaluated every time the struct is constructed, and
`SpaceTextFontPopover` is constructed inside its own `.popover` content closure — so
this ran *on the click that opened the popover*. First open per launch: 384 ms of main
thread. That is the "sometimes".

**(b) The sizing — 160 ms, every time.** A SwiftUI `Picker` on macOS is backed by an
`NSPopUpButton`, which needs an intrinsic width, which means measuring **every** item's
title. Building the menu is nearly free (0.5 ms); *sizing* it is 160 ms. This one was
paid on every open, which is why it never felt instant even warm.

Only (a) was in the original hypothesis. (b) was found by measuring the thing the
hypothesis had already blamed and cleared.

### Two traps the measurements caught

1. **"Use CoreText, it's the lower-level API."** `CTFontManagerCopyAvailableFontFamilyNames()`
   costs 58 ms *every call* — it caches nothing — against `NSFontManager`'s 0.04 ms warm
   path. Swapping naively would have made the common case ~1400× slower. CoreText is
   used here **only** because the result is cached once by us, which turns "58 ms every
   call" into "58 ms once, on a background thread".
2. **"Warm CoreText and NSFontManager gets fast."** It does not: with the CoreText
   registry already warm, `NSFontManager.availableFontFamilies` still took 321 ms. It
   builds its own cache. What *does* work is calling the enumeration off the main thread
   at all — the cache is process-wide, so a later main-thread read is 0.05 ms.

And one thing ruled out: `NSFontManager.font(withFamily:)` — what `CanvasFont.build`
resolves typefaces with — does **not** pay the enumeration cost. This was never a
text-rendering problem; the cost was isolated to the *list*, which only the pickers need.

## 3. The fix

### `FontFamilyCatalog` — enumerate once, off the main thread

A `nonisolated final class` with a lock, warmed from `SpaceView.task` when a board
opens — the only place a font picker is reachable from, so a session that never opens a
board never spends the time. `families` blocks on first read if the warm hasn't landed,
because correct beats fast and the picker must never show an empty list.

**`nonisolated` is load-bearing.** This target builds with
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it the type is implicitly
main-actor isolated and `warm()`'s detached task hops straight back to the main thread —
running the 384 ms enumeration in exactly the place the file exists to keep it out of.
The compiler said so, as a Swift 6 language mode warning, before it was a bug.

CoreText backs the list rather than `NSFontManager` for a reason beyond speed:
`CTFontManager` is not AppKit-bound, so warming it on a background thread is in
contract, whereas `NSFontManager` off-main happens to work and is not documented to.
The two return **identical family sets in identical order** — verified, not assumed.

### `FontFamilyPicker` — stop measuring 402 titles to draw 8

The `Picker` becomes a search field over a `ScrollView` + `LazyVStack`, so only visible
rows are realised and the width comes from the popover rather than from the content.
The search field earns its place independently: a flat menu of 402 families is not
browsable. Opening scrolls to the current selection, or a user who has chosen Helvetica
reopens at the top of the alphabet.

Deliberately **plain labels, not each family drawn in its own face**: resolving a
typeface costs ~1.7 ms, invisible for the handful on screen but a stutter while
scrolling.

One shared component for both call sites — the codebase's own rule, and the reason the
duplicated enumeration existed in two files to begin with.

### Focus

The popover now contains a text field, and the bubble is mounted only while a box is
being edited — so it is worth being explicit that nothing changed here. `formatTarget`
(`SpaceView.swift:454-461`) already keeps the bubble mounted against the *selected*
element when a popover steals key focus, which is the pre-existing contract for any
focusable popover content. The search field is **not** auto-focused, so opening the
popover behaves exactly as it did when the content was a popup button.

## 4. Files changed

- new: `AtelierRefs/AtelierRefs/FontFamilyCatalog.swift`
- new: `AtelierRefs/AtelierRefs/FontFamilyPicker.swift`
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — `SpaceTextFontPopover` uses the
  shared picker; the enumeration and its stored property are gone
- `AtelierRefs/AtelierRefs/ElementInspector.swift` — same, second call site
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `.task { FontFamilyCatalog.shared.warm() }`

## 5. Verification

By hand, and the *first* attempt is the one that mattered: launch, open a board,
double-click a text box, click **Aa**. The list appears immediately, scrolled to the
current family. Type into the search field to filter. Repeat from the element inspector.
Confirm choosing a family still applies to the box, and that "System" still clears back
to the nil family (`CanvasFont.build`'s fallback is unchanged).

## 6. Note for future work

The cost here scaled with the number of installed fonts, and the machine it was found on
has 402. Any future control that renders one row per font — a weight list per family, a
preview grid — should assume that number, not a typical one.
