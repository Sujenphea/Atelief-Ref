//
//  TextMetrics.swift
//  CanvasRenderer
//
//  054 §2.1 — the single source of typeface truth for text tiles. Both drawing
//  (`setTextOverlay`) and, later (2C), measurement build the font the SAME way
//  here, so a measured size can never drift from the drawn one (mirrors the
//  `CanvasTransform` "single source" rule). Resolved fonts are memoized by
//  `(family, weight)` because `setTextOverlay` runs per visible text tile every
//  `sync()` frame (the pan/zoom hot path); the typeface only changes on a style
//  edit, so resolving it per frame is waste.
//

import AppKit
import CoreText
import QuartzCore

/// Font construction for text tiles — memoized, never nil.
@MainActor
enum CanvasFont {
    /// Reference point size the resolved `CTFont` carries. `CATextLayer` sizes via
    /// its own `fontSize` (the zoom-scaled world size), so the typeface's own point
    /// size is nominal — fixed here so the cache key stays `(family, weight)` and
    /// resolution is deterministic (the pointSize a test can pin against).
    static let referenceSize: CGFloat = 16

    private struct Key: Hashable {
        let family: String?
        let weight: FontWeight
    }

    /// Memoized typefaces, bounded by the distinct `(family, weight)` combos on the
    /// board. Cleared never — a board carries only a handful of combinations.
    private static var cache: [Key: CTFont] = [:]

    /// The typeface for a style. `family == nil` (or empty) → the system font at the
    /// mapped weight; a known family → `NSFontManager` resolution; an unknown family
    /// (nil result) → the system fallback. Never nil, never blank text. Callers set
    /// point size separately (on the `CATextLayer`).
    static func resolve(family: String?, weight: FontWeight) -> CTFont {
        let key = Key(family: family, weight: weight)
        if let cached = cache[key] { return cached }
        let font = build(family: family, weight: weight)
        cache[key] = font
        return font
    }

    private static func build(family: String?, weight: FontWeight) -> CTFont {
        if let family, !family.isEmpty,
           let resolved = NSFontManager.shared.font(
               withFamily: family, traits: [], weight: weight.legacyWeight, size: referenceSize) {
            return resolved as CTFont
        }
        return NSFont.systemFont(ofSize: referenceSize, weight: weight.systemWeight) as CTFont
    }
}

extension FontWeight {
    /// The `NSFont.Weight` for the system-font path.
    var systemWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// The legacy `NSFontManager` 0–15 weight scale (5 ≈ regular, 9 ≈ bold) — the
    /// `font(withFamily:traits:weight:size:)` path takes this int, not `NSFont.Weight`.
    var legacyWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        }
    }
}

extension TextAlignment {
    /// The `CATextLayer` alignment mode for this alignment.
    var caAlignment: CATextLayerAlignmentMode {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}
