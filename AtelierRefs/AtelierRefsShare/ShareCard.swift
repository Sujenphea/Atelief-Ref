// AtelierRefsShare — the receipt (093 § 1).
//
// The whole visible surface of the share extension: one card that says the capture
// landed, or one card that says it did not. No picker, no form, no fields — 093
// decides post-and-dismiss, and this file draws the consequence.
//
// **Where the tokens come from.** They were hand-copied literals here once, each citing
// the `Theme.swift` line it came from, because `Theme.swift` is a macOS app-target file
// that imports AppKit and an extension cannot import its host's target either way. This
// file's own header predicted the ending: *"When S5 brings a real iOS UI, this stops
// being the right shape and a shared cross-platform token target becomes the question."*
// It is `AtelierTokens`, and this card reads it like everything else that draws.
//
// The curation the copy enforced is kept below rather than lost: this names the subset one
// card needs, so nothing here reaches for a token that means nothing in an extension.

import AtelierTokens
import SwiftUI

/// The tokens this card draws with — the shared values, narrowed to what one receipt uses.
enum ShareTheme {
    enum Colors {
        /// Raised cards, sheets, toasts.
        static let surface = Tokens.Colors.surface
        /// Section titles + primary text.
        static let inkPrimary = Tokens.Colors.inkPrimary
        /// Labels, values, captions.
        static let inkSecondary = Tokens.Colors.inkSecondary
        /// Borders, dividers.
        static let hairline = Tokens.Colors.hairline
        /// The app's ONE alarm colour, and the system orange rather than a hex: it has to
        /// stay legible under Increase Contrast and the accessibility colour filters,
        /// which only a system colour gets.
        static let warning = Tokens.Colors.warning
    }

    /// Re-declared rather than aliased: Swift 6 asks the USE site to import the module
    /// that DEFINES a member, and a typealias does not move a definition.
    enum Spacing {
        static let xs = Tokens.Spacing.xs
        static let sm = Tokens.Spacing.sm
        static let md = Tokens.Spacing.md
        static let lg = Tokens.Spacing.lg
        static let xl = Tokens.Spacing.xl
    }

    enum Radius {
        static let chip = Tokens.Radius.chip
        static let card = Tokens.Radius.card
    }

    enum Motion {
        /// The card leaving.
        static let gentle = Tokens.Motion.gentle
        /// The card arriving.
        static let toast = Tokens.Motion.toast
        /// `gentle`'s duration, as a number, so the dismissal can wait for it.
        static let gentleDuration = Tokens.Motion.gentleDuration
    }

    /// `Tokens.Elevation.hover` — 093 § 1 names it for this card. Spelled as three values
    /// because the card applies it to a `.shadow` directly.
    enum Elevation {
        static let color = Tokens.Elevation.hover.color
        static let radius = Tokens.Elevation.hover.radius
        static let y = Tokens.Elevation.hover.y
    }

    /// Running text: descriptions, toast messages. A text style plus a weight, never a
    /// point size, so the card inherits Dynamic Type — which 093 § 4 notes is worth more
    /// on a phone than it ever was on the Mac.
    enum Typography {
        static let body = Tokens.Typography.body
        /// For the dismiss glyph.
        static let caption = Tokens.Typography.caption
    }

    /// Apple's touch minimum. 093 § 5: visual size stays on the tokens, the hit area
    /// is a separate `.contentShape` of at least this square.
    static let touchTarget = Tokens.touchTarget
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
