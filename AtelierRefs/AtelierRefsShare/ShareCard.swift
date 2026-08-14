// AtelierRefsShare — the receipt (093 § 1).
//
// The whole visible surface of the share extension: one card that says the capture
// landed, or one card that says it did not. No picker, no form, no fields — 093
// decides post-and-dismiss, and this file draws the consequence.
//
// **Why the tokens are restated here rather than imported.** `Theme.swift` is a
// macOS app-target file: it `import AppKit`, mirrors every colour into an `NSColor`
// twin and extends `CALayer`, so it cannot compile for iOS at all, and an app
// extension cannot import its host app's target either way. What crosses is
// therefore the VALUES, copied by hand, each with the `Theme.swift` line it came
// from so the copy is checkable against its source rather than merely plausible.
// 093 § 4 is the list of which tokens cross; this is the subset one card needs.
//
// The rule `Theme.NS` states for the AppKit mirrors governs this copy too — *a
// mirror with no reader is a second copy waiting to drift* — so nothing is restated
// speculatively. Six colours, three geometry constants, two animations, one font
// role: exactly what is drawn below and nothing else. When S5 brings a real iOS UI,
// this stops being the right shape and a shared cross-platform token target becomes
// the question; one card is not enough reader to justify one now.

import SwiftUI

/// The tokens this card draws with — hand-copied values from
/// `AtelierRefs/AtelierRefs/Theme.swift`, cited line by line.
enum ShareTheme {
    enum Colors {
        /// Raised cards, sheets, toasts — `Theme.Colors.surface` (`Theme.swift:32`).
        static let surface = Color(hex: 0x232326)
        /// Section titles + primary text — `Theme.Colors.inkPrimary` (`:63`).
        static let inkPrimary = Color(hex: 0xF2F1EE)
        /// Labels, values, captions — `Theme.Colors.inkSecondary` (`:65`).
        static let inkSecondary = Color(hex: 0x9A9A9E)
        /// Borders, dividers — `Theme.Colors.hairline` (`:67`).
        static let hairline = Color.white.opacity(0.08)
        /// The app's ONE alarm colour — `Theme.Colors.warning` (`:93`). Left as the
        /// SYSTEM orange for the same reason it is there: it has to stay legible under
        /// Increase Contrast and the accessibility colour filters, which only a system
        /// colour gets.
        static let warning = Color.orange
    }

    enum Spacing {
        /// `Theme.Spacing.xs` (`Theme.swift:121`).
        static let xs: CGFloat = 4
        /// `Theme.Spacing.sm` (`:122`).
        static let sm: CGFloat = 8
        /// `Theme.Spacing.md` (`:123`).
        static let md: CGFloat = 12
        /// `Theme.Spacing.lg` (`:124`).
        static let lg: CGFloat = 16
        /// `Theme.Spacing.xl` (`:125`).
        static let xl: CGFloat = 24
    }

    enum Radius {
        /// `Theme.Radius.chip` (`Theme.swift:134`).
        static let chip: CGFloat = 6
        /// `Theme.Radius.card` (`:142`).
        static let card: CGFloat = 12
    }

    enum Motion {
        /// `Theme.Motion.gentle` (`Theme.swift:168`) — the card leaving.
        static let gentle = Animation.easeOut(duration: 0.15)
        /// `Theme.Motion.toast` (`:169`) — the card arriving.
        static let toast = Animation.spring(response: 0.35, dampingFraction: 0.85)
        /// `gentle`'s duration, as a number, so the dismissal can wait for it.
        static let gentleDuration: Duration = .milliseconds(150)
    }

    /// `Theme.Elevation.hover` (`Theme.swift:188`) — 093 § 1 names it for this card.
    /// Applied directly rather than through the `.elevation()` modifier, which lives
    /// in `Theme.swift` beside a `CALayer` extension that does not build here.
    enum Elevation {
        static let color = Color.black.opacity(0.55)
        static let radius: CGFloat = 14
        static let y: CGFloat = 8
    }

    /// Running text: descriptions, toast messages — `Theme.Typography.body`
    /// (`Theme.swift:243`). A text style plus a weight, never a point size, so the
    /// card inherits Dynamic Type — which 093 § 4 notes is worth more on a phone than
    /// it ever was on the Mac.
    enum Typography {
        static let body = Font.system(.callout, design: .default, weight: .regular)
        /// `Theme.Typography.caption` (`:259`), for the dismiss glyph.
        static let caption = Font.system(.caption2, design: .default, weight: .regular)
    }

    /// Apple's touch minimum. 093 § 5: visual size stays on the tokens, the hit area
    /// is a separate `.contentShape` of at least this square.
    static let touchTarget: CGFloat = 44
}

