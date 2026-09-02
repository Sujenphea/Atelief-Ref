//
//  StyleBridgeConformanceTests.swift
//  AtelierRefsTests
//
//  099 · 2A — one `ElementStyle`, two bridges, and the assertion that they agree.
//
//  A board element's typography is stored once, in `space_item.style`, and read
//  TWICE: `ElementRendering.textStyle(for:)` builds what the canvas draws, and
//  `MoodboardExport.textStyle(from:)` builds what the PDF/PNG renders. Two readers
//  of one string, in two modules that cannot share a type — `CanvasRenderer` and
//  `AtelierExport` each own their own `TextStyle`, and `AtelierExport` has zero
//  product dependencies by design.
//
//  They disagreed, twice, and nothing failed either time:
//
//    • the colourless fallback was WHITE on the board and BLACK in the export, so a
//      legacy row with no stored colour was two different elements;
//    • family, weight and alignment reached the board and NOT the export, so a 24pt
//      bold centred Futura heading exported as Helvetica regular flush left. P0 gave
//      `AtelierExport.TextStyle` the three fields and taught `MoodboardRenderer` to
//      honour them — and no bridge filled them, so the export stayed byte-identical.
//      This phase filled it.
//
//  A third disagreement was found by writing this file: the default `fontSize` was
//  16 on the board and 17 in the export, so an element with no stored size drew a
//  point larger on the page than on the screen. The export's defaults are now
//  expressed in terms of the board's rather than restated.
//
//  This suite is the standing version of that check. It is deliberately NOT a test
//  of either bridge's output values — `MoodboardExportTests` and
//  `CanvasContentMappingTests` do that. It asserts only that the two agree, field
//  for field, over a fixture set that covers every token either side can carry.
//

import AtelierCore
import AtelierExport
import CanvasRenderer
import Foundation
import Testing

@testable import AtelierRefs

@Suite("Style bridge conformance — one ElementStyle, two renderers (099 · 2A)")
struct StyleBridgeConformanceTests {

    // MARK: - The fixture set

    /// Every shape of stored style either bridge has to survive: a bare style, a
    /// fully-specified one, each weight token, each alignment token, an unknown
    /// token in both enum fields, the 063 hugging flag, and the legacy 062
    /// `resizeMode` that nothing reads but every old row carries.
    ///
    /// Named, because a failure that says `weight: bold` is a bug report and one
    /// that says `fixture #7` is a scavenger hunt.
    nonisolated static let fixtures: [(name: String, style: ElementStyle)] = {
        var cases: [(String, ElementStyle)] = [
            ("bare — every field nil", ElementStyle()),
            ("text only", ElementStyle(text: "Heading")),
            ("no family (the system font)",
             ElementStyle(text: "H", fontSize: 24, textColor: "#ff8800", fontWeight: "bold")),
            ("a family",
             ElementStyle(text: "H", fontSize: 24, textColor: "#ff8800", fontFamily: "Futura")),
            ("an empty family string",
             ElementStyle(text: "H", fontSize: 24, fontFamily: "")),
            ("an unknown weight token",
             ElementStyle(text: "H", fontSize: 18, fontWeight: "ultralight")),
            ("an unknown alignment token",
             ElementStyle(text: "H", fontSize: 18, textAlign: "justified")),
            ("the legacy resizeMode (062)",
             ElementStyle(text: "H", fontSize: 18, resizeMode: "autoWidth")),
            ("textAutoWidth on (063)",
             ElementStyle(text: "H", fontSize: 18, textAutoWidth: true)),
            ("textAutoWidth off",
             ElementStyle(text: "H", fontSize: 18, textAutoWidth: false)),
            ("an 8-digit translucent colour",
             ElementStyle(text: "H", fontSize: 18, textColor: "#ff880080")),
            ("a 3-digit shorthand colour",
             ElementStyle(text: "H", fontSize: 18, textColor: "#f80")),
            ("a malformed colour falls back",
             ElementStyle(text: "H", fontSize: 18, textColor: "not-a-colour")),
        ]
        // Every token of each enum, from the enum itself — a token added to
        // `TextWeight` / `TextAlign` joins this suite with no edit here, which is
        // the point: the gap that started 2A was a field NOBODY thought to carry.
        for weight in TextWeight.allCases {
            cases.append(("weight \(weight.rawValue)",
                          ElementStyle(text: "H", fontSize: 20, fontWeight: weight.rawValue)))
        }
        for align in TextAlign.allCases {
            cases.append(("align \(align.rawValue)",
                          ElementStyle(text: "H", fontSize: 20, textAlign: align.rawValue)))
        }
        return cases.map { (name: $0.0, style: $0.1) }
    }()

