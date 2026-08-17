//
//  Theme.swift
//  AtelierRefs
//
//  The Mac's view of the design tokens, plus the parts of "theme" that are AppKit and
//  therefore cannot be shared.
//
//  **The values moved out.** They live in `AtelierTokens`, a package the Mac app, the
//  phone app and the share extension all link — because the same palette had been written
//  by hand three times, once per target, and a hand-copied `#212121` is a drift waiting
//  for the first adjustment. What is left here is what only a Mac has: the `NSColor`
//  twins the layer-backed seams need, the `CALayer` shadow, the window material, and the
//  popover container.
//
//  The forwarding enums below are deliberate and not ceremony. They keep every call site
//  in the app reading `Theme.Colors.panel`, and they record which tokens the MAC uses —
//  the same curation `MobileTheme` makes for the phone. A token with no reader is a copy
//  waiting to be picked up by mistake; a token with a reader on one platform and none on
//  the other is worth saying out loud.
//
//  Monochrome by design — both Figma frames confirm it. There is NO coloured accent:
//  emphasis is a raised grey `field` fill + white/ink text.
//

import AppKit
import AtelierTokens
import SwiftUI

//  **Why these forward by hand rather than `typealias`.** Swift 6 requires the module
//  that DEFINES a member to be imported at the site that uses it, and a typealias does not
//  change where a member is defined — so `typealias Colors = Tokens.Colors` would have
//  made 44 view files import `AtelierTokens` to keep writing the `Theme.Colors.panel` they
//  already write. Re-declaring the names here defines them in this module, where the app
//  already looks. The VALUES still cross once, which is the whole point; only the names
//  are restated, and a name that has no reader on this platform is left out.
enum Theme {

    // MARK: - Colour (dark studio, monochrome)

    enum Colors {
        static let canvasOuter = Tokens.Colors.canvasOuter
        static let panel = Tokens.Colors.panel
        static let surface = Tokens.Colors.surface
        static let field = Tokens.Colors.field
        static let selection = Tokens.Colors.selection
        static let selectionMark = Tokens.Colors.selectionMark
        static let selectionMarkContrast = Tokens.Colors.selectionMarkContrast
        static let mediaBackdrop = Tokens.Colors.mediaBackdrop
        static let inkPrimary = Tokens.Colors.inkPrimary
        static let inkSecondary = Tokens.Colors.inkSecondary
        static let hairline = Tokens.Colors.hairline
        static let hairlineStrong = Tokens.Colors.hairlineStrong
        /// Pointer-over feedback on a full-width ROW. Deliberately a whisper: `selection`
        /// marks where you ARE, and hover must not be mistakable for it.
        static let hoverRow = Tokens.Colors.hoverRow
        /// Pointer-over feedback on a GLYPH BUTTON, where the fill is the whole
        /// affordance and has to read over a busy backdrop.
        static let hoverControl = Tokens.Colors.hoverControl
        /// The app's ONE alarm colour — every "healthy" state is ink, so colour appearing
        /// anywhere in the chrome means exactly one thing.
        static let warning = Tokens.Colors.warning
    }

    /// AppKit (`NSColor`) mirrors of the tokens the layer-backed grid cell
    /// (`MasonryGridItem`), the sidebar outline view and the floating add button need.
    /// Every `NSView` / `CALayer` seam draws from HERE — an `NSColor(hex:)` literal in a
    /// view file is a token that has drifted, not a colour choice.
    ///
    /// **Built from `Tokens.Hex`, not restated.** These used to be hand-written hex
    /// literals beside the SwiftUI originals, and three of them had drifted before the
    /// list was culled to the mirrors with readers. Deriving both representations from
    /// one number is what makes that impossible rather than merely watched.
    ///
    /// Only the mirrors an AppKit seam actually reads live here — add one back when a
    /// seam needs it, not before.
    enum NS {
        static let mediaBackdrop = NSColor(hex: Tokens.Hex.mediaBackdrop)
        static let selection = NSColor(hex: Tokens.Hex.selection)
        static let selectionMark = NSColor.white
        static let selectionMarkContrast =
            NSColor.black.withAlphaComponent(Tokens.Alpha.selectionMarkContrast)
        static let inkPrimary = NSColor(hex: Tokens.Hex.inkPrimary)
        static let inkSecondary = NSColor(hex: Tokens.Hex.inkSecondary)
        static let hairlineStrong =
            NSColor.white.withAlphaComponent(Tokens.Alpha.hairlineStrong)
        static let hoverRow = NSColor.white.withAlphaComponent(Tokens.Alpha.hoverRow)
        static let hoverControl = NSColor.white.withAlphaComponent(Tokens.Alpha.hoverControl)
    }

    // MARK: - Scale

    /// The 4-pt scale.
    enum Spacing {
        static let xs = Tokens.Spacing.xs
        static let sm = Tokens.Spacing.sm
        static let md = Tokens.Spacing.md
        static let lg = Tokens.Spacing.lg
        static let xl = Tokens.Spacing.xl
        static let xxl = Tokens.Spacing.xxl
    }

    enum Radius {
        static let chip = Tokens.Radius.chip
        static let field = Tokens.Radius.field
        static let control = Tokens.Radius.control
        static let tile = Tokens.Radius.tile
        static let card = Tokens.Radius.card
        static let cover = Tokens.Radius.cover
        static let panel = Tokens.Radius.panel
    }

    /// One canonical set, replacing the five per-site springs the app had grown.
    enum Motion {
        static let snappy = Tokens.Motion.snappy
        static let gentle = Tokens.Motion.gentle
        static let toast = Tokens.Motion.toast
    }

    /// The elevation TYPE is shared; `.elevation(.hover)` resolves its cases on the
    /// package's type, so the handful of files that write one import `AtelierTokens`.
    typealias Elevation = Tokens.Elevation

    /// The app's nine text roles — every piece of TEXT it draws. Each is a text style
    /// plus a weight, NOT a point size, which is what makes Dynamic Type work; see the
    /// package for why exact sizes are not on offer.
    enum Typography {
        static let pageTitle = Tokens.Typography.pageTitle
        static let sectionTitle = Tokens.Typography.sectionTitle
        static let navItem = Tokens.Typography.navItem
        static let row = Tokens.Typography.row
        static let bodyEmphasis = Tokens.Typography.bodyEmphasis
        static let body = Tokens.Typography.body
        static let barLabel = Tokens.Typography.barLabel
        static let label = Tokens.Typography.label
        static let caption = Tokens.Typography.caption
        static let mono = Tokens.Typography.mono
    }

    /// What "unavailable" looks like on a `.plain`-family control — those drop the
    /// system's own disabled dimming, so the app has to draw it.
    static let disabledOpacity = Tokens.disabledOpacity
}

// MARK: - Elevation on a layer

extension CALayer {
    /// Apply an `Elevation` token to a layer-backed seam, so an AppKit surface lifts by
    /// the same amount as its SwiftUI siblings. AppKit's y axis is not flipped, so the
    /// token's downward offset becomes a NEGATIVE `shadowOffset.height` — which is
    /// exactly why this stayed behind when the token itself crossed platforms.
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
    /// That is the opposite balance to a floating BAR (`floatingBarChrome()`), which
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

extension NSColor {
    /// An `NSColor` from a 24-bit `0xRRGGBB` literal (sRGB), for the AppKit token
    /// mirrors used by the layer-backed grid. The SwiftUI half of this pair lives in
    /// `AtelierTokens`; this one stays where AppKit is.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