/// Which card is on screen, or none (093 § 1).
///
/// Two cases, not five. `InboxWriter` has four typed failures and
/// `LibraryLocation` a fifth kind of one, and 093 collapses every one of them into
/// this single `.failed`: they are all a lost capture, none leaves anything partial,
/// and the typed payloads (`path:`, `id:`) are for whoever reads the log, not for
/// someone holding a phone.
enum ShareCard: Equatable {
    case saved
    case failed
}

/// The card's state, owned by `ShareViewController` and read by the SwiftUI view.
@MainActor
@Observable
final class ShareCardModel {
    var card: ShareCard?
}

/// The extension's entire UI.
///
/// A clear backdrop with a card at the bottom: the host app stays visible behind it,
/// because the card is a receipt and not a screen (093 § 1). The card sits low for
/// the same reason — it arrives where the share sheet just left.
struct ShareCardView: View {
    let model: ShareCardModel
    /// Called when the user dismisses a FAILURE card. Success dismisses itself.
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let card = model.card {
                cardBody(card)
                    .padding(.horizontal, ShareTheme.Spacing.lg)
                    .padding(.bottom, ShareTheme.Spacing.xl)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity)
                                .animation(ShareTheme.Motion.toast),
                            removal: .opacity.animation(ShareTheme.Motion.gentle)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func cardBody(_ card: ShareCard) -> some View {
        HStack(spacing: ShareTheme.Spacing.md) {
            Text(message(card))
                .font(ShareTheme.Typography.body)
                .foregroundStyle(
                    card == .saved
                        ? ShareTheme.Colors.inkPrimary : ShareTheme.Colors.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            if card == .failed {
                dismissButton
            }
        }
        // `ToastCard`'s recipe (`ToastHost.swift:105`–`:151`) with the action button
        // removed: `surface` on a `hairline` border at `Radius.card`, lifted by
        // `Elevation.hover`. Opaque, not a material — a translucent pill tints from
        // whatever it happens to be floating over, and here that is somebody else's
        // app.
        .padding(.horizontal, ShareTheme.Spacing.lg)
        .padding(.vertical, ShareTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: ShareTheme.Radius.card, style: .continuous)
                .fill(ShareTheme.Colors.surface))
        .overlay(
            RoundedRectangle(cornerRadius: ShareTheme.Radius.card, style: .continuous)
                .strokeBorder(ShareTheme.Colors.hairline, lineWidth: 1))
        .shadow(
            color: ShareTheme.Elevation.color,
            radius: ShareTheme.Elevation.radius,
            y: ShareTheme.Elevation.y)
        .frame(maxWidth: 420)
    }

    /// The failure card's ✕.
    ///
    /// Not a retry — 093 is explicit that there is none, because every failure this
    /// collapses is a container- or filesystem-level condition a second attempt three
    /// hundred milliseconds later hits again, and re-sharing is the retry the user
    /// already knows. This is the dismissal, and the failure card needs one precisely
    /// because it does not auto-dismiss: completing the request is the user's move.
    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(ShareTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(ShareTheme.Colors.inkSecondary)
                .padding(ShareTheme.Spacing.xs)
                // 093 § 5: the glyph keeps its token size and the hit area is stated
                // separately, rather than the padding being inflated to 44 and the
                // chrome growing to match.
                .frame(
                    minWidth: ShareTheme.touchTarget,
                    minHeight: ShareTheme.touchTarget)
                .contentShape(RoundedRectangle(cornerRadius: ShareTheme.Radius.chip))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    /// The one string each card says.
    ///
    /// Success names the destination, mirroring the Mac's capture toast
    /// (`ContentView.swift:257`), because the collection is the one fact the user
    /// cannot otherwise discover — nothing else in this flow mentions one. Failure
    /// names the gesture that IS the retry, per 093.
    private func message(_ card: ShareCard) -> String {
        switch card {
        case .saved: "Saved to Unsorted"
        case .failed: "Couldn't save. Try sharing again."
        }
    }
}

// MARK: - Compile-time hex colours

private extension Color {
    /// A `Color` from a 24-bit `0xRRGGBB` literal (sRGB). The same three lines as
    /// `Theme.swift:366`–`:377`, so the hex literals above can be compared to the
    /// app's character for character.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

#Preview("Saved") {
    let model = ShareCardModel()
    model.card = .saved
    return ShareCardView(model: model, onDismiss: {})
        .background(Color.gray)
}

#Preview("Failed") {
    let model = ShareCardModel()
    model.card = .failed
    return ShareCardView(model: model, onDismiss: {})
        .background(Color.gray)
}