    // MARK: - Field-for-field

    @Test("both bridges read one ElementStyle the same way",
          arguments: StyleBridgeConformanceTests.fixtures.map(\.name))
    func textStylesAgree(fixtureName: String) throws {
        let style = try #require(
            Self.fixtures.first { $0.name == fixtureName }?.style,
            "fixture \(fixtureName) vanished")

        let board = ElementRendering.textStyle(for: style)
        let page = MoodboardExport.textStyle(from: style)

        expectAgreement(board: board, page: page, fixture: fixtureName)
    }

    @Test("a frame's LABEL crosses both bridges identically too",
          arguments: StyleBridgeConformanceTests.fixtures.map(\.name))
    func frameLabelsAgree(fixtureName: String) throws {
        // `FrameStyle.label` is a `TextStyle`, so it inherits family / weight /
        // alignment for free — but only if BOTH sides route their label through
        // their text bridge. The board's used to build one by hand from three
        // fields, which is exactly how filling the export's bridge would have
        // created a NEW disagreement while closing the old one.
        var style = try #require(Self.fixtures.first { $0.name == fixtureName }?.style)
        style.text = style.text ?? "Label"  // a frame with no text has no label at all
        style.fillColor = "#202020"
        style.strokeColor = "#8e8e93"
        style.strokeWidth = 2

        let boardContent = ElementRendering.tileContent(
            for: item(kind: .frame, style: style), asset: nil)
        guard case .frame(let boardFrame) = boardContent else {
            Issue.record("the board did not draw a frame for \(fixtureName)"); return
        }
        let pageFrame = MoodboardExport.frameStyle(from: style)

        let boardLabel = try #require(boardFrame.label, "the board dropped the label")
        let pageLabel = try #require(pageFrame.label, "the export dropped the label")
        expectAgreement(board: boardLabel, page: pageLabel, fixture: fixtureName)
    }

    @Test("a frame with no text has no label on EITHER side")
    func anEmptyFrameHasNoLabel() {
        for text in [nil, ""] as [String?] {
            let style = ElementStyle(text: text, fillColor: "#202020")
            let content = ElementRendering.tileContent(
                for: item(kind: .frame, style: style), asset: nil)
            guard case .frame(let boardFrame) = content else {
                Issue.record("expected a frame"); return
            }
            #expect(boardFrame.label == nil)
            #expect(MoodboardExport.frameStyle(from: style).label == nil)
        }
    }

    @Test("a nil style is the same element as a bare style, on both sides")
    func aNilStyleMatchesABareStyle() {
        // Only the export bridge takes an optional (an element row whose `style`
        // JSON failed to decode). It must land on the same place a bare
        // `ElementStyle()` does, or an unreadable blob exports as something the
        // board would never draw.
        let fromNil = MoodboardExport.textStyle(from: nil)
        let fromBare = MoodboardExport.textStyle(from: ElementStyle())
        #expect(fromNil == fromBare)
        expectAgreement(
            board: ElementRendering.textStyle(for: ElementStyle()),
            page: fromNil, fixture: "nil style")
    }

    // MARK: - The defaults, pinned

    @Test("the two bridges default an unstyled element to the same size and colour")
    func defaultsAreOneSource() {
        // The third disagreement, found by writing this suite: 16 on the board, 17
        // in the export. Pinned here rather than left to `textStylesAgree`'s bare
        // fixture, so a future edit that re-introduces a literal fails against a
        // test that NAMES the rule.
        let bare = ElementStyle()
        #expect(MoodboardExport.textStyle(from: bare).fontSize
                    == ElementRendering.defaultFontSize)
        #expect(MoodboardExport.defaultTextColor
                    == RGBA(hex: ElementRendering.defaultTextColorHex))
    }

    @Test("the weight and alignment tokens are rawValue-identical across three modules",
          arguments: TextWeight.allCases)
    func weightTokensMatch(_ weight: TextWeight) {
        // The bridges are rawValue hops, so this is what makes the `??` fallbacks in
        // both of them unreachable rather than merely untested.
        #expect(AtelierExport.FontWeight(rawValue: weight.rawValue) != nil)
        #expect(ElementRendering.BoardFontWeight(rawValue: weight.rawValue) != nil)
    }

    @Test("every alignment token crosses to both renderers",
          arguments: TextAlign.allCases)
    func alignTokensMatch(_ align: TextAlign) {
        #expect(AtelierExport.TextAlignment(rawValue: align.rawValue) != nil)
        #expect(ElementRendering.BoardTextAlignment(rawValue: align.rawValue) != nil)
    }

    @Test("an unknown token degrades to the SAME default on both sides")
    func unknownTokensDegradeTogether() {
        let style = ElementStyle(
            text: "H", fontSize: 18, fontWeight: "ultralight", textAlign: "justified")
        #expect(ElementRendering.textStyle(for: style).weight == .regular)
        #expect(ElementRendering.textStyle(for: style).alignment == .left)
        #expect(MoodboardExport.textStyle(from: style).weight == .regular)
        #expect(MoodboardExport.textStyle(from: style).alignment == .left)
    }

    // MARK: - Helpers

    /// Field for field, with the fixture's name on every failure.
    private func expectAgreement(
        board: ElementRendering.BoardTextStyle,
        page: MoodboardExport.PageTextStyle,
        fixture: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(board.string == page.string, "\(fixture): string", sourceLocation: sourceLocation)
        #expect(board.fontSize == page.fontSize, "\(fixture): fontSize",
                sourceLocation: sourceLocation)
        #expect(board.fontFamily == page.fontFamily, "\(fixture): fontFamily",
                sourceLocation: sourceLocation)
        #expect(board.weight.rawValue == page.weight.rawValue, "\(fixture): weight",
                sourceLocation: sourceLocation)
        #expect(board.alignment.rawValue == page.alignment.rawValue, "\(fixture): alignment",
                sourceLocation: sourceLocation)
        #expect(board.color.red == page.color.red, "\(fixture): red",
                sourceLocation: sourceLocation)
        #expect(board.color.green == page.color.green, "\(fixture): green",
                sourceLocation: sourceLocation)
        #expect(board.color.blue == page.color.blue, "\(fixture): blue",
                sourceLocation: sourceLocation)
        #expect(board.color.alpha == page.color.alpha, "\(fixture): alpha",
                sourceLocation: sourceLocation)
        // `hugsWidth` has no counterpart: it is an EDITOR affordance (063) that the
        // draw path ignores, so a page has nothing to do with it. Named here so its
        // absence is a decision rather than a field somebody forgot.
    }

    private func item(kind: SpaceItemKind, style: ElementStyle) -> SpaceItem {
        SpaceItem(
            id: UUID(), spaceID: UUID(), kind: kind,
            x: 0, y: 0, w: 200, h: 80, z: 0,
            style: style.jsonString(),
            createdAt: Date(), updatedAt: Date())
    }
}
