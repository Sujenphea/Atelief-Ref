//
//  TextShaper.swift
//  CanvasRenderer
//
//  060 §1 — the ONE layout source of truth for text tiles. Line breaking is
//  computed once, in WORLD space, and never re-run for the viewport: `shape` has
//  no scale input at all, so for a fixed (string, fontSize, family, weight,
//  alignment, worldWidth) the line breaks and per-line origins are a pure function
//  independent of `transform.scale`. Zoom changes only the rasterization scale
//  (``TextRenderLayer``), never the layout — this is the anti-reflow invariant.
//
//  Sound on macOS specifically: CoreText renders UNHINTED with fractional glyph
//  positioning, so its metrics are linear in point size — a layout shaped at the
//  world size and drawn through a scaled CTM is geometrically what a re-shape at
//  the scaled size would give. Hinted stacks (Windows / FreeType / Android) round
//  advances to the pixel grid and would need extra work for the same guarantee.
//
//  Both measurement (``TextMetrics/size(for:maxWidth:)``, 2C) and drawing
//  (``TextRenderLayer``) read the SAME shaped result, so a drawn line break can
//  never differ from a measured one (extends the 054 §2.1 "one font source" rule
//  to cover layout).
//

import AppKit
import CoreText
import QuartzCore

/// One shaped line — a CoreText run that has ALREADY been width-broken, plus
/// where it sits in the box. Never re-broken; drawing only scales it.
struct ShapedLine {
    /// The shaped run. Line breaking is baked in (including any end-truncation).
    let line: CTLine
    /// WORLD coordinates, TOP-LEFT relative: `x` is the alignment offset within
    /// the content width; `y` is the distance from the box top DOWN to this
    /// line's baseline.
    let origin: CGPoint
}

/// A text layout computed once in world space. Carries its own ``ShapeKey`` so a
/// caller can tell "same layout?" without re-shaping (the engine's rebuild test).
struct ShapedText {
    /// Top-to-bottom, world coordinates, top-left origins.
    let lines: [ShapedLine]
    /// World-space tight size (ceiled) — what ``TextMetrics/size(for:maxWidth:)``
    /// returns, derived from these very lines so measure ≡ draw by construction.
    let size: CGSize
    /// `ascent + descent + leading` at the world font size.
    let lineHeight: CGFloat
    /// The content width this layout was broken against (`maxWidth`, or the
    /// natural width when unconstrained) — the divisor ``TextRenderLayer`` uses
    /// to derive its draw scale.
    let contentWidth: CGFloat
    /// The inputs that produced this layout. Zoom is NOT among them — the invariant.
    let key: ShapeKey
}

/// The memo key for a shaped layout. **Scale is deliberately absent** — that is
/// the whole point of 060. Widths are quantized to 1/16 pt only to kill float
/// noise (and the quantized value is what gets shaped, so the key describes the
/// layout exactly); they are NOT coarsely bucketed, because shaping against a
/// different width than the box actually has would break measure ≡ draw.
struct ShapeKey: Hashable {
    let string: String
    let fontSize: Double
    let family: String?
    let weight: FontWeight
    let alignment: TextAlignment
    /// Quantized 1/16 pt, or nil when unconstrained (autoWidth).
    let maxWidth: Int?
    /// Quantized 1/16 pt, or nil when the box does not clip (no truncation).
    let maxHeight: Int?

    init(style: TextStyle, maxWidth: CGFloat?, maxHeight: CGFloat?) {
        self.string = style.string
        self.fontSize = style.fontSize
        self.family = style.fontFamily
        self.weight = style.weight
        self.alignment = style.alignment
        self.maxWidth = Self.quantize(maxWidth)
        self.maxHeight = Self.quantize(maxHeight)
    }

