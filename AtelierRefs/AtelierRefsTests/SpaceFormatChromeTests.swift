//
//  SpaceFormatChromeTests.swift
//  AtelierRefsTests
//
//  062 — the floating format bubble's PURE parts: where the panel lands, and which
//  palette swatch a stored colour is.
//
//  The placement is the half worth testing. A floating panel is only ever wrong in
//  two ways — off the edge of the viewport, or on top of the thing it is formatting —
//  and both happen at viewport edges, which is exactly where they are hardest to
//  reproduce by hand. So the flip rules are asserted here rather than eyeballed: box
//  near the bottom, box against either side, box on a fractional pixel.
//
//  (An earlier cut floated all eleven colours in a second panel above the box, which
//  needed a don't-collide rule between the two. The palette is one segment in the
//  bubble now, so both the second panel and that rule are gone.)
//

import AppKit
import SwiftUI
import AtelierCore
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Floating format bubble — font · size · colour (062)")
struct SpaceFormatChromeTests {

    private let bounds = CGSize(width: 1_200, height: 800)
    private let gap = SpaceTextChromeLayout.gap
    private let margin = SpaceTextChromeLayout.margin

    private func bubbleSize(_ label: String = "24") -> CGSize {
        SpaceTextChromeLayout.bubbleSize(sizeLabel: label)
    }

    /// The bubble for a box.
    private func bubble(for box: CGRect, bounds: CGSize? = nil) -> CGRect {
        CGRect(
            origin: SpaceTextChromeLayout.bubbleOrigin(
                anchor: box, size: bubbleSize(), bounds: bounds ?? self.bounds),
            size: bubbleSize())
    }

    // MARK: - The ordinary case

    @Test("the bubble sits below the box, centred on it, clear of it")
    func defaultPlacement() {
        let box = CGRect(x: 400, y: 300, width: 300, height: 120)
        let panel = bubble(for: box)

        #expect(panel.minY == box.maxY + gap)
        #expect(panel.midX == box.midX)
        #expect(!panel.intersects(box))
    }

    // MARK: - Viewport edges

    @Test("a box at the bottom pushes the bubble above it")
    func bubbleFlipsAtTheBottomEdge() {
        let box = CGRect(x: 400, y: 740, width: 300, height: 50)
        let panel = bubble(for: box)
        #expect(panel.maxY == box.minY - gap)
        #expect(panel.maxY <= bounds.height - margin)
        #expect(!panel.intersects(box))
    }

    @Test("a box against either side keeps the bubble on screen")
    func clampedHorizontally() {
        for box in [CGRect(x: -200, y: 300, width: 300, height: 120),
                    CGRect(x: 1_150, y: 300, width: 300, height: 120)] {
            let panel = bubble(for: box)
            #expect(panel.minX >= margin)
            #expect(panel.maxX <= bounds.width - margin)
        }
    }

    @Test("a box on a fractional pixel still lands the bubble on whole points")
    func panelsLandOnWholePoints() {
        // The box's on-screen frame is fractional at most zoom levels. A panel on a
        // half point spreads its hairline border — and the ring around its swatch —
        // over two rows of pixels, which reads as blurred rather than as a rounding
        // error.
        let box = CGRect(x: 400.37, y: 300.62, width: 301.4, height: 119.75)
        let panel = bubble(for: box)
        #expect(panel.origin.x == panel.origin.x.rounded())
        #expect(panel.origin.y == panel.origin.y.rounded())
    }

