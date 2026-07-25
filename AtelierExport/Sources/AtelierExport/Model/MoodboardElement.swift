// AtelierExport — the package-local moodboard input model (052 · B2)
//
// The app maps its domain rows (`SpaceItem` geometry + `AssetContent` /
// `ElementStyle`) into these value types before handing them to the layout
// engine, so this package never imports AtelierCore. Everything here is in
// WORLD units (the board's own coordinate space): `rect` is the `SpaceItem`
// x/y/w/h (y-DOWN, matching the canvas), `z` is its stacking order (lower draws
// first), and the size-bearing style fields (`fontSize`, `strokeWidth`) are in
// world units too. The layout engine converts world → page points once; see
// ``PlacedElement``.

import CoreGraphics

/// One placeable thing on a moodboard, in world coordinates.
public struct MoodboardElement: Equatable, Sendable {
    /// World-space rect (`SpaceItem` x/y/w/h). Origin top-left, y increases
    /// downward — the same convention as the canvas board.
    public var rect: CGRect
    /// Stacking order; lower draws first (behind). Ties break by input order.
    public var z: Int
    /// What to draw inside ``rect``.
    public var content: MoodboardContent

    public init(rect: CGRect, z: Int, content: MoodboardContent) {
        self.rect = rect
        self.z = z
        self.content = content
    }
}

/// What a ``MoodboardElement`` draws. One case per renderable kind; the
/// non-renderable asset kinds (a `.link` / `.tweet` with no image, an unknown
/// blob) are filtered out by the app's mapping and never reach the package —
/// they surface as a skip-with-report at the selection seam (052 · 7A).
public enum MoodboardContent: Equatable, Sendable {
    /// A raster reference resolved lazily at render time by
    /// ``MoodboardImageProvider`` (image assets, video posters, image-backed
    /// link / tweet cards). `id` is opaque to the package.
    case image(id: String)
    /// A solid colour swatch (`AssetContent.color`).
    case color(RGBA)
    /// A text element (`SpaceItemKind.text`).
    case text(TextStyle)
    /// A freeform frame element (`SpaceItemKind.frame`): fill + border, with an
    /// optional label.
    case frame(FrameStyle)
}

/// A text element's presentation, mapped from `ElementStyle`. `fontSize` is in
/// WORLD units (scaled to page points by the renderer via
/// ``PlacedElement/scale``).
public struct TextStyle: Equatable, Sendable {
    public var string: String
    public var fontSize: Double
    public var color: RGBA

    /// - Parameters:
    ///   - string: the text to draw (wrapped within the element rect).
    ///   - fontSize: point size in WORLD units.
    ///   - color: fill colour; defaults to opaque black.
    public init(string: String, fontSize: Double, color: RGBA = .black) {
        self.string = string
        self.fontSize = fontSize
        self.color = color
    }
}

/// A frame element's presentation, mapped from `ElementStyle`. `strokeWidth` and
/// the label's `fontSize` are in WORLD units. A `nil` fill / stroke means that
/// pass is skipped (a fill-less frame draws only its border, and vice versa).
public struct FrameStyle: Equatable, Sendable {
    public var fill: RGBA?
    public var stroke: RGBA?
    public var strokeWidth: Double
    /// Optional label drawn top-left inside the frame; reuses the text fields.
    public var label: TextStyle?

    public init(
        fill: RGBA? = nil,
        stroke: RGBA? = nil,
        strokeWidth: Double = 0,
        label: TextStyle? = nil
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.label = label
    }
}
