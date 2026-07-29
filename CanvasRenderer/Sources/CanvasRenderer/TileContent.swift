import CoreGraphics

/// What a ``Tile`` draws (E3 — decision T3, the *hybrid* renderer).
///
/// `image` is the **untouched** pooled / culled / LOD / decode path — the
/// benchmark-gated 4.6 ms/frame for thousands of thumbnails. `frame` and `text`
/// are *freeform elements*: crisp vector siblings that bypass the decode pipeline
/// entirely (they number in the dozens per board, not thousands). Providers that
/// only draw images need no change — the ``TileProvider`` default is `.image`.
public enum TileContent: Equatable, Sendable {
    /// An image tile — the existing decode-and-cache path.
    case image
    /// A freeform frame: a labeled rectangle (fill / border / corner / label).
    case frame(FrameStyle)
    /// A freeform text box.
    case text(TextStyle)
}

/// A device-RGBA colour in the `0...1` range — a `Sendable`, value-type stand-in
/// for `CGColor` across the renderer seam (`CGColor` is not `Sendable`). The
/// engine converts to `CGColor` at draw time.
public struct RGBAColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Fully transparent — the default for an unspecified fill.
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

extension RGBAColor {
    /// The matching `CGColor` in device RGB. Engine-internal (drawing only).
    var cgColor: CGColor {
        CGColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// A frame element's presentation (E3). A labeled rectangle: an optional `fill`,
/// an optional `stroke` border of `strokeWidth`, an optional `cornerRadius`, and
/// an optional `label` drawn inside the top-left. `strokeWidth` / `cornerRadius`
/// are **world units** — the engine scales them by the current zoom so a frame's
/// border keeps a constant world thickness (like the tiles it groups).
public struct FrameStyle: Equatable, Hashable, Sendable {
    public var fill: RGBAColor?
    public var stroke: RGBAColor?
    public var strokeWidth: Double
    public var cornerRadius: Double
    public var label: TextStyle?

    public init(
        fill: RGBAColor? = nil,
        stroke: RGBAColor? = nil,
        strokeWidth: Double = 0,
        cornerRadius: Double = 0,
        label: TextStyle? = nil
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.label = label
    }
}

/// A text element's font weight — mirrors `AtelierCore.TextWeight`. The rawValues
/// MUST match the domain tokens (the bridge is a rawValue hop; enforced by a
/// conformance test, not a comment). The renderer can't import `AtelierCore`.
public enum FontWeight: String, Hashable, Sendable, CaseIterable {
    case regular, medium, semibold, bold
}

/// A text element's horizontal alignment — mirrors `AtelierCore.TextAlign`. Same
/// rawValue-match contract as ``FontWeight``.
public enum TextAlignment: String, Hashable, Sendable, CaseIterable {
    case left, center, right
}

/// A text element's presentation (E3). `fontSize` is a **world unit** — the engine
/// multiplies it by the current zoom so the glyphs scale with the board and stay
/// crisp (a `CATextLayer` re-rasterizes per frame at the on-screen point size).
public struct TextStyle: Equatable, Hashable, Sendable {
    public var string: String
    public var fontSize: Double
    public var color: RGBAColor
    /// Font family name; nil → the system font.
    public var fontFamily: String?
    /// Font weight (default `.regular`).
    public var weight: FontWeight
    /// Horizontal alignment (default `.left`).
    public var alignment: TextAlignment
    /// The box derives its own width from the text rather than being given one (063).
    ///
    /// Read by the inline editor, to decide whether to measure unconstrained. The DRAW
    /// path ignores it: a committed hugging box already has its hugged width stored in
    /// `tile.w`, so the renderer stays mode-agnostic (054 §R1) and wraps at whatever
    /// width it is handed.
    ///
    /// It does ride into ``TextShaper/ShapeKey`` — which stores the whole style — but
    /// is not a shaping input: `maxWidth` comes from the caller. Harmless (two boxes
    /// differing only in this flag get separate cache entries and identical layouts);
    /// noted so a future reader doesn't mistake it for one.
    public var hugsWidth: Bool

    public init(
        string: String,
        fontSize: Double,
        color: RGBAColor,
        fontFamily: String? = nil,
        weight: FontWeight = .regular,
        alignment: TextAlignment = .left,
        hugsWidth: Bool = false
    ) {
        self.string = string
        self.fontSize = fontSize
        self.color = color
        self.fontFamily = fontFamily
        self.weight = weight
        self.alignment = alignment
        self.hugsWidth = hugsWidth
    }
}
