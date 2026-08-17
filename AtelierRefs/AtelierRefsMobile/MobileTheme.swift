// AtelierRefsMobile — the phone's tokens (093 § 4).
//
// The same arrangement `ShareCard` made and for the same reason: `Theme.swift` is a
// macOS app-target file that imports AppKit, mirrors every colour into an `NSColor`
// twin and extends `CALayer`, so it cannot compile for iOS and cannot be linked from
// another target either way. What crosses is the VALUES, hand-copied with the
// `Theme.swift` line each came from, so the copy is checkable against its source
// rather than merely plausible. 093 § 4 is the list of which tokens cross; this is it.
//
// **There are now two of these on iOS** — `ShareTheme` in the share extension and this
// — which is exactly the situation `ShareCard`'s header predicted would arrive with
// S5: *"a shared cross-platform token target becomes the question; one card is not
// enough reader to justify one now."* There are two readers now. Making that target is
// a small, mechanical change and it is deliberately NOT made here, because it means
// editing the share extension, which is verified working through a real share sheet
// and is not what this slice is about. It is raised rather than done.
//
// What does NOT cross, and is absent below rather than quietly repurposed:
// `hoverRow` / `hoverControl` (no pointer, and `hoverRow` is documented as a whisper
// precisely so it cannot be mistaken for selection — a press wants the opposite),
// `Theme.NS` (no `NSView`/`CALayer` seam here), `CALayer.applyElevation` (it flips the
// shadow's y sign for AppKit's unflipped axis; UIKit's is flipped),
// `VisualEffectBackground` (a phone has no window margins and no desktop behind them),
// and the content panel's INSET and corner arc — the phone paints `panel` full-bleed
// and keeps only the tone. `selectionMark` / `selectionMarkContrast` are absent
// because v1 has no multiselect and a token with no reader is a second copy waiting to
// drift.

import SwiftUI

/// The phone's design tokens — hand-copied values from
/// `AtelierRefs/AtelierRefs/Theme.swift`, cited line by line.
enum MobileTheme {
    enum Colors {
        /// The app's ground, painted opaque — `Theme.Colors.canvasOuter`
        /// (`Theme.swift:28`). On the Mac a material supplies this tone under a
        /// translucent window; a phone has no window, so the token is the ground.
        static let canvasOuter = Color(hex: 0x131313)
        /// The content surface the grid and detail live on — `Theme.Colors.panel`
        /// (`:30`). Full-bleed here: the Mac's `Spacing.md` inset and `Radius.panel`
        /// arc exist because it is a panel inside a window beside a sidebar (093 § 4).
        static let panel = Color(hex: 0x212121)
        /// Raised cards, sheets — `Theme.Colors.surface` (`:32`).
        static let surface = Color(hex: 0x232326)
        /// Chips and inset fields — `Theme.Colors.field` (`:39`).
        static let field = Color(hex: 0x2C2C30)
        /// The active row in the collection switcher — `Theme.Colors.selection` (`:42`).
        static let selection = Color(hex: 0x3A3A40)
        /// Grid tiles + the detail media area — the art's stable dark ground.
        /// `Theme.Colors.mediaBackdrop` (`:56`). 093 § 6 leans on this one: a light
        /// image and a dark one sit on the same tone instead of the image's own edges
        /// reading as chrome.
        static let mediaBackdrop = Color(hex: 0x141416)
        /// Titles + primary text — `Theme.Colors.inkPrimary` (`:63`).
        static let inkPrimary = Color(hex: 0xF2F1EE)
        /// Labels, values, captions — `Theme.Colors.inkSecondary` (`:65`).
        static let inkSecondary = Color(hex: 0x9A9A9E)
        /// Borders, dividers — `Theme.Colors.hairline` (`:67`).
        static let hairline = Color.white.opacity(0.08)
        /// A stronger hairline for interactive borders — `Theme.Colors.hairlineStrong`
        /// (`:69`).
        static let hairlineStrong = Color.white.opacity(0.14)
        /// The app's ONE alarm colour — `Theme.Colors.warning` (`:93`). Left as the
        /// SYSTEM orange for the reason stated there: it has to stay legible under
        /// Increase Contrast and the accessibility colour filters.
        static let warning = Color.orange
    }

