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
        /// translucent window (D1b) the material supplies this tone; this is painted
        /// BENEATH it as the opaque fallback, for Reduce Transparency and anywhere
        /// else the material has nothing to sample.
        static let canvasOuter = Color(hex: 0x131313)
        /// The inset content panel the grid + detail live inside (opaque, radius 16).
        static let panel = Color(hex: 0x212121)
        /// Raised cards, sheets, toasts.
        static let surface = Color(hex: 0x232326)
        /// Sidebar selection, chips, and the floating bars (on a `hairline` border).
        ///
        /// NOT a popover's own fields and buttons, despite the name. Those sit on
        /// `surface`, where a second raised grey reads as a third layer, so
        /// ``DialogControls`` draws them unfilled on a `hairlineStrong` border instead
        /// — see that file for why selection there is an outline rather than a fill.
        static let field = Color(hex: 0x2C2C30)
        /// The ACTIVE sidebar row — a brighter fill than `field` so the current
        /// destination pops off the translucent sidebar (paired with `hairlineStrong`).
        static let selection = Color(hex: 0x3A3A40)
        /// The selection MARKER drawn over ARTWORK: the grid tile's ring, the gallery
        /// card's ring, the marquee, the canvas item's outline. Distinct from
        /// ``selection``, which is the grey FILL marking the active sidebar row — a
        /// fill can't be read on top of a photograph, and a ring can't be read on top
        /// of a list row.
        static let selectionMark = Color.white
        /// The dark hairline nested just INSIDE ``selectionMark`` wherever the ring is
        /// drawn OVER the image (the grid tile). White alone vanishes on a pale photo,
        /// so the two make a two-sided edge: the white reads against dark artwork, this
        /// reads against light. Neither carries selection alone — that is why it is
        /// half-opaque and 2pt rather than the whisper it was under the blue accent.
        static let selectionMarkContrast = Color.black.opacity(0.5)
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
        /// Pointer-over feedback on a full-width ROW — sidebar nav + collection rows,
        /// the overflow popover's rows and section headers, the search mode segments.
        /// Deliberately a whisper: `selection` marks where you ARE, and hover must not
        /// be mistakable for it. (White rather than `Color.primary` so the SwiftUI rows
        /// and their AppKit siblings in `SidebarOutlineKit` render the same grey.)
        static let hoverRow = Color.white.opacity(0.06)
        /// Pointer-over feedback on a GLYPH BUTTON — toolbar / action-bar icons, where
        /// the fill is the whole affordance and has to read over a busy backdrop.
        static let hoverControl = Color.white.opacity(0.10)
    }

    /// AppKit (`NSColor`) mirrors of the tokens the layer-backed grid cell
    /// (`MasonryGridItem`), the sidebar outline view and the floating add button need.
    /// Every `NSView` / `CALayer` seam draws from HERE — an `NSColor(hex:)` literal in a
    /// view file is a token that has drifted, not a colour choice.
    ///
    /// Only the mirrors an AppKit seam actually reads live here. `field`, `panel` and
    /// `hairline` were mirrored speculatively and read by nothing; a mirror with no
    /// reader is a second copy of a value that can silently fall out of step with the
    /// `Colors` original — which is how three of these had already drifted before.
    /// Add one back when a seam needs it, not before.
    enum NS {
        static let mediaBackdrop = NSColor(hex: 0x141416)
        static let selection = NSColor(hex: 0x3A3A40)
        static let selectionMark = NSColor.white
        static let selectionMarkContrast = NSColor.black.withAlphaComponent(0.5)
        static let inkPrimary = NSColor(hex: 0xF2F1EE)
        static let inkSecondary = NSColor(hex: 0x9A9A9E)
        static let hairlineStrong = NSColor.white.withAlphaComponent(0.14)
        static let hoverRow = NSColor.white.withAlphaComponent(0.06)
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
        /// Small rounded backgrounds: chips, sidebar + menu rows, filter pills.
        /// Deliberately the same value as ``field`` — everything small rounds the
        /// same; the two names record what a call site IS, not two measurements.
        static let chip: CGFloat = 6
        static let field: CGFloat = 6
        /// A glyph button's hover fill — the ``HoverHighlight`` default and the
        /// selection bar's icons. Its own step because it sits between a chip and a
        /// tile, hugging a 15pt icon in a 30×28 hit area.
        static let control: CGFloat = 7
        static let tile: CGFloat = 8
        static let card: CGFloat = 12
        static let cover: CGFloat = 14
        /// The largest rounded surface: the content panel, and the detail page's hero
        /// colour swatch.
        static let panel: CGFloat = 16
        // No `sheet`: the app's three sheets are system `.sheet` presentations and
        // AppKit draws their corners. The token named a radius the app never got to
        // choose.
    }

    // MARK: - Motion (one canonical set — replaces the per-site springs)

    enum Motion {
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let gentle = Animation.easeOut(duration: 0.15)
        static let toast = Animation.spring(response: 0.35, dampingFraction: 0.85)
    }

    // MARK: - Elevation (hover / rest shadow tokens)

    struct Elevation {
        /// Black at this alpha. Stored as the ALPHA rather than a ready-made `Color` so
        /// the AppKit seams can mirror the same token — `CALayer.shadowOpacity` wants a
        /// `Float`, and a `Color` can't be taken apart again.
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat

        var color: Color { .black.opacity(opacity) }

        // No `rest`: nothing rested at 0.40 / 2 / 1. The two small resting shadows the
        // app does draw — `ToastCard` (0.15 / 8 / 3) and `FanCard` (0.2 / 3 / 2) — are
        // genuinely different weights rather than drifted copies of it, so collapsing
        // them onto one token would be inventing a rule, not recording one.
        static let hover = Elevation(opacity: 0.55, radius: 14, y: 8)
        /// A floating BAR or pill riding directly over content it did not lay out — the
        /// selection action bar, the import pill, the Space format bubble. Softer and
        /// lower than `hover`: these track a thing on screen, so a heavy shadow would
        /// read as a second object rather than as the bar's own lift.
        static let floating = Elevation(opacity: 0.35, radius: 14, y: 5)
    }

    // MARK: - Typography

    /// The app's nine text roles — every piece of TEXT it draws. Four are the Figma's
    /// original tokens; five replace the raw SwiftUI text styles that had been
    /// standing in for them at 70 sites.
    ///
    /// Each is a text style plus a weight, NOT a point size. That is a deliberate
    /// reversal of how the first four were written, and the reason is Dynamic Type:
    /// `Font.system(size:)` does not scale with the Accessibility text-size setting,
    /// and `Font.system(size:weight:relativeTo:)` — which would give exact sizes AND
    /// scaling — does not exist. `relativeTo:` belongs to `Font.custom`, which needs a
    /// font NAME; the only name matching the system font's metrics is the private
    /// `.AppleSystemUIFont`, and CoreText warns against it. A name that stops
    /// resolving falls back silently (`.SFNS-Regular` yields Times New Roman), which
    /// is not a failure mode worth accepting for every string in the app.
    ///
    /// So the sizes are Apple's, and the app inherits Dynamic Type for free. On macOS
    /// today those land at: largeTitle 26 · title2 17 · title3 15 · headline 13 ·
    /// body 13 · callout 12 · subheadline 11 · caption2 10. Seven of the nine roles
    /// therefore render exactly what they rendered before this change.
    enum Typography {
        // No `display`: the app's only `.largeTitle` was an empty-state GLYPH, not
        // text, and it now takes an explicit glyph size like its siblings. Adding the
        // role anyway would have put a token with no reader straight back into a file
        // that just had five removed for exactly that.

        /// A sheet / overlay title ("Snapshots", "Capture", "Export moodboard").
        static let pageTitle = Font.system(.title2, design: .default, weight: .semibold)
        /// The ONE page / section title role. Home section headers ("Collections",
        /// "Spaces"), the Collection + Space page titles, and the detail inspector
        /// section headers ("Data", "Source", "Details") all share this so no page
        /// title drifts to its own `.title2`/`.title3`/`.headline`.
        static let sectionTitle = Font.system(.title3, design: .default, weight: .semibold)
        /// Sidebar top-nav rows ("Home", "Search", …).
        static let navItem = Font.system(.title2, design: .default, weight: .medium)
        /// Sidebar collection rows, chip / field text.
        static let row = Font.system(.body, design: .default, weight: .regular)
        /// Emphasised body — a card title, a list row's heading.
        static let bodyEmphasis = Font.system(.headline, design: .default, weight: .semibold)
        /// Running text: descriptions, toast messages, secondary rows.
        static let body = Font.system(.callout, design: .default, weight: .regular)
        /// Metadata labels + values.
        static let label = Font.system(.subheadline, design: .default, weight: .regular)
        /// The smallest text the app draws — captions, counters, badge numerals.
        static let caption = Font.system(.caption2, design: .default, weight: .regular)
    }
}

