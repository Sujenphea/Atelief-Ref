//
//  BoardStyleNames.swift
//  AtelierRefs
//
//  099 · 2A — names for the renderer's style types that a file importing
//  `AtelierExport` (or SwiftUI) can actually say.
//
//  `TextStyle`, `FontWeight` and `TextAlignment` each exist in more than one
//  module this app links: `CanvasRenderer` owns the board's, `AtelierExport` owns
//  the page's, and SwiftUI owns a `TextAlignment` of its own. That is not an
//  accident to tidy away — it is the shape of 2A. `AtelierExport` has zero product
//  dependencies by design, so the two renderers cannot share a type, and the
//  conformance suite exists precisely because two independent types are read from
//  one stored `ElementStyle`.
//
//  What IS an accident is that neither collision can be resolved by qualifying.
//  `CanvasRenderer.TextStyle` does not mean "the module's TextStyle": the module
//  also contains an enum named `CanvasRenderer`, so the qualified spelling looks
//  inside that enum and fails. The fix is scope — this file imports ONE of the
//  modules, so the bare names resolve, and the aliases it publishes carry that
//  resolution everywhere else.
//
//  Its opposite number is `MoodboardExport.PageTextStyle`, resolved the same way
//  in a file that imports `AtelierExport` and not `CanvasRenderer`.
//

import CanvasRenderer

extension ElementRendering {
    /// The board's text style — `CanvasRenderer`'s.
    typealias BoardTextStyle = TextStyle
    /// The board's weight token — `CanvasRenderer`'s.
    typealias BoardFontWeight = FontWeight
    /// The board's alignment token — `CanvasRenderer`'s, not SwiftUI's.
    typealias BoardTextAlignment = TextAlignment
}
