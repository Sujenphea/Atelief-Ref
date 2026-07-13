//
//  ElementRendering.swift
//  AtelierRefs
//
//  005-E3 — the bridge between the Core `ElementStyle` (hex-string colours in the
//  `space_item.style` JSON) and the renderer's `TileContent` value types
//  (`FrameStyle` / `TextStyle` with `RGBAColor`). Also the default styles for
//  newly-created frames/text and the `Color` ↔ hex interop the inspector needs.
//  Kept in the app layer — the only place that imports BOTH `AtelierCore` and
//  `CanvasRenderer`.
//

import AppKit
import AtelierCore
import CanvasRenderer
import SwiftUI

enum ElementRendering {
    // Defaults for freshly-created elements.
    static let defaultFontSize: Double = 22
    static let defaultTextColorHex = "#111111"
    static let defaultLabelColorHex = "#3A3A3C"
    static let defaultFrameStrokeHex = "#8E8E93"
    static let defaultFrameStrokeWidth: Double = 2
    static let frameCornerRadius: Double = 4

    // MARK: Core style → renderer content

    /// Map a persisted row to what the renderer should draw. Asset rows are
    /// `.image` (handled by the existing path); element rows decode their
    /// `ElementStyle` JSON into a `FrameStyle` / `TextStyle`.
    static func tileContent(for item: SpaceItem) -> TileContent {
        switch item.kind {
        case .asset:
            return .image
        case .text:
            let style = ElementStyle(jsonString: item.style) ?? ElementStyle()
            return .text(TextStyle(
                string: style.text ?? "",
                fontSize: style.fontSize ?? defaultFontSize,
                color: rgba(fromHex: style.textColor) ?? RGBAColor(red: 0.07, green: 0.07, blue: 0.07)))
        case .frame:
            let style = ElementStyle(jsonString: item.style) ?? ElementStyle()
            let label: TextStyle? = {
                guard let text = style.text, !text.isEmpty else { return nil }
                return TextStyle(
                    string: text, fontSize: style.fontSize ?? 16,
                    color: rgba(fromHex: style.textColor) ?? RGBAColor(red: 0.23, green: 0.23, blue: 0.25))
            }()
            return .frame(FrameStyle(
                fill: rgba(fromHex: style.fillColor),
                stroke: rgba(fromHex: style.strokeColor)
                    ?? RGBAColor(red: 0.56, green: 0.56, blue: 0.58),
                strokeWidth: style.strokeWidth ?? defaultFrameStrokeWidth,
                cornerRadius: frameCornerRadius,
                label: label))
        }
    }

    // MARK: Default styles

    static func defaultTextStyle() -> ElementStyle {
        ElementStyle(text: "Text", fontSize: defaultFontSize, textColor: defaultTextColorHex)
    }

    static func defaultFrameStyle() -> ElementStyle {
        ElementStyle(
            text: nil, fontSize: 16, textColor: defaultLabelColorHex,
            fillColor: nil, strokeColor: defaultFrameStrokeHex, strokeWidth: defaultFrameStrokeWidth)
    }

    // MARK: Hex ↔ RGBAColor

    /// Parse `#rrggbb` / `#rrggbbaa` (leading `#` optional) into an `RGBAColor`,
    /// or `nil` for a nil / malformed string (so an unset colour stays unset).
    static func rgba(fromHex hex: String?) -> RGBAColor? {
        guard var s = hex else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            return RGBAColor(
                red: Double((v >> 24) & 0xff) / 255, green: Double((v >> 16) & 0xff) / 255,
                blue: Double((v >> 8) & 0xff) / 255, alpha: Double(v & 0xff) / 255)
        }
        return RGBAColor(
            red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255, alpha: 1)
    }

    /// Encode an `RGBAColor` as `#rrggbb` (or `#rrggbbaa` when translucent).
    static func hex(from c: RGBAColor) -> String {
        func h(_ x: Double) -> String { String(format: "%02X", Int((max(0, min(1, x)) * 255).rounded())) }
        if c.alpha < 1 { return "#\(h(c.red))\(h(c.green))\(h(c.blue))\(h(c.alpha))" }
        return "#\(h(c.red))\(h(c.green))\(h(c.blue))"
    }
}

extension Color {
    /// Build a SwiftUI colour from a renderer `RGBAColor` (sRGB).
    init(rgba c: RGBAColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    /// Resolve this colour to an sRGB `RGBAColor` for persistence as hex.
    func rgbaComponents() -> RGBAColor {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        return RGBAColor(
            red: Double(ns.redComponent), green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}
