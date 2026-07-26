//
//  SpaceTextStyleTests.swift
//  AtelierRefsTests
//
//  054 §3 / §8 (2A) — the app-layer bridge for rich text. Two invariants:
//   1. Enum conformance (R5): every `AtelierCore` weight/align token maps to a
//      `CanvasRenderer` token and back — the rawValue hop in `tileContent` is a
//      pure no-op, and CI fails on any drift between the two vocabularies.
//   2. `ElementRendering.tileContent` carries the persisted weight / alignment /
//      family into the renderer `TextStyle`, defaulting an unknown token.
//  The inspector stays compile-only (repo convention).
//

import AtelierCore
import CanvasRenderer
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Spaces rich-text style bridge (2A)")
struct SpaceTextStyleTests {

    // MARK: - Enum conformance (both directions)

    @Test("every AtelierCore TextWeight token ↔ a CanvasRenderer FontWeight token")
    func weightTokensCross() {
        #expect(TextWeight.allCases.count == FontWeight.allCases.count)
        // AtelierCore → renderer
        for w in TextWeight.allCases {
            #expect(FontWeight(rawValue: w.rawValue)?.rawValue == w.rawValue)
        }
        // renderer → AtelierCore
        for w in FontWeight.allCases {
            #expect(TextWeight(rawValue: w.rawValue)?.rawValue == w.rawValue)
        }
        #expect(Set(TextWeight.allCases.map(\.rawValue)) == Set(FontWeight.allCases.map(\.rawValue)))
    }

    @Test("every AtelierCore TextAlign token ↔ a CanvasRenderer TextAlignment token")
    func alignTokensCross() {
        #expect(TextAlign.allCases.count == TextAlignment.allCases.count)
        for a in TextAlign.allCases {
            #expect(TextAlignment(rawValue: a.rawValue)?.rawValue == a.rawValue)
        }
        for a in TextAlignment.allCases {
            #expect(TextAlign(rawValue: a.rawValue)?.rawValue == a.rawValue)
        }
        #expect(Set(TextAlign.allCases.map(\.rawValue)) == Set(TextAlignment.allCases.map(\.rawValue)))
    }

    // MARK: - tileContent carries the style through

    private func textItem(_ style: ElementStyle) -> SpaceItem {
        SpaceItem(
            id: UUID(), spaceID: UUID(), kind: .text, x: 0, y: 0, w: 100, h: 50, z: 0,
            style: style.jsonString(), createdAt: Date(), updatedAt: Date())
    }

    private func textStyle(_ item: SpaceItem) -> TextStyle? {
        guard case let .text(ts) = ElementRendering.tileContent(for: item, asset: nil) else {
            Issue.record("expected a .text tile content")
            return nil
        }
        return ts
    }

    @Test("tileContent maps every weight token onto the renderer TextStyle")
    func mapsEveryWeight() {
        for w in TextWeight.allCases {
            let ts = textStyle(textItem(ElementStyle(text: "x", fontWeight: w.rawValue)))
            #expect(ts?.weight.rawValue == w.rawValue)
        }
    }

    @Test("tileContent maps every alignment token onto the renderer TextStyle")
    func mapsEveryAlignment() {
        for a in TextAlign.allCases {
            let ts = textStyle(textItem(ElementStyle(text: "x", textAlign: a.rawValue)))
            #expect(ts?.alignment.rawValue == a.rawValue)
        }
    }

    @Test("an unknown weight / alignment token degrades to the renderer default")
    func unknownTokenDefaults() {
        let ts = textStyle(textItem(ElementStyle(
            text: "x", fontWeight: "ultrablack", textAlign: "justify")))
        #expect(ts?.weight == .regular)
        #expect(ts?.alignment == .left)
    }

    @Test("tileContent passes the font family through (nil stays nil)")
    func familyPassthrough() {
        #expect(textStyle(textItem(ElementStyle(text: "x", fontFamily: "Menlo")))?.fontFamily == "Menlo")
        #expect(textStyle(textItem(ElementStyle(text: "x")))?.fontFamily == nil)
    }

    @Test("a legacy text row (no new keys) renders as system / regular / left")
    func legacyRowDefaults() {
        let ts = textStyle(textItem(ElementStyle(text: "x", fontSize: 20)))
        #expect(ts?.fontFamily == nil)
        #expect(ts?.weight == .regular)
        #expect(ts?.alignment == .left)
    }

    // MARK: - Inspector (compile-only, repo convention)

    @Test("ElementInspector for a text element type-checks")
    func inspectorTextCompiles() {
        _ = ElementInspector(
            kind: .text,
            initialStyle: ElementStyle(
                text: "hi", fontFamily: "Helvetica", fontWeight: "bold",
                textAlign: "center", resizeMode: "autoWidth"),
            onCommit: { _ in }, onDelete: {})
    }

    @Test("ElementInspector for a frame element type-checks (keeps its label field)")
    func inspectorFrameCompiles() {
        _ = ElementInspector(
            kind: .frame, initialStyle: ElementStyle(text: "Label"),
            onCommit: { _ in }, onDelete: {})
    }
}
