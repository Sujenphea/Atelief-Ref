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

/// Pure world-space text measurement for auto-sizing text tiles (2C · 054 §4.1).
/// Mode-agnostic *(R1)*: it never sees the domain `TextResize` — a `nil`
/// `maxWidth` measures unconstrained (one line / autoWidth), a value measures
/// width-constrained wrapping (autoHeight). It builds the typeface the SAME way
/// as drawing (``CanvasFont/resolve(family:weight:)``) at the world `fontSize`, so
/// a measured size can never drift from the drawn one (the `CanvasTransform`
/// "single source" discipline). Padding is NOT included — the app-layer policy
/// adds ``padding`` on the measured axes (054 §4.2).
@MainActor
public enum TextMetrics {
    /// World-space inset applied on EACH edge of a `.text` tile — added by the app
    /// when it auto-sizes (`w`/`h` = measured + `2 · padding`, 054 §4.2) and mapped
    /// `× scale` at draw time (``CanvasEngine`` §4.4) so the drawn inset equals the
    /// measured inset at every zoom. Frame labels keep their own screen-space pad.
    public static let padding: CGFloat = 4

    /// The world-space size the styled text occupies, measured with the drawing
    /// font at the world `fontSize` (so it is zoom-independent). `maxWidth == nil`
    /// → unconstrained (grows to the longest line); a value → wrapped to that width
    /// (height grows with the line count). An empty string still occupies one line
    /// height (so an empty auto box stays selectable). Ceiled so glyphs never clip.
    public static func size(for style: TextStyle, maxWidth: CGFloat?) -> CGSize {
        let pointSize = CGFloat(max(1, style.fontSize))
        let base = CanvasFont.resolve(family: style.fontFamily, weight: style.weight)
        // The resolved typeface carries a nominal reference size; measure at the
        // actual world point size (a cheap descriptor copy, not a new resolution).
        let font = CTFontCreateCopyWithAttributes(base, pointSize, nil, nil)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)

        // An empty string measures as one line (a lone space) so the box never
        // collapses to zero height; width stays tiny.
        let string = style.string.isEmpty ? " " : style.string
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let constraint = CGSize(
            width: maxWidth ?? .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude)
        let rect = attributed.boundingRect(
            with: constraint, options: [.usesLineFragmentOrigin], context: nil)
        return CGSize(
            width: ceil(rect.width),
            height: ceil(max(rect.height, lineHeight)))
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
