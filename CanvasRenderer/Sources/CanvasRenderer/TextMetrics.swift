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

    /// The same typeface as ``resolve(family:weight:)``, as an `NSFont` at a given
    /// point size — what an `NSTextView` needs.
    ///
    /// One resolver for the drawn glyphs and the edited ones. The inline editor used to
    /// rebuild this mapping for itself, in the app, because `CanvasFont` was internal to
    /// the package; two copies of a family/weight table is exactly the kind of thing
    /// that drifts, and it is the editor and the renderer disagreeing that the user sees.
    static func nsFont(family: String?, weight: FontWeight, size: CGFloat) -> NSFont {
        let base = resolve(family: family, weight: weight)
        let sized = CTFontCreateCopyWithAttributes(base, max(1, size), nil, nil)
        return sized as NSFont
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

    /// How wide an auto-width box (063) may grow before it starts wrapping — the
    /// measured text width, so a box's outer width caps at `maxAutoWidth + 2·padding`.
    ///
    /// A deliberate deviation from Figma, which grows without limit. Text arrives here
    /// by paste as often as by typing, and an unbounded hug turns a pasted paragraph
    /// into a single line tens of thousands of world units wide — unreadable at any
    /// zoom that fits it, and awkward to select. Past the cap the box wraps and behaves
    /// like a fixed box of this width *while staying flagged auto*, so deleting text
    /// lets it hug again. A safety valve, not a second mode.
    public static let maxAutoWidth: CGFloat = 1200

    /// The world-space size the styled text occupies, measured with the drawing
    /// font at the world `fontSize` (so it is zoom-independent). `maxWidth == nil`
    /// → unconstrained (grows to the longest line); a value → wrapped to that width
    /// (height grows with the line count). An empty string still occupies one line
    /// height (so an empty auto box stays selectable). Ceiled so glyphs never clip.
    ///
    /// A thin wrapper over ``TextShaper/shape(_:maxWidth:maxHeight:)`` (060 §1):
    /// the size returned IS the size of the layout that gets drawn, so a measured
    /// line break can never differ from a drawn one. Never truncates — clipping is
    /// a draw-box concern, not a measurement one.
    public static func size(for style: TextStyle, maxWidth: CGFloat?) -> CGSize {
        TextShaper.shape(style, maxWidth: maxWidth).size
    }

    /// The inner (unpadded) size of a text box's text, for a box that is either given
    /// its outer width or derives one (063).
    ///
    /// Hugging measures unconstrained, then — if the longest line exceeds
    /// ``maxAutoWidth`` — measures *again* wrapped to the cap. The second pass is what
    /// makes the cap a **wrap** rather than a clip: the box stops growing sideways and
    /// grows downward instead, and shrinking the text below the cap lets it hug again,
    /// because nothing about the flag changed.
    ///
    /// Lives here, in the renderer, because BOTH sides need it and they must agree:
    /// the app derives the committed box from it, and the inline editor derives the
    /// live one. Two copies of this rule would be two answers to "how wide is this
    /// box", which is precisely the drift 060 exists to prevent.
    public static func size(
        for style: TextStyle, hugging: Bool, outerWidth: CGFloat
    ) -> CGSize {
        guard hugging else {
            return size(for: style, maxWidth: max(1, outerWidth - 2 * padding))
        }
        let free = size(for: style, maxWidth: nil)
        guard free.width > maxAutoWidth else { return free }
        return size(for: style, maxWidth: maxAutoWidth)
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

