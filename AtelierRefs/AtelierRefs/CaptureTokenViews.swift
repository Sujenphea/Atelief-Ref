//
//  CaptureTokenViews.swift
//  AtelierRefs
//
//  The pairing-token facts shared by the two surfaces that show them: the
//  sidebar's Capture pane (``AppShellView``) and the Settings window's Browser
//  Capture section (``SettingsView``). Both rendered the endpoint, the token, its
//  Copy button, and the same explanatory sentence independently — and the sentence
//  had already drifted ("browser extension" in one, "Chrome extension" in the
//  other). The wording is now settled on **Chrome**: that is the store the
//  extension actually ships to (`extension/STORE-LISTING.md`), so it is the more
//  actionable instruction.
//
//  Only the FACTS live here. Layout stays with each surface — a grouped `Form`
//  row and a free-form pane genuinely want different chrome, and forcing one
//  view to serve both would need a style flag for every difference.
//
//  ``CaptureEndpointStatus`` is the one place that rule bends, and only because the
//  third surface (``OnboardingSheet``) had drawn the SAME indicator a third time.
//  Three copies of a dot whose colours encode a rule is three places to forget the
//  rule, so the widget is shared and only its font is a parameter.
//

import SwiftUI

/// The strings and display rules both capture surfaces share.
nonisolated enum CaptureCopy {
    /// The loopback host the extension posts captures to.
    static let host = "127.0.0.1"

    /// Stands in for a token that has not been minted yet.
    static let tokenPlaceholder = "—"

    /// The one explanation of what the token is for.
    static let explainer =
        "Paste this token into the AtelierRefs Chrome extension's options to "
        + "authorize captures. It never leaves your Mac."

    /// Confirmation that Copy did something.
    ///
    /// The app's ⌘C deliberately stays SILENT on a full success — "the pasteboard
    /// content is the feedback, matching standard macOS Copy" (052 · B1). This is
    /// the case that reasoning doesn't cover: the token is middle-truncated on every
    /// surface that shows it, so what landed on the pasteboard is a string the user
    /// cannot read back to check, and the button gives no state change of its own.
    /// A Copy you can't verify needs to say so.
    static let tokenCopied = "Pairing token copied"

    /// The endpoint address, bare — for a labelled field.
    static func endpoint(port: UInt16) -> String { "\(host):\(port)" }

    /// The endpoint as a sentence — for a status line with an indicator dot.
    static func endpointStatus(port: UInt16, running: Bool) -> String {
        running
            ? "Listening on \(endpoint(port: port))"
            : "Endpoint unavailable (port \(port) in use)"
    }

    /// The token as displayed: the placeholder stands in until one exists.
    static func tokenDisplay(_ token: String) -> String {
        token.isEmpty ? tokenPlaceholder : token
    }

    /// Whether Copy / Regenerate are offered. Deliberately the exact `isEmpty`
    /// test ``IngestionModel/copyCaptureToken()`` guards on — a stricter rule here
    /// (trimming whitespace, say) would enable a button whose action then no-ops.
    static func hasToken(_ token: String) -> Bool { !token.isEmpty }
}

/// The pairing token itself — monospaced, middle-truncated, selectable.
///
/// No `style` parameter any more. It existed so each surface could pick its own text
/// size (`.body` in the Settings form, `.callout` in the pane), which meant the same
/// token rendered at two sizes for no reason either surface could state.
/// ``Theme/Typography/mono`` is now the one answer.
struct CaptureTokenText: View {
    let token: String

    var body: some View {
        Text(CaptureCopy.tokenDisplay(token))
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Colors.inkPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// Copies the pairing token to the pasteboard; disabled until one exists.
struct CaptureTokenCopyButton: View {
    @ObservedObject var model: IngestionModel
    /// The pane spells the action with an icon; the Settings form row is text-only.
    var icon = false
    /// Whether to wear the app's own ``DialogButtonStyle`` instead of the system push
    /// button. True on the panel — where an accent-filled default button would be the
    /// only coloured chrome on screen — and false in the Settings window, whose
    /// grouped `Form` is system chrome and whose other buttons are all stock. Same
    /// reason `style` used to exist: the facts are shared, the dress is per-surface.
    var tokenised = false

    var body: some View {
        let button = Button {
            model.copyCaptureToken()
        } label: {
            if icon {
                Label("Copy", systemImage: "doc.on.doc")
            } else {
                Text("Copy")
            }
        }
        .disabled(!CaptureCopy.hasToken(model.captureToken))

        if tokenised {
            button.buttonStyle(DialogButtonStyle(width: .hug))
        } else {
            button
        }
    }
}

/// The live capture-endpoint indicator — the DOT alone, without a sentence beside it.
///
/// Shared by the Capture pane and the onboarding guide, which drew this twice and
/// would otherwise have had to be de-greened twice. Only the dot is shared: the two
/// surfaces genuinely say different things next to it (the guide prints the endpoint
/// address on its own line above, so repeating it in the status would state it twice),
/// and it is the dot that encodes the colour rule.
///
/// MONOCHROME while it is working, ``Theme/Colors/warning`` when it is not. It was
/// green/orange, which read as a two-colour severity scale the rest of the app does
/// not have. The app's rule is that colour means something is WRONG — so "listening"
/// is a filled ink dot, and only the broken state is allowed to be orange. A hollow
/// ring rather than a dimmer fill for that state, so the two differ in SHAPE as well
/// as colour and survive a colour-blind reading.
struct CaptureEndpointDot: View {
    let running: Bool
    var size: CGFloat = 8

    var body: some View {
        Group {
            if running {
                Circle().fill(Theme.Colors.inkPrimary)
            } else {
                Circle().strokeBorder(Theme.Colors.warning, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        // The state can flip while the surface is open (another build takes the port,
        // or gives it back), and an indicator that changes meaning silently is easy to
        // miss — `gentle` is the app's token for a small state cross-fade.
        .animation(Theme.Motion.gentle, value: running)
    }
}

/// The endpoint dot plus ``CaptureCopy``'s sentence — the Capture pane's status line.
struct CaptureEndpointStatus: View {
    let port: UInt16
    let running: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            CaptureEndpointDot(running: running)
            Text(CaptureCopy.endpointStatus(port: port, running: running))
                .font(Theme.Typography.body)
                .foregroundStyle(running ? Theme.Colors.inkSecondary : Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The caption under the token explaining what to do with it.
struct CaptureTokenExplainer: View {
    var body: some View {
        Text(CaptureCopy.explainer)
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