    @Test("the bubble never lands on the box, wherever the box is")
    func bubbleNeverCoversTheBox() {
        // The sweep is the point: the flip is conditional, and a case the branch
        // doesn't cover would show up here rather than on someone's board.
        for y in stride(from: -100.0, through: 900.0, by: 25.0) {
            for x in stride(from: -300.0, through: 1_400.0, by: 100.0) {
                let box = CGRect(x: x, y: y, width: 300, height: 120)
                #expect(!bubble(for: box).intersects(box),
                        "the bubble covers a box at (\(x), \(y))")
            }
        }
    }

    // MARK: - Sizing

    @Test("the bubble widens for a wider size label, never below its minimum")
    func bubbleWidthTracksItsLabel() {
        #expect(bubbleSize("144").width > bubbleSize("10").width)
        #expect(SpaceTextChromeLayout.sizeSegmentWidth(label: "8") >= 26)
    }

    @Test("the bubble's width counts its dividers, so nothing is squeezed out")
    func bubbleWidthCountsEverythingItDraws() {
        // The panel's frame is set from this number: a separator left out of the sum
        // is a separator squeezed out of the content at draw time.
        let label = "24"
        let content = SpaceTextChromeLayout.aaWidth
            + SpaceTextChromeLayout.sizeSegmentWidth(label: label)
            + SpaceTextChromeLayout.swatchSegmentWidth
            + 2 * SpaceTextChromeLayout.dividerWidth
            + 4 * SpaceTextChromeLayout.segmentGap
            + 2 * SpaceTextChromeLayout.panelPadding
        #expect(bubbleSize(label).width == content)
    }

    @Test("the size label reads the style, and falls back to the default")
    func sizeLabelReadsTheStyle() {
        #expect(SpaceTextChromeLayout.sizeLabel(for: ElementStyle(fontSize: 36)) == "36")
        #expect(SpaceTextChromeLayout.sizeLabel(for: ElementStyle(fontSize: 23.6)) == "24")
        #expect(SpaceTextChromeLayout.sizeLabel(for: ElementStyle())
                == String(Int(ElementRendering.defaultFontSize)))
    }

    // MARK: - The palette

    @Test("eleven swatches, every one a parseable colour, no duplicates")
    func paletteIsWellFormed() {
        #expect(TextPalette.swatches.count == 11)
        for swatch in TextPalette.swatches {
            #expect(ElementRendering.rgba(fromHex: swatch.hex) != nil, "\(swatch.name) is unparseable")
        }
        #expect(Set(TextPalette.swatches.map(\.hex)).count == TextPalette.swatches.count)
    }

    @Test("a stored colour matches its swatch whatever form it was written in")
    func matchingIsOnTheColourNotTheString() {
        // The inspector's `ColorPicker` writes whatever the resolved `NSColor`
        // produces — lower case, and `#rrggbbaa` when it round-trips an alpha. All of
        // those are the same red, so all of them must ring the same dot.
        let red = TextPalette.swatches.first { $0.name == "Red" }!
        #expect(TextPalette.swatch(forStoredHex: "#FF5A5F") == red)
        #expect(TextPalette.swatch(forStoredHex: "#ff5a5f") == red)
        #expect(TextPalette.swatch(forStoredHex: "ff5a5f") == red)
        #expect(TextPalette.swatch(forStoredHex: "#FF5A5FFF") == red)
    }

    @Test("an off-palette colour rings nothing, rather than the nearest dot")
    func offPaletteColourMatchesNoSwatch() {
        #expect(TextPalette.swatch(forStoredHex: "#123456") == nil)
        #expect(TextPalette.swatch(forStoredHex: "#FF5A60") == nil) // one step off red
        #expect(TextPalette.swatch(forStoredHex: nil) == nil)
        #expect(TextPalette.swatch(forStoredHex: "not a colour") == nil)
    }

    @Test("a translucent stored colour is not the opaque swatch")
    func alphaIsPartOfTheMatch() {
        #expect(TextPalette.swatch(forStoredHex: "#00000080") == nil)
        #expect(TextPalette.swatch(forStoredHex: "#000000")?.name == "Black")
    }

    // MARK: - The hover ring, measured

    /// Render a swatch dot and return the bounding box of everything it drew, in
    /// POINTS relative to the render's centre.
    ///
    /// Rendered rather than reasoned about: "the ring isn't centred" was reported
    /// twice, and both fixes were arguments about how SwiftUI centres an overlay. An
    /// argument can be wrong in a way a pixel can't.
    @MainActor
    private func inkBounds(hovering: Bool) throws -> CGRect {
        let side: CGFloat = 40
        let renderer = ImageRenderer(
            content: ZStack {
                SwatchDotBody(
                    swatch: TextPalette.swatches.first { $0.name == "Black" }!,
                    isCurrent: false, hovering: hovering)
            }
            .frame(width: side, height: side))
        let scale: CGFloat = 4
        renderer.scale = scale
        let image = try #require(renderer.cgImage)

        // Read the alpha channel: the background is clear, so anything the dot drew
        // is the only non-zero alpha in the bitmap.
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 { // ignore AA dust
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        #expect(maxX >= 0, "the dot drew nothing at all")
        // Back to points, relative to the centre of the render.
        let half = side * scale / 2
        return CGRect(
            x: (CGFloat(minX) - half) / scale, y: (CGFloat(minY) - half) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    @MainActor
    @Test("the hover ring is concentric with its dot, and 2pt clear of it")
    func hoverRingIsConcentric() throws {
        let resting = try inkBounds(hovering: false)
        let hovered = try inkBounds(hovering: true)

        // Both are centred on the same point: |left inset| == |right inset|.
        for box in [resting, hovered] {
            #expect(abs(box.minX + box.maxX) < 0.3, "off-centre horizontally: \(box)")
            #expect(abs(box.minY + box.maxY) < 0.3, "off-centre vertically: \(box)")
        }
        // Resting is the 16pt dot; hovering adds the ring, 2pt clear on every side.
        #expect(abs(resting.width - SpaceTextChromeLayout.swatchSize) < 0.6)
        #expect(abs(hovered.width - SwatchDotBody.hoverRingSize) < 0.6)
        #expect(abs(hovered.height - hovered.width) < 0.3)
    }

    @Test("the hover ring clears its neighbours in the colour popover's grid")
    func hoverRingFitsTheGrid() {
        // It overflows the dot's own 16pt cell by design, so what keeps it from
        // colliding is the grid's spacing — and, in the bubble, the segment it sits in.
        let overhang = (SwatchDotBody.hoverRingSize - SpaceTextChromeLayout.swatchSize) / 2
        #expect(overhang * 2 <= SpaceTextChromeLayout.swatchGap)
        #expect(SwatchDotBody.hoverRingSize <= SpaceTextChromeLayout.swatchSegmentWidth)
    }

    @Test("eleven swatches fill the grid's rows without a ragged last row of one")
    func paletteGridIsBalanced() {
        let columns = SpaceTextChromeLayout.paletteColumns
        #expect(TextPalette.swatches.count % columns != 1)
    }
}
