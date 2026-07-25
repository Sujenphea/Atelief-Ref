// AtelierExport — the PDF / PNG renderer (052 · B2, 13A/15A/16A)
//
// Consumes a `[LayoutPage]` (from ``MoodboardLayout`` today, the contact sheet
// tomorrow) and draws it into a CoreGraphics context. PDF and PNG share ONE
// draw routine — only the context factory differs — so the two formats can
// never diverge in how an element lands on the page.
//
// Memory (052 · 13A): elements draw in `z` order inside a per-element
// `autoreleasepool`; image bytes are requested from the provider sized to that
// element's on-page footprint and released before the next element. Peak
// footprint ≈ one image, not the board.
//
// Threading (052 · 15A): synchronous and self-contained — the app calls it from
// a background `Task` and passes `isCancelled: { Task.isCancelled }` to bail
// promptly; the renderer itself touches no global state and no main actor.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stateless render entry points. All members `static`.
public enum MoodboardRenderer {

    /// Render every page into a single multi-page PDF (vector page container,
    /// images embedded at `options.pixelsPerPoint` resolution).
    ///
    /// - Throws: ``ExportError/noPages`` for an empty layout,
    ///   ``ExportError/contextCreationFailed`` if the PDF context won't open, or
    ///   `CancellationError` if `isCancelled` trips mid-render.
    public static func renderPDF(
        pages: [LayoutPage],
        provider: MoodboardImageProvider?,
        options: RenderOptions = .pdfDefault,
        isCancelled: () -> Bool = { false }
    ) throws -> RenderResult {
        guard let first = pages.first else { throw ExportError.noPages }

        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData) else {
            throw ExportError.contextCreationFailed
        }
        // All pages in one render share a size (a single fit page, or a uniform
        // paper size), so one media box serves the document.
        var mediaBox = CGRect(origin: .zero, size: first.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }

        var skipped: [SkippedElement] = []
        for page in pages {
            try throwIfCancelled(isCancelled)
            context.beginPDFPage(nil)
            drawPage(
                page, in: context, provider: provider,
                options: options, skipped: &skipped, isCancelled: isCancelled)
            context.endPDFPage()
        }
        context.closePDF()
        return RenderResult(data: buffer as Data, skipped: skipped)
    }

    /// Render ONE page to a PNG at `options.pixelsPerPoint` (page points ×
    /// pixels-per-point = pixel dimensions). A paginated moodboard calls this
    /// once per page; a fit moodboard calls it once for its single page.
    ///
    /// - Throws: ``ExportError/contextCreationFailed`` if the bitmap won't
    ///   allocate, ``ExportError/imageEncodingFailed`` if PNG encoding fails, or
    ///   `CancellationError`.
    public static func renderPNG(
        page: LayoutPage,
        provider: MoodboardImageProvider?,
        options: RenderOptions = RenderOptions(),
        isCancelled: () -> Bool = { false }
    ) throws -> RenderResult {
        let scale = options.pixelsPerPoint
        let pixelWidth = Int((page.size.width * scale).rounded())
        let pixelHeight = Int((page.size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { throw ExportError.contextCreationFailed }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ExportError.contextCreationFailed }

        // Map point space onto the pixel bitmap so the shared draw routine works
        // in points exactly like the PDF path.
        context.scaleBy(x: scale, y: scale)

        var skipped: [SkippedElement] = []
        drawPage(
            page, in: context, provider: provider,
            options: options, skipped: &skipped, isCancelled: isCancelled)

        try throwIfCancelled(isCancelled)
        guard let image = context.makeImage() else { throw ExportError.imageEncodingFailed }
        let data = try encodePNG(image)
        return RenderResult(data: data, skipped: skipped)
    }

    // MARK: - Shared draw routine

    /// Paint one page's background and every element, in `z` order, into a
    /// point-space context (y-up). Used identically by the PDF and PNG paths.
    private static func drawPage(
        _ page: LayoutPage,
        in context: CGContext,
        provider: MoodboardImageProvider?,
        options: RenderOptions,
        skipped: inout [SkippedElement],
        isCancelled: () -> Bool
    ) {
        if let background = options.background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(origin: .zero, size: page.size))
        }

        for element in page.elements.sorted(by: { $0.z < $1.z }) {
            if isCancelled() { return }
            autoreleasepool {
                context.saveGState()
                context.clip(to: element.clip)
                draw(element, in: context, provider: provider,
                     pixelsPerPoint: options.pixelsPerPoint, skipped: &skipped)
                context.restoreGState()
            }
        }
    }

    /// The one documented switch over element kinds (mirrors the pasteboard
    /// contract's single switch, 052 · 8A).
    private static func draw(
        _ element: PlacedElement,
        in context: CGContext,
        provider: MoodboardImageProvider?,
        pixelsPerPoint: Double,
        skipped: inout [SkippedElement]
    ) {
        switch element.content {
        case .image(let id):
            drawImage(id: id, frame: element.frame, in: context,
                      provider: provider, pixelsPerPoint: pixelsPerPoint, skipped: &skipped)
        case .color(let rgba):
            context.setFillColor(rgba.cgColor)
            context.fill(element.frame)
        case .text(let style):
            drawText(style, in: element.frame, scale: element.scale, in: context)
        case .frame(let style):
            drawFrame(style, frame: element.frame, scale: element.scale, in: context)
        }
    }

    private static func drawImage(
        id: String,
        frame: CGRect,
        in context: CGContext,
        provider: MoodboardImageProvider?,
        pixelsPerPoint: Double,
        skipped: inout [SkippedElement]
    ) {
        guard let provider else {
            skipped.append(SkippedElement(id: id, reason: .noProvider))
            return
        }
        // Decode sized to the element's on-page pixel footprint (052 · 13A).
        let longestEdge = Swift.max(frame.width, frame.height) * pixelsPerPoint
        let maxPixelSize = Swift.max(1, Int(longestEdge.rounded()))
        guard let image = provider.cgImage(forID: id, maxPixelSize: maxPixelSize) else {
            skipped.append(SkippedElement(id: id, reason: .missingImage))
            return
        }
        context.draw(image, in: frame)
    }

    /// Draw wrapped text within `rect` using CoreText (no AppKit — keeps the
    /// package headless-testable). `scale` converts the world-unit point size to
    /// page points.
    private static func drawText(
        _ style: TextStyle,
        in rect: CGRect,
        scale: Double,
        in context: CGContext
    ) {
        guard !style.string.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let pointSize = Swift.max(1, style.fontSize * scale)
        let font = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(rawValue: kCTFontAttributeName as String): font,
            .init(rawValue: kCTForegroundColorAttributeName as String): style.color.cgColor,
        ]
        let attributed = NSAttributedString(string: style.string, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func drawFrame(
        _ style: FrameStyle,
        frame rect: CGRect,
        scale: Double,
        in context: CGContext
    ) {
        if let fill = style.fill {
            context.setFillColor(fill.cgColor)
            context.fill(rect)
        }
        if let stroke = style.stroke, style.strokeWidth > 0 {
            let width = style.strokeWidth * scale
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(width)
            // Inset by half the line width so the stroke stays inside the rect
            // rather than straddling and bleeding past the element bounds.
            context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
        }
        if let label = style.label {
            // Inset the label a little from the frame's top-left corner.
            let inset = rect.insetBy(dx: Swift.min(6, rect.width / 8), dy: Swift.min(6, rect.height / 8))
            drawText(label, in: inset, scale: scale, in: context)
        }
    }

    // MARK: - Encoding

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.imageEncodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.imageEncodingFailed }
        return data as Data
    }

    private static func throwIfCancelled(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
