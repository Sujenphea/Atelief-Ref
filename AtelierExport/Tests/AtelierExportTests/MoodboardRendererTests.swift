// AtelierExport — render structural + pixel tests (052 · 10A layers 2–3)
//
// Layer 2: structural assertions on the encoded output — PDF page count and
// media-box size via `CGPDFDocument`, PNG pixel dimensions.
// Layer 3: a lightweight pixel probe (no committed golden files, so nothing to
// quarantine on a CI GPU): render known content and read back specific pixels.

import CoreGraphics
import CoreText
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

    /// The full sRGB byte buffer behind encoded PNG bytes. The text probes below
    /// compare rasters rather than named pixels: a glyph's ink lands wherever the
    /// face and the alignment put it, so "did this style change what was drawn?"
    /// is a question about the whole box, not about one coordinate that a
    /// different face might miss by a pixel.
    private func raster(_ data: Data) throws -> [UInt8] {
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
        return buffer
    }

    /// Render one text element filling the page, and hand back its raster.
    private func textRaster(_ style: TextStyle) throws -> [UInt8] {
        let el = placed(.text(style), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let result = try MoodboardRenderer.renderPNG(
            page: page([el]), provider: nil,
            options: RenderOptions(background: .white, pixelsPerPoint: 1))
        return try raster(result.data)
    }

    /// How many pixels in a raster carry ink (anything darker than the white
    /// background). A raster with no ink means nothing was drawn, which would make
    /// every "these two differ" assertion below pass for the wrong reason.
    private func inkCount(_ buffer: [UInt8]) -> Int {
        stride(from: 0, to: buffer.count, by: 4).count { buffer[$0] < 250 }
    }

    /// Ink in the left half of a `width`-pixel-wide raster — how the alignment
    /// probe asserts that the glyphs MOVED, not merely that the bytes differ.
    private func inkInLeftHalf(_ buffer: [UInt8], width: Int) -> Int {
        stride(from: 0, to: buffer.count, by: 4).count {
            buffer[$0] < 250 && (($0 / 4) % width) < width / 2
        }
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

    // MARK: - Text style: family / weight / alignment (2A)

    /// The style every probe below varies exactly one field of.
    private static let baseText = TextStyle(
        string: "Hamburgefonstiv", fontSize: 18, color: .black)

    @Test("Text draws ink at all (the baseline every 2A probe is measured against)")
    func textDrawsInk() throws {
        let ink = inkCount(try textRaster(Self.baseText))
        #expect(ink > 0)
    }

    @Test("fontFamily changes the raster")
    func textFamilyChangesRaster() throws {
        var courier = Self.baseText
        courier.fontFamily = "Courier"
        var helvetica = Self.baseText
        helvetica.fontFamily = "Helvetica"
        let a = try textRaster(courier)
        let b = try textRaster(helvetica)
        #expect(inkCount(a) > 0 && inkCount(b) > 0)
        #expect(a != b)
    }

    @Test("weight changes the raster")
    func textWeightChangesRaster() throws {
        // A family with a real Bold face, so the probe measures the weight trait
        // resolving to a different face rather than a synthesized emboldening.
        var regular = Self.baseText
        regular.fontFamily = "Helvetica"
        var bold = regular
        bold.weight = .bold
        let a = try textRaster(regular)
        let b = try textRaster(bold)
        #expect(inkCount(a) > 0 && inkCount(b) > 0)
        #expect(a != b)
        // Bold lays down more ink than regular at the same size and family.
        #expect(inkCount(b) > inkCount(a))
    }

    @Test("alignment changes the raster")
    func textAlignmentChangesRaster() throws {
        var left = Self.baseText
        left.alignment = .left
        var right = Self.baseText
        right.alignment = .right
        var centered = Self.baseText
        centered.alignment = .center
        let l = try textRaster(left)
        let r = try textRaster(right)
        let c = try textRaster(centered)
        #expect(inkCount(l) > 0)
        #expect(l != r)
        #expect(l != c)
        #expect(c != r)
        // Not merely "different" — the ink MOVED the way the token says. The page
        // is 100 pt wide and the string is narrower than that, so a left-aligned
        // line puts more ink in the left half than a right-aligned one does.
        #expect(inkInLeftHalf(l, width: 100) > inkInLeftHalf(r, width: 100))
        #expect(inkInLeftHalf(l, width: 100) > inkInLeftHalf(c, width: 100))
        #expect(inkInLeftHalf(c, width: 100) > inkInLeftHalf(r, width: 100))
    }

    @Test("An unknown family falls back to the system font")
    func textUnknownFamilyFallsBack() throws {
        var unknown = Self.baseText
        unknown.fontFamily = "ZzThisFamilyIsNotInstalledZz"
        let fallback = try textRaster(unknown)
        // Byte-identical to asking for no family at all — the fallback IS the
        // system font, not merely "some other font".
        #expect(fallback == (try textRaster(Self.baseText)))
        #expect(inkCount(fallback) > 0)
    }

    @Test("font(family:weight:size:) resolves family, weight and the unknown-family fallback")
    func fontResolution() throws {
        let system = MoodboardRenderer.font(family: nil, weight: .regular, size: 24)
        let systemName = CTFontCopyPostScriptName(system) as String

        // A named family is honoured…
        let helvetica = MoodboardRenderer.font(family: "Helvetica", weight: .regular, size: 24)
        #expect((CTFontCopyFamilyName(helvetica) as String) == "Helvetica")
        // …and the weight trait picks that family's Bold face.
        let bold = MoodboardRenderer.font(family: "Helvetica", weight: .bold, size: 24)
        #expect((CTFontCopyPostScriptName(bold) as String) != (CTFontCopyPostScriptName(helvetica) as String))

        // An unknown family lands on the system font, not on a default face.
        let unknown = MoodboardRenderer.font(
            family: "ZzThisFamilyIsNotInstalledZz", weight: .regular, size: 24)
        #expect((CTFontCopyPostScriptName(unknown) as String) == systemName)

        // The system font carries the weight axis too.
        let systemBold = MoodboardRenderer.font(family: nil, weight: .bold, size: 24)
        #expect((CTFontCopyPostScriptName(systemBold) as String) != systemName)
    }

    @Test("An empty family string is treated as no family")
    func textEmptyFamilyIsSystem() throws {
        var empty = Self.baseText
        empty.fontFamily = ""
        #expect(try textRaster(empty) == (try textRaster(Self.baseText)))
    }

    @Test("FrameStyle.label inherits family, weight and alignment")
    func frameLabelInheritsTextFields() throws {
        func frameRaster(_ label: TextStyle) throws -> [UInt8] {
            let style = FrameStyle(
                fill: .white, stroke: .black, strokeWidth: 1, label: label)
            let el = placed(.frame(style), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let result = try MoodboardRenderer.renderPNG(
                page: page([el]), provider: nil,
                options: RenderOptions(background: .white, pixelsPerPoint: 1))
            return try raster(result.data)
        }
        var plain = Self.baseText
        plain.fontFamily = "Helvetica"
        var styled = plain
        styled.weight = .bold
        styled.alignment = .right

        let a = try frameRaster(plain)
        let b = try frameRaster(styled)
        #expect(inkCount(a) > 0 && inkCount(b) > 0)
        #expect(a != b)

        // And each field on its own reaches the label, not just the pair.
        var boldOnly = plain
        boldOnly.weight = .bold
        var rightOnly = plain
        rightOnly.alignment = .right
        var courierOnly = plain
        courierOnly.fontFamily = "Courier"
        #expect(try frameRaster(boldOnly) != a)
        #expect(try frameRaster(rightOnly) != a)
        #expect(try frameRaster(courierOnly) != a)
    }

    @Test("The token enums keep the rawValues the domain stores")
    func tokenRawValues() {
        #expect(FontWeight.allCases.map(\.rawValue) == ["regular", "medium", "semibold", "bold"])
        #expect(TextAlignment.allCases.map(\.rawValue) == ["left", "center", "right"])
    }
}
