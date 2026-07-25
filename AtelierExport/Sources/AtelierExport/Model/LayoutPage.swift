// AtelierExport — the layout OUTPUT model (052 · B2, shared engine)
//
// A `[LayoutPage]` is the seam between layout and render: the moodboard layout
// is its first producer, the contact sheet (B4) will be a second, and
// ``MoodboardRenderer`` consumes either without change. Unlike the world-space
// input model, everything here is in PAGE POINTS (1 pt = 1/72"), y-UP — the
// native CoreGraphics context space — so the renderer draws with no coordinate
// gymnastics and images / text come out upright.

import CoreGraphics

/// One rendered page: a point-sized canvas plus the elements placed on it.
public struct LayoutPage: Equatable, Sendable {
    /// Page size in points. All pages in one render share a size (a single fit
    /// page, or the uniform paper size of a paginated run).
    public var size: CGSize
    /// The elements on this page, in input order (the renderer sorts by `z`).
    public var elements: [PlacedElement]

    public init(size: CGSize, elements: [PlacedElement]) {
        self.size = size
        self.elements = elements
    }
}

/// One element positioned on a page. `frame` is in page points (y-up, already
/// scaled from world), and `clip` bounds the drawing to the page's content area
/// so an element straddling a page boundary in a paginated run cannot bleed
/// across the margin. World-unit style fields inside `content` (`fontSize`,
/// `strokeWidth`) are left verbatim and multiplied by ``scale`` at draw time —
/// keeping a single content enum rather than a parallel page-space copy.
public struct PlacedElement: Equatable, Sendable {
    /// Destination rect in page points (y-up).
    public var frame: CGRect
    /// Clip rect in page points; drawing is confined to it.
    public var clip: CGRect
    /// Stacking order carried through from the source element.
    public var z: Int
    /// Points per world unit — the factor to convert `content`'s world-unit
    /// sizes (`fontSize`, `strokeWidth`) into page points.
    public var scale: Double
    /// What to draw. Geometry is described by `frame`; only the world-unit size
    /// fields still need `scale` applied.
    public var content: MoodboardContent

    public init(
        frame: CGRect,
        clip: CGRect,
        z: Int,
        scale: Double,
        content: MoodboardContent
    ) {
        self.frame = frame
        self.clip = clip
        self.z = z
        self.scale = scale
        self.content = content
    }
}
