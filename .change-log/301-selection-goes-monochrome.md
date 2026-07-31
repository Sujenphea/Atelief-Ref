# 301 — selection goes monochrome

## Summary

`Theme.swift`'s header has said this from the start:

> Monochrome by design — both Figma frames confirm it. There is NO coloured accent:
> emphasis is a raised grey `field` fill (`#2C2C30`) + white/ink text.

Twenty-five sites disagreed with it. Selection — the single most-seen piece of
chrome in a reference app — was drawn in the system accent: `controlAccentColor` at
5 AppKit sites (the grid cell, the marquee), `Color.accentColor` at 13 SwiftUI sites,
and **seven
hardcoded copies of `CGColor(red: 0.0, green: 0.48, blue: 1.0, …)`** in
`CanvasRenderer`, two of them commented `// accent blue`. That last group is the
tell: a literal blue, duplicated seven times, standing in for a system colour, in an
app that had declared it has no accent.

Selection is now white. One `.accentColor` remains, on purpose (below).

## Two new tokens, and why the second one is not optional

```swift
static let selectionMark = Color.white
static let selectionMarkContrast = Color.black.opacity(0.5)
```

`Colors.selection` was already taken — by the grey FILL that marks the active sidebar
row. That is a different job: a fill reads on a list row and is invisible over a
photograph; a ring reads over a photograph and is wrong on a list row. Both names now
say which they are.

The contrast hairline is the part that makes white workable. The grid tile's ring is
drawn INSET, over the artwork, so a white ring vanishes on a pale photo exactly as
the blue one vanished — which is why a dark hairline already existed beside it. But
that hairline was **1pt at 25% black**, tuned as a supporting edge under a blue
stroke that still half-read on pale images. With a white ring it *is* the edge there,
so it is now **2pt at 50%**. White reads against dark artwork, the hairline reads
against light, and neither carries selection alone.

## The three things this broke if done naively

**The keyboard-cursor ring had no hairline.** Blue at 60% still reads on a white
photo; white at 60% does not. The hairline is now shown for the cursor ring too, and
because the two rings are different widths (3 and 2) it re-derives its inset from
whichever is showing — `layOutContrastHairline(in:)`, called from both
`viewDidLayout` (bounds changed) and `applySelectionState` (ring changed), since the
two inputs are independent and neither can own it. Without that the hairline would
sit 1pt inside the cursor ring with a stripe of bare image between them.

**The selected-cell checkmark.** It is a palette symbol, `[.black, accent]` — a black
tick on an accent disc, chosen so the tick has contrast on any image. `[.black,
.white]` keeps that property; a white tick on a dark disc would have fought the 18%
scrim underneath.

**The canvas resize handles.** A white square with a blue 1.5pt border became a white
square with a white border — i.e. no border. They now take the same two-sided
treatment: white fill, dark border.

## Where white needed no help

`CanvasRenderer` draws its selection OUTSET —
`screenFrame.insetBy(dx: -selectionInset, …)` — so the stroke lands on the dark board
rather than on the artwork. White always reads there, and no hairline is needed. The
grid ring being inset is the *only* reason that one needs a dark line beside it, and
`CanvasChrome`'s header now says so.

**Snap guides stay magenta.** They are the one thing on the canvas that must not be
mistaken for selection — and now that selection is white, a white guide would be
precisely that mistake.

## Two sites that are not selection and did not become white

- **The drag-preview count badge** (`CollectionView`, `LibrarySearch`) was an accent
  capsule with white text. White-on-white erases its own label, so it is a raised
  dark chip — the monochrome way to say "stands off the artwork".
- **`AddColorForm`'s initial swatch** keeps `.accentColor`. It is the colour the USER
  is picking, on its way into the library. The monochrome rule governs what the app
  draws *around* the work, not the work.

## CanvasRenderer can't see Theme

It is a standalone SPM target that knows nothing about AtelierRefs, so the seven
literals collapsed into a new `CanvasChrome` enum rather than importing tokens.
`CanvasChrome.selection` is the same white as `Theme.Colors.selectionMark`; the file
says to move both if either moves. Mirroring is the lesser evil against seven copies
of a raw `CGColor`.

## Files changed

`Theme.swift` (2 tokens + 2 `NS` mirrors), `MasonryGridItem.swift`,
`GridMarqueeController.swift`, `SharedThumbnail.swift`, `CollectionsGalleryView.swift`,
`CollectionView.swift`, `LibrarySearch.swift`, `MoodboardExportControls.swift`,
`AddColorForm.swift`; `CanvasChrome.swift` (new), `CanvasEngine.swift`,
`CanvasHostView.swift`.

## Verified

`swift build` (CanvasRenderer) and `-only-testing:AtelierRefsTests test` →
`** TEST SUCCEEDED **`.

Not looked at running. The geometry is unit-testless by nature — it is CALayer border
widths and insets — so the hairline/ring nesting is reasoned above rather than
observed, and a look at a pale image against a dark one is the check I could not make
from here.