    /// 1/16-pt fixed point. `nil` stays `nil`; non-finite / non-positive values
    /// are treated as "unconstrained" so a degenerate frame can't produce a
    /// zero-width shaping pass.
    static func quantize(_ value: CGFloat?) -> Int? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Int((value * 16).rounded())
    }

    /// The constraint actually shaped against — the de-quantized key value, so
    /// the key describes the layout with no residual drift.
    static func dequantize(_ value: Int?) -> CGFloat? {
        value.map { CGFloat($0) / 16 }
    }
}

/// World-space CoreText shaping — the single layout call behind both measurement
/// and drawing.
@MainActor
enum TextShaper {
    /// Shaped layouts memoized by their inputs. A board carries few distinct
    /// texts, but a live resize drag sweeps many widths, so the table is capped
    /// and cleared wholesale on overflow (cheap; a re-shape is a few hundred µs).
    private static var cache: [ShapeKey: ShapedText] = [:]
    private static let cacheLimit = 256

    /// Drop every memoized layout. Tests only — production never needs it (the
    /// key covers every input, so a stale entry is impossible).
    static func resetCache() { cache.removeAll(keepingCapacity: true) }

    /// The world-space layout for `style`.
    ///
    /// - Parameters:
    ///   - maxWidth: `nil` shapes unconstrained (autoWidth / a `.fixed` one-liner)
    ///     — the box grows to the longest line; a value wraps to that width
    ///     (autoHeight / overflowing `.fixed`).
    ///   - maxHeight: when set, lines past the box bottom are dropped and the last
    ///     visible line gets an end-ellipsis (``CTLineCreateTruncatedLine``) —
    ///     computed HERE, at shape time, because the cut point is pure world
    ///     geometry and so is zoom-stable. `nil` never truncates (every
    ///     measurement caller).
    static func shape(_ style: TextStyle, maxWidth: CGFloat?, maxHeight: CGFloat? = nil) -> ShapedText {
        let key = ShapeKey(style: style, maxWidth: maxWidth, maxHeight: maxHeight)
        if let hit = cache[key] { return hit }
        let shaped = build(style, key: key)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = shaped
        return shaped
    }

    // MARK: -

    private static func build(_ style: TextStyle, key: ShapeKey) -> ShapedText {
        let maxWidth = ShapeKey.dequantize(key.maxWidth)
        let maxHeight = ShapeKey.dequantize(key.maxHeight)

        // Same font construction as 2A/2C drawing + measurement: the memoized
        // typeface copied to the WORLD point size (never a zoom-scaled one).
        let pointSize = CGFloat(max(1, style.fontSize))
        let base = CanvasFont.resolve(family: style.fontFamily, weight: style.weight)
        let font = CTFontCreateCopyWithAttributes(base, pointSize, nil, nil)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = ascent + descent + CTFontGetLeading(font)

        // An empty string still occupies one line (a lone space) so an empty auto
        // box never collapses to zero height — matches 2C's measurement rule.
        let string = style.string.isEmpty ? " " : style.string
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // Alignment is applied as a per-line pen offset below (one source of
        // truth, and the ONLY way to align a truncated line we build ourselves),
        // so the paragraph style stays alignment-free on purpose.
        //
        // Colour is deliberately absent: it cannot move a line break, so keeping
        // it out of the layout means a recolour never costs a re-shape. The
        // runs take the drawing context's fill colour instead
        // (``TextRenderLayer`` sets it per frame).
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(attributed)

        // Pass 1 — the box CoreText wants, so pass 2 frames a sane finite height
        // (a "huge" path height is the classic source of CTFrame weirdness).
        var fitRange = CFRange()
        let constraint = CGSize(
            width: maxWidth ?? .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil, constraint, &fitRange)

        let boxWidth = max(1, maxWidth ?? ceil(suggested.width))
        // One extra line of slack: CTFrame CLIPS lines that don't fit its path.
        let boxHeight = max(lineHeight, ceil(suggested.height)) + lineHeight

        // Pass 2 — the shaped lines themselves.
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        guard !ctLines.isEmpty else {
            return ShapedText(lines: [], size: CGSize(width: 0, height: ceil(lineHeight)),
                              lineHeight: lineHeight, contentWidth: boxWidth, key: key)
        }
        var bottomUpOrigins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &bottomUpOrigins)
        // CTFrame origins are y-up from the path's bottom; we work top-left down.
        let baselines = bottomUpOrigins.map { boxHeight - $0.y }

