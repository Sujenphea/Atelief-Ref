//
//  CanvasChrome.swift
//  CanvasRenderer
//
//  The canvas's overlay colours in one place. They used to be seven copies of
//  `CGColor(red: 0.0, green: 0.48, blue: 1.0, …)` spread across `CanvasEngine` and
//  `CanvasHostView`, two of them annotated `// accent blue` — a hardcoded stand-in
//  for the system accent, in an app whose theme header states it is monochrome by
//  design and has no coloured accent.
//
//  This package cannot see the app's `Theme` (it is a standalone SPM target that
//  knows nothing about AtelierRefs), so the tokens are mirrored here rather than
//  imported. `selection` is the same white as `Theme.Colors.selectionMark`; if one
//  moves, move both.
//
//  No contrast hairline here, unlike the grid's tile ring. The canvas draws its
//  selection OUTSET — `screenFrame.insetBy(dx: -selectionInset, …)` — so the stroke
//  lands on the dark board rather than on the artwork, and white always reads
//  against it. The grid's ring is INSET over the image, which is the only reason
//  that one needs a dark line beside it.
//

import CoreGraphics

enum CanvasChrome {
    /// The selected element's outline.
    static let selection = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    /// The marquee's stroke + its wash.
    static let marqueeStroke = CGColor(red: 1, green: 1, blue: 1, alpha: 0.7)
    static let marqueeFill = CGColor(red: 1, green: 1, blue: 1, alpha: 0.12)
    /// The create-tool's rubber band: brighter than the marquee because it is
    /// committing something rather than surveying it.
    static let createStroke = CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)
    static let createFill = CGColor(red: 1, green: 1, blue: 1, alpha: 0.08)
    /// The wash over tiles a resizing frame is about to swallow. A FILL, never a
    /// border — the border idiom belongs to selection, and these are not selected.
    static let membershipWash = CGColor(red: 1, green: 1, blue: 1, alpha: 0.22)
    /// Snap guides stay MAGENTA on purpose. They are the one thing on the canvas
    /// that must not be mistaken for selection, and now that selection is white,
    /// a white guide would be exactly that mistake.
    static let snapGuide = CGColor(red: 1.0, green: 0.2, blue: 0.55, alpha: 0.9)
    /// An EQUAL-SPACING guide (099 · P12), the same magenta at two thirds the alpha.
    ///
    /// The same hue on purpose: both lines mean "snapped", and a second colour would
    /// invite the reader to decode a palette mid-drag. The weaker alpha carries the
    /// weaker claim — an alignment guide sits on an edge that is really there, while
    /// this one marks a position inferred from two gaps, and it is a fallback to the
    /// alignment it never overrides.
    static let equalSpacingGuide = CGColor(red: 1.0, green: 0.2, blue: 0.55, alpha: 0.6)
    /// The resize handle: a white square with a DARK border. It kept its white fill
    /// and lost a blue border, and white-on-white is not a border — so the handle
    /// takes the same two-sided treatment as the grid's ring, dark inside light.
    static let handleFill = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let handleBorder = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
}
