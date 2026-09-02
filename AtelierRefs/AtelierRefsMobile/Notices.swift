// AtelierRefsMobile — every screen with nothing on it (093 § 7, 098 · P6).
//
// 093 § 7 lists "empty and error states" among the things it deliberately does not design,
// with one exception it asks to be closed early — a missing App Group is a typed FATAL
// error by design (092 · S1 · decision 3) and something has to render it. 098 brings the
// rest into scope: an empty library, an empty collection, a failed drain, a failed export
// and that missing container are the five screens this file draws.
//
// **Why they are one file.** They were three private types in `ContentView.swift` and one
// in `ExportControls.swift`, and the fourth — a bottom card in `warning` on `cardChrome()`
// — was the export's by name only. Nothing about it is about exporting; it is what this app
// says when something went wrong and the grid is still worth looking at. A fifth caller
// arriving (the drain, below) is what made the name a lie rather than a detail.
//
// **Two shapes, and the difference is load-bearing.** A screen with nothing on it takes the
// whole panel (``FailureNotice``, ``EmptyNotice``, ``LoadingNotice``): there is nothing else
// to look at, and centring the sentence is the only honest layout. A condition that arrives
// while there IS something to look at takes a card at the bottom (``WarningNotice``): the
// grid is what the user launched for, and a condition about the inbox must not take the
// library off the screen to report itself.
//
// Nothing here invents a recipe. The card is `cardChrome()` (098 · P3, in `AtelierTokens`),
// the alarm colour is `warning` — the app's single deliberate exception to monochrome — and
// the type roles are the same six `MobileTheme` forwards.

import AtelierBrowse
import AtelierTokens
import SwiftUI

// MARK: - The whole panel

/// The library is being opened, or a collection is being read.
struct LoadingNotice: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(MobileTheme.Colors.inkSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("notice.loading")
    }
}

/// The library could not be opened or read — including the one 093 § 7 asked for by name.
///
/// **The missing App Group lands here.** `LibraryLocation` throws
/// `appGroupIdentifierMissing` when the bundle carries no `AtelierAppGroupIdentifier` and
/// `appGroupContainerUnavailable` when the entitlement does not grant the one it names;
/// 092 · S1 · decision 3 made both fatal rather than falling back to a private container,
/// so that a provisioning bug fails where it is fixable instead of silently writing a
/// second library nobody will ever find. `BrowseFailure.message(for:)` is where each of
/// those becomes a sentence, and this is the screen it is drawn on.
///
/// `warning` is the app's ONE alarm colour and its one deliberate exception to monochrome.
struct FailureNotice: View {
    let message: String

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(MobileTheme.Colors.warning)
            Text(message)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.warning)
                .multilineTextAlignment(.center)
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notice.failure")
    }
}

/// A grid with nothing in it — one of four different nothings.
///
/// **Which one is decided in the package** (``BrowseEmptyState``), because it is decidable:
/// four booleans and a count, no I/O, and the case that used to be missing entirely — a
/// collection holding only subfolders — is missing precisely because the emptiness test was
/// spelled at the call site. What is left here is the drawing.
///
/// Two lines, never three, and neither of them names a control: v1 browse is read-only
/// (091 · D1), so an empty screen offering a verb would be the one place in the app
/// promising something it does not have, in the place a user is most likely to look for it.
struct EmptyNotice: View {
    let state: BrowseEmptyState

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            Text(state.title)
                .font(MobileTheme.Typography.bodyEmphasis)
                .foregroundStyle(MobileTheme.Colors.inkPrimary)
            Text(state.detail)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notice.empty")
    }
}

// MARK: - A card over the grid

/// Something went wrong and the grid is still worth looking at.
///
/// A card rather than a screen: every condition drawn this way — an export that wrote
/// nothing, an inbox that will not enumerate, a pass that quarantined a capture — leaves
/// the library exactly as it was, and taking it off the screen to report a fact about the
/// inbox would be the app punishing the user for its own failure.
///
/// The identifier is a parameter because there are three of these and a UI test asking
/// "which notice is up" is asking about which condition, not which recipe.
struct WarningNotice: View {
    let message: String
    let identifier: String

    var body: some View {
        Text(message)
            .font(MobileTheme.Typography.body)
            .foregroundStyle(MobileTheme.Colors.warning)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.vertical, MobileTheme.Spacing.md)
            .cardChrome()
            .padding(MobileTheme.Spacing.lg)
            .accessibilityIdentifier(identifier)
    }
}

/// The identifiers the notices carry, spelled once (098 · P3's rule for string keys).
enum NoticeID {
    /// An export that could not write anything. Auto-dismisses.
    static let exportFailure = "export.failure"
    /// The inbox could not be counted, so the send control is not there to be missed.
    /// **Does not dismiss** — see `ContentView`'s overlay.
    static let inboxUnreadable = "export.unreadable"
    /// A drain pass found something the user was told the opposite of. Auto-dismisses.
    static let drain = "drain.notice"
}
