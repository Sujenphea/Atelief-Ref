# 273 — The text format popovers open instantly

## Summary

Opening the board's "Aa" font popover was intermittently slow. Two independent costs,
both scaling with the number of installed fonts (402 on the machine this was found on):

- **384 ms, once per launch.** Both font controls held the catalogue as a *stored
  property on a SwiftUI `View`* — `private let families = NSFontManager.shared.availableFontFamilies`
  — and `SpaceTextFontPopover` is constructed inside its own `.popover` content closure.
  So the enumeration ran on the click that opened the popover.
- **160 ms, every time.** A SwiftUI `Picker` is backed by an `NSPopUpButton`, which
  derives an intrinsic width by measuring *every* item's title. Building the menu costs
  0.5 ms; sizing it costs 160 ms.

Only the first was suspected. The second was found by measuring the part the hypothesis
had already cleared.

## The fix

`FontFamilyCatalog` enumerates once, off the main thread, warmed from `SpaceView.task`
when a board opens. `FontFamilyPicker` replaces the `Picker` with a search field over a
`ScrollView` + `LazyVStack`, so only visible rows are realised and the width comes from
the popover rather than the content. One shared component for both call sites, which is
also how the duplicated enumeration got into two files.

## Two traps the measurements caught

- **"Use CoreText instead."** `CTFontManagerCopyAvailableFontFamilyNames()` costs 58 ms
  *every* call — it caches nothing — against `NSFontManager`'s 0.04 ms warm path.
  Swapping naively would have made the common case ~1400× slower. It is the right source
  here only because the result is cached once, off-main.
- **`nonisolated` is load-bearing.** The target builds with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it the catalogue is implicitly
  main-actor isolated and the detached warm hops back to main — running the 384 ms in
  exactly the place it was moved out of.

Ruled out: `NSFontManager.font(withFamily:)`, which `CanvasFont.build` uses, does **not**
pay the enumeration cost. This was never a text-rendering problem.

## Files changed

- new: `AtelierRefs/AtelierRefs/FontFamilyCatalog.swift`, `FontFamilyPicker.swift`
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift`, `ElementInspector.swift` — both call
  sites use the shared picker; the duplicated enumeration is gone
- `AtelierRefs/AtelierRefs/SpaceView.swift` — warms the catalogue on board open

## Migration notes

None. No model, schema or renderer change; the font a box uses is stored and resolved
exactly as before.

## Verification

By hand, and the *first* open is the case that failed: launch → board → double-click a
text box → **Aa**. The list appears immediately, scrolled to the current family, and
filters as you type. Full write-up with the measurement table in
`.docs/064-spaces-format-popover-latency-plan.md`.