        // Clip + end-truncate to the box height (world geometry → zoom-stable).
        let visible = truncated(
            ctLines, baselines: baselines, attributed: attributed, attributes: attributes,
            descent: descent, boxWidth: boxWidth, maxHeight: maxHeight)

        // Alignment as a pen offset within the content width — applied uniformly
        // to shaped and truncated lines alike.
        let flush = style.alignment.flushFactor
        let lines = visible.enumerated().map { index, line in
            ShapedLine(
                line: line,
                origin: CGPoint(
                    x: CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(boxWidth))),
                    y: baselines[index]))
        }

        // Size derived from these very lines — measure ≡ draw by construction.
        let inkWidth = lines.map { lineWidth($0.line) }.max() ?? 0
        let lastBottom = (lines.last?.origin.y ?? ascent) + descent
        let size = CGSize(
            width: min(ceil(inkWidth), ceil(boxWidth)),
            height: ceil(max(lineHeight, lastBottom)))

        return ShapedText(lines: lines, size: size, lineHeight: lineHeight,
                          contentWidth: boxWidth, key: key)
    }

    /// The lines that fit `maxHeight`, with the last one end-truncated when text
    /// was dropped. `nil` height (or everything fits) returns the input unchanged.
    private static func truncated(
        _ ctLines: [CTLine], baselines: [CGFloat], attributed: NSAttributedString,
        attributes: [NSAttributedString.Key: Any], descent: CGFloat,
        boxWidth: CGFloat, maxHeight: CGFloat?
    ) -> [CTLine] {
        guard let maxHeight else { return ctLines }
        // A line is visible when its whole box (baseline + descent) clears the
        // bottom. Always keep at least one, so a too-short box still shows text.
        var kept = 0
        for index in ctLines.indices {
            guard baselines[index] + descent <= maxHeight + 0.5 else { break }
            kept = index + 1
        }
        kept = max(1, kept)
        guard kept < ctLines.count else { return ctLines }

        var result = Array(ctLines.prefix(kept))
        // Truncate over the text REMAINING from the last visible line onward (not
        // just that line's own run) so the ellipsis stands for the dropped text —
        // matching `CATextLayer.truncationMode = .end`.
        let start = CTLineGetStringRange(ctLines[kept - 1]).location
        let length = attributed.length - Int(start)
        guard length > 0 else { return result }
        let remainder = attributed.attributedSubstring(
            from: NSRange(location: Int(start), length: length))
        let full = CTLineCreateWithAttributedString(remainder as CFAttributedString)
        // The token inherits NOTHING — it must carry the same world-size
        // attributes as the run it ends.
        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: attributes) as CFAttributedString)
        // Returns nil when the token alone is wider than the box — keep the
        // untruncated line rather than dropping it.
        if let cut = CTLineCreateTruncatedLine(full, Double(boxWidth), .end, token) {
            result[kept - 1] = cut
        }
        return result
    }

    /// A line's ink width — typographic width less trailing whitespace, so a
    /// wrapped line's trailing space doesn't inflate the measured box.
    private static func lineWidth(_ line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return max(0, CGFloat(width - CTLineGetTrailingWhitespaceWidth(line)))
    }
}

extension TextAlignment {
    /// The CoreText flush factor for ``CTLineGetPenOffsetForFlush``.
    var flushFactor: Double {
        switch self {
        case .left: return 0
        case .center: return 0.5
        case .right: return 1
        }
    }
}
