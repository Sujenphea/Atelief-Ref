// AtelierTokens — the dark-studio palette.
//
// Monochrome by design; both Figma frames confirm it. There is NO coloured accent:
// emphasis is a raised grey `field` fill plus white/ink text. The one exception is
// ``Tokens.Colors/warning``, and it is deliberately the only one — every healthy state is
// ink, so colour appearing anywhere in the chrome means exactly one thing.
//
// **Each colour is defined ONCE, as a number.** The `Color` is derived from it and the
// Mac's `NSColor` twin is derived from the same number, so the two cannot disagree. Before
// this package the twins were hand-written literals and three of them had already drifted
// from their originals — which is why `Theme.NS` was culled back to the mirrors that had
// readers.

import SwiftUI

public enum Tokens {

    /// The raw numbers. Every colour in the app resolves to one of these, and nothing
    /// outside this file writes a hex literal for chrome.
    ///
    /// Public because the Mac builds `NSColor` twins from them — an `NSColor` cannot be
    /// derived from a SwiftUI `Color` (there is no reliable way back out of one), so the
    /// number has to be reachable or the twin becomes a second literal again.
    public enum Hex {
        /// Outermost window ground + the collapsed sidebar rail; the phone's ground.
        public static let canvasOuter: UInt32 = 0x131313
        /// The inset content panel the grid and detail live inside.
        public static let panel: UInt32 = 0x212121
        /// Raised cards, sheets, toasts.
        public static let surface: UInt32 = 0x232326
        /// Sidebar selection, chips, the floating bars.
        public static let field: UInt32 = 0x2C2C30
        /// The ACTIVE sidebar row — brighter than ``field`` so the current destination
        /// pops off the translucent sidebar.
        public static let selection: UInt32 = 0x3A3A40
        /// Grid tiles and the detail media area — the art's stable dark ground.
        public static let mediaBackdrop: UInt32 = 0x141416
        /// Section titles and primary text.
        public static let inkPrimary: UInt32 = 0xF2F1EE
        /// Labels, values, captions.
        public static let inkSecondary: UInt32 = 0x9A9A9E
    }

    /// The alphas that define a colour on their own — a white or black veil rather than a
    /// pigment. Named here for the same reason the hexes are: the Mac mirrors them into
    /// `NSColor` and a second literal is a second thing to keep in step.
    public enum Alpha {
        /// Borders, dividers, chip and field hairlines.
        public static let hairline: Double = 0.08
        /// A stronger hairline for interactive borders.
        public static let hairlineStrong: Double = 0.14
        /// Pointer-over feedback on a full-width ROW. macOS only — a phone has no
        /// pointer, and this is documented as a whisper precisely so it cannot be
        /// mistaken for selection, which is the opposite of what a press wants.
        public static let hoverRow: Double = 0.06
        /// Pointer-over feedback on a GLYPH BUTTON, where the fill is the whole
        /// affordance. macOS only, as ``hoverRow``.
        public static let hoverControl: Double = 0.10
        /// The dark hairline nested just INSIDE the selection ring wherever it is drawn
        /// OVER an image. White alone vanishes on a pale photo.
        public static let selectionMarkContrast: Double = 0.5
    }

    public enum Colors {
        public static let canvasOuter = Color(hex: Hex.canvasOuter)
        public static let panel = Color(hex: Hex.panel)
        public static let surface = Color(hex: Hex.surface)
        public static let field = Color(hex: Hex.field)
        public static let selection = Color(hex: Hex.selection)
        public static let mediaBackdrop = Color(hex: Hex.mediaBackdrop)
        public static let inkPrimary = Color(hex: Hex.inkPrimary)
        public static let inkSecondary = Color(hex: Hex.inkSecondary)

        public static let hairline = Color.white.opacity(Alpha.hairline)
        public static let hairlineStrong = Color.white.opacity(Alpha.hairlineStrong)
        public static let hoverRow = Color.white.opacity(Alpha.hoverRow)
        public static let hoverControl = Color.white.opacity(Alpha.hoverControl)

        /// The selection MARKER drawn over ARTWORK — the grid tile's ring, the gallery
        /// card's ring, the marquee. Distinct from ``selection``, which is the grey FILL
        /// marking the active sidebar row: a fill can't be read on top of a photograph,
        /// and a ring can't be read on top of a list row.
        public static let selectionMark = Color.white
        public static let selectionMarkContrast = Color.black.opacity(Alpha.selectionMarkContrast)

        /// The app's ONE alarm colour: a warning label, an unreachable backup drive, a
        /// stopped sweep, a capture endpoint that couldn't take the port.
        ///
        /// The SYSTEM orange rather than a hex literal, unlike every token above it. The
        /// greys are the app's own studio palette and have to be exact; this one has to
        /// stay legible under Increase Contrast and the accessibility colour filters,
        /// which the platform only does for a system colour. A hex here would trade the
        /// one property that matters for a consistency the eye cannot check.
        public static let warning = Color.orange
    }
}

// MARK: - Hex → Color

extension Color {
    /// A `Color` from a 24-bit `0xRRGGBB` literal (sRGB), for token definitions.
    ///
    /// Public because the app draws colours the DOMAIN stores as well as ones it chose —
    /// see ``init(hexString:)``, which parses those. This one is for compile-time
    /// literals, and outside this package the only literals left should be values that
    /// are not chrome.
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// A `Color` from a stored hex STRING; `nil` for anything unparseable, so a corrupt
    /// payload falls back rather than drawing black and looking deliberate.
    ///
    /// Accepts `#`-optional, whitespace-tolerant, case-insensitive, 3/4/6/8 digits, with
    /// the short forms expanding each nibble exactly like CSS.
    ///
    /// **This grammar is shared on purpose.** The app reads one kind of stored string
    /// through parsers in modules that cannot share an implementation —
    /// `AtelierExport.RGBA.init(hex:)` (zero product dependencies by design) and
    /// `ElementRendering.rgba(fromHex:)` (the canvas) — and they used to disagree: a
    /// `#f3a` drew in an export and vanished on the board. `HexGrammarTests` pins them
    /// together. The SwiftUI one had then been written TWICE, once per platform, and the
    /// iOS copy took 3/6 only — so an 8-digit stored colour rendered on the Mac and fell
    /// back to a grey placeholder on the phone. It lives here now, once.
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.allSatisfy(\.isHexDigit) else { return nil }
        switch text.count {
        case 3, 4: text = text.map { "\($0)\($0)" }.joined()
        case 6, 8: break
        default: return nil
        }
        guard let value = UInt32(text, radix: 16) else { return nil }
        if text.count == 8 {
            self.init(
                .sRGB,
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255)
            return
        }
        self.init(hex: value)
    }
}
