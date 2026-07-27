//
//  SpaceInlineEditGeometryTests.swift
//  AtelierRefsTests
//
//  2B / 062 — the inline editor's PURE geometry decision (`inlineEditorWorldBox`),
//  following the same posture as `SpaceInlineEditTests`: the `NSTextView` lifecycle
//  is live-only, but the decisions it drives are pure functions and tested here.
//
//  The crux is `boxIsIdenticalAtEveryZoom`. The editor used to size its FONT to
//  `worldSize × zoom`, which made TextKit re-lay-out — and therefore potentially
//  re-wrap — on every zoom step: jerky, and the same reflow 059 removed from the
//  canvas. Layout now happens in world units and the zoom is carried by
//  `EditorScaleBox`, so for a fixed tile the layout box cannot move with the camera.
//
//  062 collapsed the three resize modes into one behaviour — the width is the
//  tile's (the user's), the height follows the text — so the box is now a single
//  expression rather than a switch. What must hold is unchanged: no zoom in, no
//  zoom out.
//

import AppKit
import AtelierCore
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs
@testable import CanvasRenderer

@Suite("Inline text-edit geometry (062 · world-space layout)")
struct SpaceInlineEditGeometryTests {

    /// A tile 300×200 in WORLD units, expressed as the screen frame the engine would
    /// hand the editor at `scale` (screen = world × scale + translation).
    private func screenFrame(scale: CGFloat, worldSize: CGSize = CGSize(width: 300, height: 200),
                             origin: CGPoint = CGPoint(x: 40, y: 25)) -> CGRect {
        CGRect(x: origin.x * scale, y: origin.y * scale,
               width: worldSize.width * scale, height: worldSize.height * scale)
    }

    private let zooms: [CGFloat] = [0.25, 0.5, 1, 2, 4, 8]
    private let measured = CGSize(width: 180, height: 96)   // world units

    // MARK: - The crux: the layout box does not move with the camera

    @Test("the world layout box is identical at every zoom")
    func boxIsIdenticalAtEveryZoom() {
        let boxes = zooms.map { scale in
            inlineEditorWorldBox(
                tileScreenFrame: screenFrame(scale: scale), scale: scale,
                measuredWorldSize: measured)
        }
        // Every zoom must produce the SAME world box — exactly, not approximately.
        let first = boxes[0]
        for (zoom, box) in zip(zooms, boxes) {
            #expect(abs(box.width - first.width) < 0.000_1, "width drifted at \(zoom)×")
            #expect(abs(box.height - first.height) < 0.000_1, "height drifted at \(zoom)×")
        }
    }

    @Test("the wrap width the editor lays out against is zoom-invariant")
    func wrapWidthIsZoomInvariant() {
        // The content width (box − padding on both edges) is what TextKit wraps to
        // and what `TextMetrics` measures against; both must be constant across zoom,
        // or a pinch re-wraps the line the caret is sitting on.
        let widths = zooms.map { scale in
            inlineEditorWorldBox(
                tileScreenFrame: screenFrame(scale: scale), scale: scale,
                measuredWorldSize: measured
            ).width - 2 * TextMetrics.padding
        }
        #expect(widths.allSatisfy { abs($0 - widths[0]) < 0.000_1 })
        #expect(abs(widths[0] - (300 - 2 * TextMetrics.padding)) < 0.000_1)
    }

    // MARK: - Width is the tile's, height is the text's

    @Test("the width comes from the tile, never from the measured text")
    func widthComesFromTheTile() {
        // A string measured far wider than the box must NOT widen it — the width is
        // the user's, set by a resize handle, and only they may change it (062).
        let box = inlineEditorWorldBox(
            tileScreenFrame: screenFrame(scale: 2), scale: 2,
            measuredWorldSize: CGSize(width: 9_999, height: 40))
        #expect(abs(box.width - 300) < 0.000_1)
    }

    @Test("the height is the measured text plus padding on both edges")
    func heightIsMeasuredTextPlusPadding() {
        let box = inlineEditorWorldBox(
            tileScreenFrame: screenFrame(scale: 3), scale: 3,
            measuredWorldSize: measured)
        #expect(abs(box.height - (measured.height + 2 * TextMetrics.padding)) < 0.000_1)
    }

    @Test("a taller string grows the box; a shorter one shrinks it")
    func heightTracksTheText() {
        func height(_ measuredHeight: CGFloat) -> CGFloat {
            inlineEditorWorldBox(
                tileScreenFrame: screenFrame(scale: 1), scale: 1,
                measuredWorldSize: CGSize(width: 180, height: measuredHeight)).height
        }
        #expect(height(40) < height(96))
        #expect(height(96) < height(300))
    }

    @Test("the editor's height ignores the tile's height entirely")
    func heightIgnoresTheTile() {
        // The committed tile is 200pt tall but the text needs far less: the editor
        // must hug the text, exactly as the committed box will after `autosizedFrame`.
        let box = inlineEditorWorldBox(
            tileScreenFrame: screenFrame(scale: 1), scale: 1,
            measuredWorldSize: CGSize(width: 100, height: 20))
        #expect(abs(box.height - (20 + 2 * TextMetrics.padding)) < 0.000_1)
        #expect(box.height < 200)
    }

    // MARK: - Degenerate input

    @Test("a zero or negative scale is clamped, never divides by zero")
    func degenerateScaleIsSafe() {
        for scale in [CGFloat(0), -1, .leastNonzeroMagnitude] {
            let box = inlineEditorWorldBox(
                tileScreenFrame: CGRect(x: 0, y: 0, width: 300, height: 200),
                scale: scale, measuredWorldSize: measured)
            #expect(box.width.isFinite && box.height.isFinite)
            #expect(box.width > 0 && box.height > 0)
        }
    }

    @Test("an empty measured size still yields a padded, non-zero box")
    func emptyTextStillHasABox() {
        let box = inlineEditorWorldBox(
            tileScreenFrame: screenFrame(scale: 1), scale: 1, measuredWorldSize: .zero)
        #expect(abs(box.width - 300) < 0.000_1)                    // the tile's width
        #expect(abs(box.height - 2 * TextMetrics.padding) < 0.000_1)
    }

    // MARK: - The scale box carries the zoom

    @MainActor
    @Test("EditorScaleBox turns a screen frame over a world bounds into the zoom")
    func scaleBoxCarriesTheZoom() {
        let box = EditorScaleBox()
        let world = CGSize(width: 300, height: 200)
        for scale in zooms {
            box.frame = CGRect(x: 0, y: 0, width: world.width * scale, height: world.height * scale)
            box.bounds = CGRect(origin: .zero, size: world)
            // Bounds stay in world units regardless of the on-screen size — that ratio
            // IS the zoom, and it is the only place the zoom is applied.
            #expect(abs(box.bounds.width - world.width) < 0.000_1)
            #expect(abs(box.frame.width / box.bounds.width - scale) < 0.000_1)
        }
        #expect(box.isFlipped)   // top-left origin, matching the canvas host
    }
}
