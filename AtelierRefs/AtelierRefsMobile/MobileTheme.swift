// AtelierRefsMobile — the phone's view of the design tokens (093 § 4).
//
// **The values live in `AtelierTokens` now.** This file used to hold hand-copied literals,
// each citing the `Theme.swift` line it came from so the copy was checkable; there were
// three such copies across the Mac app, this app and the share extension. They are one
// package now, linked by all three, and a `#212121` adjusted anywhere is adjusted
// everywhere.
//
// **What this file still does is CURATE.** 093 § 4 is a list of which tokens cross, and
// that list is information: forwarding only the ones the phone draws is what stops a call
// site here reaching for a token that means nothing on a phone. Absent, and absent
// deliberately:
//
// - `hoverRow` / `hoverControl` — no pointer. `hoverRow` is documented as a whisper
//   precisely so it cannot be mistaken for selection; a press wants the opposite.
// - `Radius.control` — it hugs a 15pt icon in a 30×28 hit area, a pointer measurement.
// - `selectionMark` / `selectionMarkContrast` — v1 has no multiselect.
// - `Typography.navItem` / `barLabel` / `mono` — no sidebar nav, no floating action bar,
//   no pairing token on the phone.
// - `Motion.toast` — the phone shows no toasts; the share extension's card does, and it
//   asks for that token itself.
// - `Elevation.hover` — nothing here floats that high; `floating` is what the export
//   control's sheet lift uses.
//
// Also absent, and not a curation: the Mac's `Theme.NS` mirrors, `CALayer.applyElevation`
// (it flips the shadow's y sign for AppKit's unflipped axis; UIKit's is flipped) and
// `VisualEffectBackground` (a phone has no window margins and no desktop behind them).
// Those are AppKit, and they stayed in `Theme.swift` when the values left it.
//
// The content panel's INSET and corner arc are still not taken: the phone paints `panel`
// full-bleed and keeps only the tone.

import AtelierTokens
import SwiftUI

/// The phone's design tokens — the shared values, curated for what a phone draws.
enum MobileTheme {
    enum Colors {
        /// The app's ground, painted opaque. On the Mac a material supplies this tone
        /// under a translucent window; a phone has no window, so the token is the ground.
        static let canvasOuter = Tokens.Colors.canvasOuter
        /// The content surface the grid and detail live on. Full-bleed here: the Mac's
        /// `Spacing.md` inset and `Radius.panel` arc exist because it is a panel inside a
        /// window beside a sidebar (093 § 4).
        static let panel = Tokens.Colors.panel
        /// Raised cards and sheets.
        static let surface = Tokens.Colors.surface
        /// Chips and inset fields.
        static let field = Tokens.Colors.field
        /// The active row in the collection switcher.
        static let selection = Tokens.Colors.selection
        /// Grid tiles + the detail media area — the art's stable dark ground. 093 § 6
        /// leans on this one: a light image and a dark one sit on the same tone instead
        /// of the image's own edges reading as chrome.
        static let mediaBackdrop = Tokens.Colors.mediaBackdrop
        /// Titles + primary text.
        static let inkPrimary = Tokens.Colors.inkPrimary
        /// Labels, values, captions.
        static let inkSecondary = Tokens.Colors.inkSecondary
        /// Borders and dividers.
        static let hairline = Tokens.Colors.hairline
        /// A stronger hairline for interactive borders.
        static let hairlineStrong = Tokens.Colors.hairlineStrong
        /// The app's ONE alarm colour, and the system orange rather than a hex — it has
        /// to stay legible under Increase Contrast and the accessibility colour filters.
        static let warning = Tokens.Colors.warning
    }

    /// The 4-pt scale. A rhythm, not a density: 4/8/12/16/24/40 reads the same at 390pt
    /// as at 1100.
    ///
    /// Re-declared rather than aliased, like everything else here: Swift 6 asks the USE
    /// site to import the module that DEFINES a member, and a typealias does not move a
    /// definition — so an alias would make every view file import `AtelierTokens` to keep
    /// writing the `MobileTheme.Spacing.sm` it already writes.
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
        static let tile = Tokens.Radius.tile
        static let card = Tokens.Radius.card
        static let cover = Tokens.Radius.cover
        static let panel = Tokens.Radius.panel
    }

    /// Durations and damping, not platform behaviours, so they cross unchanged.
    enum Motion {
        static let snappy = Tokens.Motion.snappy
        static let gentle = Tokens.Motion.gentle
    }

    /// `Tokens.Elevation.floating` — a bar or card riding over content it did not lay
    /// out. Spelled out as three values rather than used through `.elevation()` because
    /// the call sites here apply it to a `.shadow` directly.
    enum Elevation {
        static let color = Tokens.Elevation.floating.color
        static let radius = Tokens.Elevation.floating.radius
        static let y = Tokens.Elevation.floating.y
    }

    /// `.plain`-family controls drop the system's own dimming, so the app draws it — a
    /// SwiftUI fact, true on both platforms.
    static let disabledOpacity = Tokens.disabledOpacity

    /// The type roles this app draws. Each is a text style plus a weight, never a point
    /// size — which is what makes Dynamic Type work, and 093 § 4 notes that reasoning was
    /// written for a Mac and pays off far more on a phone.
    enum Typography {
        static let pageTitle = Tokens.Typography.pageTitle
        static let sectionTitle = Tokens.Typography.sectionTitle
        static let row = Tokens.Typography.row
        static let bodyEmphasis = Tokens.Typography.bodyEmphasis
        static let body = Tokens.Typography.body
        static let label = Tokens.Typography.label
        static let caption = Tokens.Typography.caption
    }

    /// Apple's touch minimum. 093 § 5's rule: visual size stays on the tokens above, and
    /// a hit area is a SEPARATE `.contentShape` of at least this square — the same
    /// separation `HoverHighlight` already makes between its fill and its padded
    /// `.contentShape`, with a different constant. Inflating the padding to 44 would make
    /// phone chrome visually enormous to solve an invisible problem.
    static let touchTarget = Tokens.touchTarget

    /// The gap between grid cells, both ways. One name because the masonry column width
    /// and the vertical stack spacing must be the same number for the decomposition to
    /// reproduce the Mac's frames.
    static let gridSpacing: CGFloat = Tokens.Spacing.sm
}
