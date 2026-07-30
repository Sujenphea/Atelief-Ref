// AtelierExport — RGBA colour value + hex parsing (052 · B2)
//
// A tiny value type so the package can carry colours (swatch fills, text /
// frame styling) without depending on AppKit's `NSColor` or leaking a
// non-Sendable `CGColor` through the input model. The hex parser is the one
// place `#rgb` / `#rrggbb` / `#rrggbbaa` strings (the on-disk `AssetContent`
// `.color(hex:)` and `ElementStyle` colour encoding) are decoded, so it is
// pure and heavily unit-tested (052 · 10A layer 1).

import CoreGraphics

/// Straight (non-premultiplied) sRGB colour, components in `0...1`.
///
/// `Sendable` + `Equatable` so it can ride inside the value-type input model
/// across the render `Task` boundary; the bridge to a drawable `CGColor` is
/// deferred to ``cgColor`` at draw time (CGColor is not Sendable).
public struct RGBA: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    /// Opaque black — the fallback for a text colour that fails to parse.
    public static let black = RGBA(red: 0, green: 0, blue: 0)
    /// Opaque white — paper. The right ground for a CONTACT SHEET, whose captions
    /// are a mid grey chosen to read on it.
    public static let white = RGBA(red: 1, green: 1, blue: 1)
    /// The dark ground a Space board is composed against (`#141416` — the mirror of
    /// the app's `Theme.Colors.mediaBackdrop`; this package cannot see `Theme`).
    ///
    /// A moodboard export renders it because the board's own defaults assume it: a
    /// text element created on a board persists white (`#FFFFFF`), so on white paper
    /// every caption the user typed came out invisible.
    public static let boardGround = RGBA(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)

    /// Parse a CSS-style hex string into an ``RGBA``, or `nil` when the string
    /// is not a recognised hex colour.
    ///
    /// Accepts an optional leading `#`, case-insensitive digits, and four
    /// lengths: `rgb` (3), `rgba` (4), `rrggbb` (6), `rrggbbaa` (8). The 3/4
    /// short forms expand each nibble (`f` → `ff`) exactly like CSS. Any other
    /// length, or a non-hex digit, yields `nil` — the caller then drops the
    /// colour and reports a skip rather than drawing a wrong one.
    public init?(hex raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }

        let expanded: String
        switch s.count {
        case 3, 4:
            // Expand each nibble: "f3a" -> "ff33aa".
            expanded = s.map { "\($0)\($0)" }.joined()
        case 6, 8:
            expanded = s
        default:
            return nil
        }

        func component(_ start: Int) -> Double {
            let i = expanded.index(expanded.startIndex, offsetBy: start)
            let j = expanded.index(i, offsetBy: 2)
            return Double(Int(expanded[i..<j], radix: 16) ?? 0) / 255
        }

        self.init(
            red: component(0),
            green: component(2),
            blue: component(4),
            alpha: expanded.count == 8 ? component(6) : 1)
    }

    /// A drawable sRGB `CGColor`. Built at draw time (not stored) so the value
    /// type stays `Sendable`.
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension Double {
    /// Clamp into `0...1` so an out-of-range channel can never reach `CGColor`.
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