    /// The 4-pt scale — `Theme.Spacing` (`Theme.swift:121`–`:126`). A rhythm, not a
    /// density: 4/8/12/16/24/40 reads the same at 390pt as at 1100.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 40
    }

    /// `Theme.Radius` (`Theme.swift:134`–`:149`). `control` is absent — it exists to
    /// hug a 15pt icon in a 30×28 hit area, which is a pointer measurement.
    enum Radius {
        static let chip: CGFloat = 6
        static let field: CGFloat = 6
        static let tile: CGFloat = 8
        static let card: CGFloat = 12
        static let cover: CGFloat = 14
        static let panel: CGFloat = 16
    }

    /// `Theme.Motion` (`Theme.swift:167`–`:169`) — durations and damping, not platform
    /// behaviours, so they cross unchanged.
    enum Motion {
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let gentle = Animation.easeOut(duration: 0.15)
    }

    /// `Theme.Elevation.floating` (`Theme.swift:193`) — a bar or card riding over
    /// content it did not lay out. Applied directly rather than through the
    /// `.elevation()` modifier, which lives beside a `CALayer` extension that does not
    /// build here.
    enum Elevation {
        static let color = Color.black.opacity(0.35)
        static let radius: CGFloat = 14
        static let y: CGFloat = 5
    }

    /// `Theme.disabledOpacity` (`Theme.swift:162`). Its stated reason — `.plain`-family
    /// controls drop the system's own dimming — is a SwiftUI fact, true on both
    /// platforms.
    static let disabledOpacity: Double = 0.35

    /// The type roles this app draws, from `Theme.Typography` (`Theme.swift:216`–`:265`).
    /// Each is a text style plus a weight, never a point size — which is what makes
    /// Dynamic Type work, and 093 § 4 notes that reasoning was written for a Mac and
    /// pays off far more on a phone.
    enum Typography {
        /// `Theme.Typography.pageTitle` (`:236`).
        static let pageTitle = Font.system(.title2, design: .default, weight: .semibold)
        /// `Theme.Typography.sectionTitle` (`:242`).
        static let sectionTitle = Font.system(.title3, design: .default, weight: .semibold)
        /// `Theme.Typography.row` (`:246`).
        static let row = Font.system(.body, design: .default, weight: .regular)
        /// `Theme.Typography.bodyEmphasis` (`:248`).
        static let bodyEmphasis = Font.system(.headline, design: .default, weight: .semibold)
        /// `Theme.Typography.body` (`:250`).
        static let body = Font.system(.callout, design: .default, weight: .regular)
        /// `Theme.Typography.label` (`:261`).
        static let label = Font.system(.subheadline, design: .default, weight: .regular)
        /// `Theme.Typography.caption` (`:263`).
        static let caption = Font.system(.caption2, design: .default, weight: .regular)
    }

    /// Apple's touch minimum. 093 § 5's rule: visual size stays on the tokens above,
    /// and a hit area is a SEPARATE `.contentShape` of at least this square — the same
    /// separation `HoverHighlight` already makes between its fill and its padded
    /// `.contentShape` (`HoverButtonStyle.swift:38`–`:42`), with a different constant.
    /// Inflating the padding to 44 would make phone chrome visually enormous to solve
    /// an invisible problem.
    static let touchTarget: CGFloat = 44

    /// The gap between grid cells, both ways — `Theme.Spacing.sm`. One name because the
    /// masonry column width and the vertical stack spacing must be the same number for
    /// the decomposition to reproduce the Mac's frames.
    static let gridSpacing: CGFloat = Spacing.sm
}

// MARK: - Compile-time hex colours

extension Color {
    /// A `Color` from a 24-bit `0xRRGGBB` literal (sRGB) — the same three lines as
    /// `Theme.swift:366`–`:377`, so the hex literals above compare to the app's
    /// character for character.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
