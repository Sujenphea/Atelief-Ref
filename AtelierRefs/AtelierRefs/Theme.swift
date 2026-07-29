//
//  Theme.swift
//  AtelierRefs
//
//  The app's single design-token layer — the home the app previously lacked. It
//  extends the existing centralization precedent of `ElementRendering` (canvas
//  colour tokens) and the `*Layout` structs (geometry) to the app CHROME: the
//  dark-studio palette, a spacing / radius / motion / elevation scale, and a few
//  typography roles. Every scattered magic number (corner radii `6,8,10,12,14,20`,
//  ad-hoc paddings, five different springs) resolves here.
//
//  Monochrome by design — both Figma frames confirm it. There is NO coloured
//  accent: emphasis is a raised grey `field` fill (`#2C2C30`) + white/ink text.
//

import AppKit
import SwiftUI

enum Theme {

    // MARK: - Colour (dark studio, monochrome)

    enum Colors {
        /// Outermost window ground + the collapsed sidebar rail. Under the native
        /// translucent window (D1b) the material supplies this tone; the token is
        /// the opaque fallback / reference value.
        static let canvasOuter = Color(hex: 0x131313)
        /// The inset content panel the grid + detail live inside (opaque, radius 16).
        static let panel = Color(hex: 0x212121)
        /// Raised cards, sheets, toasts.
        static let surface = Color(hex: 0x232326)
        /// Sidebar selection, chips, input fields, buttons (on a `hairline` border).
        static let field = Color(hex: 0x2C2C30)
        /// The ACTIVE sidebar row — a brighter fill than `field` so the current
        /// destination pops off the translucent sidebar (paired with `hairlineStrong`).
        static let selection = Color(hex: 0x3A3A40)
        /// Grid tiles + the detail media area — the art's stable dark ground.
        static let mediaBackdrop = Color(hex: 0x141416)
        /// Detail filmstrip thumbs + the Back-button fill.
        static let filmstrip = Color(hex: 0x1A1A1C)
        /// Section titles + primary text.
        static let inkPrimary = Color(hex: 0xF2F1EE)
        /// Labels, values, captions.
        static let inkSecondary = Color(hex: 0x9A9A9E)
        /// Borders, dividers, chip / field hairlines.
        static let hairline = Color.white.opacity(0.08)
        /// A stronger hairline for interactive borders (e.g. the detail Back pill).
        static let hairlineStrong = Color.white.opacity(0.14)
    }

    /// AppKit (`NSColor`) mirrors of the tokens the layer-backed grid cell
    /// (`MasonryGridItem`) and other `NSView` seams need.
    enum NS {
        static let mediaBackdrop = NSColor(hex: 0x141416)
        static let field = NSColor(hex: 0x2C2C30)
        static let panel = NSColor(hex: 0x212121)
        static let inkPrimary = NSColor(hex: 0xF2F1EE)
        static let hairline = NSColor.white.withAlphaComponent(0.08)
    }

    // MARK: - Spacing (4-pt scale)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 40
    }

    // MARK: - Radius

    enum Radius {
        static let chip: CGFloat = 6
        static let field: CGFloat = 6
        static let tile: CGFloat = 8
        static let card: CGFloat = 12
        static let cover: CGFloat = 14
        static let panel: CGFloat = 16
        static let sheet: CGFloat = 16
    }

    // MARK: - Motion (one canonical set — replaces the per-site springs)

    enum Motion {
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let gentle = Animation.easeOut(duration: 0.15)
        static let toast = Animation.spring(response: 0.35, dampingFraction: 0.85)
    }

    // MARK: - Elevation (hover / rest shadow tokens)

    struct Elevation {
        let color: Color
        let radius: CGFloat
        let y: CGFloat

        static let rest = Elevation(color: .black.opacity(0.40), radius: 2, y: 1)
        static let hover = Elevation(color: .black.opacity(0.55), radius: 14, y: 8)
    }

    // MARK: - Typography (the Figma's fixed roles)

    enum Typography {
        /// The ONE page / section title role — 15pt semibold. Home section headers
        /// ("Collections", "Spaces"), the Collection + Space page titles, and the
        /// detail inspector section headers ("Data", "Source", "Details") all share
        /// this so no page title drifts to its own `.title2`/`.title3`/`.headline`.
        static let sectionTitle = Font.system(size: 15, weight: .semibold)
        /// Sidebar top-nav rows ("Home", "Search", …) — 17pt medium.
        static let navItem = Font.system(size: 16, weight: .medium)
        /// Sidebar collection rows, chip / field text — 14pt.
        static let row = Font.system(size: 14, weight: .regular)
        /// Metadata labels + values, captions — 12pt.
        static let label = Font.system(size: 12, weight: .regular)
    }
}

// MARK: - Shadow convenience

extension View {
    /// Apply an `Elevation` token as a drop shadow.
    func elevation(_ e: Theme.Elevation) -> some View {
        shadow(color: e.color, radius: e.radius, y: e.y)
    }
}

// MARK: - Popover surface

extension View {
    /// The app's ONE popover look: a `surface` card on a plain `hairline`, lifted by
    /// the `hover` elevation.
    ///
    /// A popover is the app's only chrome that floats over content it did not lay
    /// out, so its separation has to come from the shadow rather than from a heavy
    /// border — hence the subtle hairline paired with the strongest elevation token.
    /// That is the opposite balance to a floating BAR (`selectionBarChrome()`), which
    /// sits in known space and can afford `hairlineStrong`.
    ///
    /// The radius is a parameter only so a pill-shaped popover can pass its own; the
    /// default is the container radius every card in the app uses.
    func popoverChrome(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Theme.Colors.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline))
            .elevation(.hover)
    }

    /// A system `.popover`'s CONTENT, wearing the app's own container: the inset, an
    /// optional fixed width, ``popoverChrome()``, and a transparent host so only this
    /// card shows.
    ///
    /// The order is the whole point — inset, then width, then chrome. A background
    /// sizes to the view it decorates, so chrome applied before the frame draws
    /// around the content and lets the frame pad it with nothing.
    ///
    /// Note this trades away the native popover's ARROW: a transparent host has
    /// nothing to draw one from. The overflow menu made that trade first, and the
    /// card's own shadow does the pointing well enough at this size.
    func popoverContent(
        padding: CGFloat = Theme.Spacing.lg, width: CGFloat? = nil
    ) -> some View {
        self
            .padding(padding)
            .frame(width: width)
            .popoverChrome()
            .presentationBackground(.clear)
    }
}

// MARK: - The native translucent window material (D1b)

/// An `NSVisualEffectView` placed behind the shell so the desktop shows through the
/// window's outer margins + the sidebar rail — preserving the Mac vibrancy under the
/// dark-studio look. The `#212121` content panel is drawn opaque ON TOP of this.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - Compile-time hex colours

extension Color {
    /// A `Color` from a 24-bit `0xRRGGBB` literal (sRGB), for token definitions.
    /// (The app's other hex path — `init?(hexString:)` in `SharedThumbnail` — parses
    /// STORED strings; this one is for compile-time literals only.)
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    /// An `NSColor` from a 24-bit `0xRRGGBB` literal (sRGB), for the AppKit token
    /// mirrors used by the layer-backed grid.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