// MARK: - Shadow convenience

extension View {
    /// Apply an `Elevation` token as a drop shadow.
    func elevation(_ e: Theme.Elevation) -> some View {
        shadow(color: e.color, radius: e.radius, y: e.y)
    }
}

extension CALayer {
    /// Apply an `Elevation` token to a layer-backed seam, so an AppKit surface lifts by
    /// the same amount as its SwiftUI siblings. AppKit's y axis is not flipped, so the
    /// token's downward offset becomes a NEGATIVE `shadowOffset.height`.
    func applyElevation(_ e: Theme.Elevation) {
        masksToBounds = false
        shadowColor = NSColor.black.cgColor
        shadowOpacity = Float(e.opacity)
        shadowRadius = e.radius
        shadowOffset = CGSize(width: 0, height: -e.y)
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
    /// The ARROW SURVIVES this. `presentationBackground` clears the SwiftUI hosting
    /// view; the arrow belongs to `NSPopover`'s own frame, which AppKit draws either
    /// way. So the eight system `.popover` sites show this card WITH a native arrow,
    /// while the in-window surfaces that call ``popoverChrome()`` directly (the Space
    /// format panels, the search suggestions) show the card alone — the app's two
    /// popover families do not currently match.
    ///
    /// Losing the arrow means giving up `.popover` for an anchored in-window overlay,
    /// and with it `NSPopover`'s transient dismissal and focus hand-back — which
    /// ``SpaceSpacingPopover`` deliberately depends on (see its file comment). That trade
    /// has not been made.
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
