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

    // Media-less kind tiles (003 · O1) — a color swatch / a bare link·tweet card,
    // drawn as vector frames (no blob to decode). Dark label on a light card,
    // matching the freeform frame/text defaults (a light canvas).
    static let mediaLessCardFill = RGBAColor(red: 0.93, green: 0.93, blue: 0.95)
    static let mediaLessCardStroke = RGBAColor(red: 0.56, green: 0.56, blue: 0.58) // #8E8E93
    static let mediaLessLabelColor = RGBAColor(red: 0.23, green: 0.23, blue: 0.25) // #3A3A3C
    static let mediaLessCardFontSize: Double = 14
    /// A faint hairline around a color swatch so a light swatch stays legible.
    static let swatchHairline = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.12)

    // MARK: Core style → renderer content

    /// Map a persisted row to what the renderer should draw. Asset rows go through
    /// ``assetTileContent(_:)`` (byte kinds → `.image`; media-less kinds → a vector
    /// swatch / card); element rows decode their `ElementStyle` JSON into a
    /// `FrameStyle` / `TextStyle`.
    static func tileContent(for item: SpaceItem, asset: Asset?) -> TileContent {
        switch item.kind {
        case .asset:
            return assetTileContent(asset)
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

    /// What an asset row draws on a board. A byte-backed asset — an image / video,
    /// OR a tweet / link that HAS a card image (its own `blobHash`) — takes the
    /// existing `.image` decode path. A media-less asset (a color, or a bare link /
    /// text-only tweet with no blob) draws as a vector `.frame`: a color swatch, or
    /// a neutral card labelled with the link heading / tweet byline. This mirrors the
    /// grid's ``AssetContentThumbnail`` switch, so a board tile reads like its cell.
    static func assetTileContent(_ asset: Asset?) -> TileContent {
        guard let asset else { return .image }
        // Any asset with bytes (incl. a hybrid tweet/link card image) → decode path.
        if asset.blobHash != nil { return .image }
        switch asset.content {
        case let .color(hex):
            return .frame(FrameStyle(
                fill: rgba(fromHex: hex) ?? mediaLessCardFill,
                stroke: swatchHairline, strokeWidth: 1, cornerRadius: frameCornerRadius))
        case let .link(link):
            return mediaLessCard(label: link.displayHeading)
        case let .tweet(tweet):
            return mediaLessCard(label: tweet.displayByline)
        case .image, .video, .unknown:
            // `.image`/`.video` can't reach here (blobHash was non-nil); `.unknown`
            // (data contradicts the kind) → a neutral, unlabelled card.
            return mediaLessCard(label: nil)
        }
    }

    /// A neutral media-less card: a light fill + subtle border, with the given
    /// heading drawn top-left (nil → an unlabelled placeholder).
    private static func mediaLessCard(label: String?) -> TileContent {
        let text = label.map {
            TextStyle(string: $0, fontSize: mediaLessCardFontSize, color: mediaLessLabelColor)
        }
        return .frame(FrameStyle(
            fill: mediaLessCardFill,
            stroke: mediaLessCardStroke,
            strokeWidth: defaultFrameStrokeWidth,
            cornerRadius: frameCornerRadius,
            label: text))
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

extension LinkContent {
    /// The card heading: the title if known, else the host, else the raw URL.
    /// Shared by the grid card (``LinkCardTile``) and the board tile.
    var displayHeading: String {
        if let title, !title.isEmpty { return title }
        if let host = URL(string: url)?.host { return host }
        return url
    }
}

extension TweetContent {
    /// The card byline: `@handle` when known, else the author name, else "Tweet".
    /// Shared by the grid card (``TweetCardTile``) and the board tile. The stored
    /// handle already carries a leading `@` (both capture paths prefix it), so we
    /// add one ONLY when absent — otherwise a real tweet reads `@@handle`.
    var displayByline: String {
        if let authorHandle, !authorHandle.isEmpty {
            return authorHandle.hasPrefix("@") ? authorHandle : "@\(authorHandle)"
        }
        if let authorName, !authorName.isEmpty { return authorName }
        return "Tweet"
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
