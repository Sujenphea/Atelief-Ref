// AtelierExport — render structural + pixel tests (052 · 10A layers 2–3)
//
// Layer 2: structural assertions on the encoded output — PDF page count and
// media-box size via `CGPDFDocument`, PNG pixel dimensions.
// Layer 3: a lightweight pixel probe (no committed golden files, so nothing to
// quarantine on a CI GPU): render known content and read back specific pixels.

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AtelierExport

@Suite("Moodboard renderer")
struct MoodboardRendererTests {

    // MARK: - Fixtures

    /// A provider that hands back a solid-colour image for every id, and records
    /// the sizes it was asked for (so the 13A footprint sizing can be checked).
    private final class SolidProvider: MoodboardImageProvider {
        let color: RGBA
        var requestedSizes: [Int] = []
        init(_ color: RGBA) { self.color = color }
        func cgImage(forID id: String, maxPixelSize: Int) -> CGImage? {
            requestedSizes.append(maxPixelSize)
            return Self.solid(color, side: 8)
        }
        static func solid(_ c: RGBA, side: Int) -> CGImage {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: 0, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return ctx.makeImage()!
        }
    }

    /// A provider that never resolves — every request is a miss.
    private struct MissingProvider: MoodboardImageProvider {
        func cgImage(forID id: String, maxPixelSize: Int) -> CGImage? { nil }
    }

    private func page(_ elements: [PlacedElement], size: CGSize = CGSize(width: 100, height: 100))
        -> LayoutPage
    { LayoutPage(size: size, elements: elements) }

    private func placed(
        _ content: MoodboardContent,
        frame: CGRect,
        z: Int = 0,
        scale: Double = 1,
        clip: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    ) -> PlacedElement {
        PlacedElement(frame: frame, clip: clip, z: z, scale: scale, content: content)
    }

    /// Read an sRGB pixel from encoded PNG bytes.
    private func pixel(in data: Data, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let width = image.width, height = image.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Drawing the decoded image into this bitmap lands its top row at buffer
        // row 0, so a top-left y maps straight to the row index.
        let i = (y * width + x) * 4
        return (Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2]), Int(buffer[i + 3]))
    }

    // MARK: - PDF structure (layer 2)

    @Test("PDF has one page per layout page, each at the page size")
    func pdfPageCountAndBox() throws {
        let pages = [
            page([placed(.color(.black), frame: CGRect(x: 10, y: 10, width: 20, height: 20))]),
            page([placed(.color(.white), frame: CGRect(x: 10, y: 10, width: 20, height: 20))]),
        ]
        let result = try MoodboardRenderer.renderPDF(pages: pages, provider: nil)
        let doc = try #require(CGPDFDocument(
            CGDataProvider(data: result.data as CFData)!))
        #expect(doc.numberOfPages == 2)
        let box = try #require(doc.page(at: 1)).getBoxRect(.mediaBox)
        #expect(box.size == CGSize(width: 100, height: 100))
    }

    @Test("Empty layout throws noPages")
    func pdfEmpty() {
        #expect(throws: ExportError.noPages) {
            try MoodboardRenderer.renderPDF(pages: [], provider: nil)
        }
    }

    // MARK: - PNG structure + pixels (layers 2–3)

    @Test("PNG pixel dimensions are page points × pixels-per-point")
    func pngDimensions() throws {
        let result = try MoodboardRenderer.renderPNG(
            page: page([]),
            provider: nil,
            options: RenderOptions(background: .white, pixelsPerPoint: 2))
        let src = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(image.width == 200)   // 100 pt × 2
        #expect(image.height == 200)
    }

    @Test("Background fills the page")
    func pngBackground() throws {
        let result = try MoodboardRenderer.renderPNG(
            page: page([]), provider: nil,
            options: RenderOptions(background: .white, pixelsPerPoint: 1))
        let corner = try pixel(in: result.data, x: 0, y: 0)
        #expect(corner.r == 255 && corner.g == 255 && corner.b == 255)
    }

    @Test("Colour swatch paints its rect")
    func pngColorSwatch() throws {
        // Red swatch covering the top-left quadrant (world y-down -> page top).
        let red = try #require(RGBA(hex: "#ff0000"))
        let el = placed(.color(red), frame: CGRect(x: 0, y: 60, width: 40, height: 40))
        let result = try MoodboardRenderer.renderPNG(
            page: page([el]), provider: nil,
            options: RenderOptions(background: .white, pixelsPerPoint: 1))
        // Inside the swatch (page-y 60..100, so top-left in flipped read space).
        let inside = try pixel(in: result.data, x: 20, y: 20)
        #expect(inside.r == 255 && inside.g == 0 && inside.b == 0)
        // Outside stays white.
        let outside = try pixel(in: result.data, x: 80, y: 80)
        #expect(outside.r == 255 && outside.g == 255 && outside.b == 255)
    }

    @Test("Image element draws the provider's pixels, sized to footprint")
    func pngImage() throws {
        let green = try #require(RGBA(hex: "#00ff00"))
        let provider = SolidProvider(green)
        let el = placed(.image(id: "a"), frame: CGRect(x: 0, y: 60, width: 40, height: 40))
        let result = try MoodboardRenderer.renderPNG(
            page: page([el]), provider: provider,
            options: RenderOptions(background: .white, pixelsPerPoint: 2))
        let inside = try pixel(in: result.data, x: 20 * 2, y: 20 * 2)
        #expect(inside.g == 255 && inside.r == 0 && inside.b == 0)
        // 13A: decode was requested sized to the footprint (40 pt × 2 = 80 px).
        #expect(provider.requestedSizes == [80])
        #expect(result.skipped.isEmpty)
    }

    // MARK: - Skip report (7A)

    @Test("A missing image is skipped with a report, not a failure")
    func missingImageSkipped() throws {
        let el = placed(.image(id: "gone"), frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let result = try MoodboardRenderer.renderPNG(page: page([el]), provider: MissingProvider())
        #expect(result.skipped == [SkippedElement(id: "gone", reason: .missingImage)])
    }

    @Test("An image with no provider is skipped as noProvider")
    func noProviderSkipped() throws {
        let el = placed(.image(id: "x"), frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let result = try MoodboardRenderer.renderPDF(pages: [page([el])], provider: nil)
        #expect(result.skipped == [SkippedElement(id: "x", reason: .noProvider)])
    }

    // MARK: - Progress (15A)

    @Test("Progress advances per element and finishes at 1")
    func progress() throws {
        let els = (0..<4).map {
            placed(.color(.black), frame: CGRect(x: 0, y: Double($0) * 10, width: 10, height: 10))
        }
        var ticks: [Double] = []
        _ = try MoodboardRenderer.renderPNG(
            page: page(els), provider: nil, onProgress: { ticks.append($0) })
        // One tick per element (0.25, 0.5, 0.75, 1.0) plus the final 1.0.
        #expect(ticks.contains(0.25))
        #expect(ticks.contains(1.0))
        #expect(ticks.last == 1.0)
        // Monotonic non-decreasing.
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Empty layout still signals completion")
    func progressEmpty() throws {
        var last: Double = -1
        _ = try MoodboardRenderer.renderPNG(page: page([]), provider: nil, onProgress: { last = $0 })
        #expect(last == 1)
    }

    // MARK: - Cancellation (15A)

    @Test("Cancellation aborts the render")
    func cancellation() {
        #expect(throws: CancellationError.self) {
            try MoodboardRenderer.renderPDF(
                pages: [page([])], provider: nil, isCancelled: { true })
        }
    }
}
