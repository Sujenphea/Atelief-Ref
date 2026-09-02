// AtelierTokens — spacing, radius, motion, elevation, and the two lone constants.
//
// Everything here is a NUMBER or a SwiftUI value built from one, which is why it crosses
// platforms unchanged: 4/8/12/16/24/40 is a rhythm, not a density, and it reads the same
// at 390pt as at 1100. What does NOT cross is behaviour built on top — `CALayer`'s
// shadow, an `NSVisualEffectView` — and none of that is here.

import SwiftUI

extension Tokens {

    /// The 4-pt scale.
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 40
    }

    public enum Radius {
        /// Small rounded backgrounds: chips, sidebar and menu rows, filter pills.
        /// Deliberately the same value as ``field`` — everything small rounds the same;
        /// the two names record what a call site IS, not two measurements.
        public static let chip: CGFloat = 6
        public static let field: CGFloat = 6
        /// A glyph button's hover fill. Its own step because it sits between a chip and a
        /// tile, hugging a 15pt icon in a 30×28 hit area — a POINTER measurement, which
        /// is why the phone has no reader for it.
        public static let control: CGFloat = 7
        public static let tile: CGFloat = 8
        public static let card: CGFloat = 12
        public static let cover: CGFloat = 14
        /// The largest rounded surface: the content panel, and the detail page's hero
        /// colour swatch.
        public static let panel: CGFloat = 16
    }

    /// One canonical set, replacing the five per-site springs the app had grown.
    public enum Motion {
        public static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
        public static let gentle = Animation.easeOut(duration: 0.15)
        public static let toast = Animation.spring(response: 0.35, dampingFraction: 0.85)
        /// ``gentle``'s duration as a number, so a caller that has to WAIT for the
        /// animation can — the share extension dismisses itself after its card leaves.
        public static let gentleDuration: Duration = .milliseconds(150)
    }

    /// A hover / floating shadow.
    ///
    /// Stored as the ALPHA rather than a ready-made `Color` so an AppKit seam can mirror
    /// the same token: `CALayer.shadowOpacity` wants a `Float`, and a `Color` cannot be
    /// taken apart again.
    public struct Elevation: Sendable, Equatable {
        public let opacity: Double
        public let radius: CGFloat
        public let y: CGFloat

        public init(opacity: Double, radius: CGFloat, y: CGFloat) {
            self.opacity = opacity
            self.radius = radius
            self.y = y
        }

        public var color: Color { .black.opacity(opacity) }

        public static let hover = Elevation(opacity: 0.55, radius: 14, y: 8)
        /// A floating BAR or pill riding directly over content it did not lay out — the
        /// selection action bar, the import pill, the Space format bubble. Softer and
        /// lower than ``hover``: these track a thing on screen, so a heavy shadow would
        /// read as a second object rather than as the bar's own lift.
        public static let floating = Elevation(opacity: 0.35, radius: 14, y: 5)
    }

    /// What "unavailable" looks like on a `.plain`-family control, which drops the
    /// system's own dimming — so the app has to draw it. A SwiftUI fact, true on both
    /// platforms.
    public static let disabledOpacity: Double = 0.35

    /// Apple's touch minimum. 093 § 5's rule: visual size stays on the tokens, and a hit
    /// area is a SEPARATE `.contentShape` of at least this square. Inflating padding to
    /// 44 would make phone chrome visually enormous to solve an invisible problem.
    public static let touchTarget: CGFloat = 44
}

// MARK: - Chrome

extension View {
    /// Apply an ``Tokens/Elevation`` token as a drop shadow. The AppKit seam that has to
    /// flip the y sign for an unflipped axis stays where AppKit is.
    public func elevation(_ e: Tokens.Elevation) -> some View {
        shadow(color: e.color, radius: e.radius, y: e.y)
    }

    /// A raised card: a rounded ``Tokens/Colors/surface`` fill under the content, lifted
    /// by ``Tokens/Elevation/floating``.
    ///
    /// The recipe was spelled three times in the companion app — both export notices and
    /// the share extension's card — as five lines of `background(RoundedRectangle(…))`
    /// plus a `.shadow` reading three values off a mirror of the elevation token. Which is
    /// how the phone came to have a `MobileTheme.Elevation` that restated `floating`'s
    /// colour, radius and y as three separate constants: the call sites could not use
    /// ``elevation(_:)`` because they were applying it beside a background rather than to
    /// one, so they took the token apart. This is that composition, named.
    ///
    /// `cornerRadius` is a parameter rather than fixed at ``Tokens/Radius/card`` because
    /// the two names in that enum record what a call site IS; a caller drawing a cover or
    /// a panel says so.
    public func cardChrome(cornerRadius: CGFloat = Tokens.Radius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Tokens.Colors.surface))
            .elevation(.floating)
    }

    /// An inset field or chip: a rounded ``Tokens/Colors/field`` fill, a
    /// ``Tokens/Colors/hairline`` border, and a matching `contentShape` so the hit area is
    /// the shape rather than the label's bounding box.
    ///
    /// The `contentShape` is the part worth having in one place. It is what 093 § 5's rule
    /// depends on — visual size stays on the tokens and the hit area is stated separately —
    /// and it is the line a hand-copied recipe drops, which produces a chip that looks
    /// right and is only tappable on its text.
    public func fieldChrome(cornerRadius: CGFloat = Tokens.Radius.field) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(Tokens.Colors.field))
            .overlay(shape.strokeBorder(Tokens.Colors.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
