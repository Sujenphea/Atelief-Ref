// AtelierExport — render knobs shared by the PDF and PNG paths (052 · B2)

import CoreGraphics

/// Output-format-independent render settings. The same `[LayoutPage]` renders
/// to PDF or PNG through these; only the context factory differs.
public struct RenderOptions: Equatable, Sendable {
    /// Page background painted before any element, or `nil` to leave the page
    /// transparent (PNG) / unpainted (PDF). Defaults to opaque white.
    public var background: RGBA?

    /// Pixels per point used to size image decode requests and to rasterise the
    /// PNG. 1.0 = 72 dpi, 2.0 = 144 dpi ("retina"), etc.
    ///
    /// For PDF this only bounds how large each embedded image is decoded (the
    /// page geometry stays vector); for PNG it also sets the output bitmap's
    /// pixel dimensions (`pageSize × pixelsPerPoint`). Clamped to ≥ 0.1.
    public var pixelsPerPoint: Double

    public init(background: RGBA? = .white, pixelsPerPoint: Double = 2) {
        self.background = background
        self.pixelsPerPoint = Swift.max(0.1, pixelsPerPoint)
    }

    /// A convenience for the common US-Letter-at-72-dpi PDF baseline.
    public static let pdfDefault = RenderOptions(background: .white, pixelsPerPoint: 2)
}
