// AtelierRefsMobile — the one control that sends, and the sheet it opens (092 · S6b).
//
// 093 § 2 spent its argument on subtraction: the phone has one destination, so it has one
// navigation control, and the title is it. This adds the second thing in the toolbar, so it
// has to earn the space:
//
//   • it appears ONLY when the inbox has something in it. An empty phone shows the grid and
//     nothing else, which is the resting state 093 designed;
//   • it says the COUNT, because "Send 3" answers the question the icon alone raises, and
//     because a user who has just shared something wants to see the number go up;
//   • it is on the root screen only — a pushed subcollection is a place you are reading, not
//     a place you send from.
//
// The share sheet is the system's, deliberately: 092 · S6 says transport is whatever moves a
// folder, and inventing a picker for AirDrop / Files / iCloud Drive would be building a
// worse copy of the thing every iOS user already knows.

import AtelierBrowse
import AtelierTokens
import SwiftUI
import UIKit

/// The toolbar's send control: a glyph, a count, and the phase it is in.
struct ExportButton: View {
    let count: Int
    let phase: CaptureExport.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MobileTheme.Spacing.xs) {
                if case .working = phase {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MobileTheme.Colors.inkSecondary)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(MobileTheme.Typography.body)
                }
                Text("\(count)")
                    .font(MobileTheme.Typography.label)
                    .monospacedDigit()
            }
            .foregroundStyle(MobileTheme.Colors.inkPrimary)
            // 093 § 5 again: the label keeps its token size, the hit area is stated
            // separately at Apple's minimum.
            .frame(minHeight: MobileTheme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase == .working)
        .accessibilityLabel("Send \(count) captures to your Mac")
        .accessibilityIdentifier("export.send")
    }
}

/// `UIActivityViewController` over the exported FOLDER.
///
/// A folder rather than a zip, because the Mac's importer opens a folder and unzipping
/// first is a step the user has to know to take. If AirDrop of a directory proves
/// unreliable on a device — this cannot be checked in a simulator — the fallback is
/// `NSFileCoordinator`'s `.forUploading` coordination, which hands over a zip of the same
/// folder and is one function call from here.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// What an export says when it could not write anything.
///
/// A toast rather than a screen: the failure modes are "nothing to send" and "nothing
/// readable", neither of which is worth taking the user off the grid for, and the captures
/// are still in the inbox either way.
struct ExportFailureNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(MobileTheme.Typography.body)
            .foregroundStyle(MobileTheme.Colors.warning)
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.vertical, MobileTheme.Spacing.md)
            .cardChrome()
            .padding(MobileTheme.Spacing.lg)
            .accessibilityIdentifier("export.failure")
    }
}

/// The offer to retire what was just sent (096 · 3B).
///
/// **Why this exists at all.** Nothing on the phone ever left the inbox: `InboxArchive`
/// deletes nothing after an export — deliberately, since the phone cannot know whether the
/// share sheet was cancelled, the AirDrop landed, or an import ever ran — so every export
/// re-sent every capture ever made and `inbox/` grew for the life of the device.
///
/// **Why it is an offer and not a button that just does it.** The safe default has to be
/// keeping. `UIActivityViewController`'s completion handler cannot tell a successful AirDrop
/// from a cancelled one, and the Mac says nothing back by design (091 · D4 refuses a second
/// transport direction). The only party who knows is the person who just watched the
/// transfer, so they are asked — once, at the moment they know, with the cautious answer
/// requiring no thought.
///
/// The wording avoids "delete" because nothing is deleted: the captures move to
/// `inbox/sent/` and stay on disk.
struct ExportSentNotice: View {
    let count: Int
    let onClear: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("Sent \(count) \(count == 1 ? "capture" : "captures")")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.inkPrimary)
            Text("Once your Mac has imported them, clear them so the next send only carries what's new.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MobileTheme.Spacing.md) {
                // Keep is FIRST and is the plain one: the cautious answer should be the one
                // a thumb reaches without deciding.
                Button("Keep", action: onKeep)
                    .font(MobileTheme.Typography.label)
                    .foregroundStyle(MobileTheme.Colors.inkSecondary)
                    .frame(minHeight: MobileTheme.touchTarget)
                    .accessibilityIdentifier("export.keep")

                Button("Clear", action: onClear)
                    .font(MobileTheme.Typography.label)
                    .foregroundStyle(MobileTheme.Colors.inkPrimary)
                    .frame(minHeight: MobileTheme.touchTarget)
                    .accessibilityIdentifier("export.clear")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.md)
        .cardChrome()
        .padding(MobileTheme.Spacing.lg)
        .accessibilityIdentifier("export.sent")
    }
}
