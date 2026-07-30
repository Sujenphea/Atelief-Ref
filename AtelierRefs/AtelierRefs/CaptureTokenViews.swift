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

import SwiftUI

/// The strings and display rules both capture surfaces share.
enum CaptureCopy {
    /// The loopback host the extension posts captures to.
    static let host = "127.0.0.1"

    /// Stands in for a token that has not been minted yet.
    static let tokenPlaceholder = "—"

    /// The one explanation of what the token is for.
    static let explainer =
        "Paste this token into the AtelierRefs Chrome extension's options to "
        + "authorize captures. It never leaves your Mac."

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

/// The pairing token itself — monospaced, middle-truncated, selectable. `style`
/// is the only thing that varies between surfaces (`.body` in the Settings form,
/// `.callout` in the pane).
struct CaptureTokenText: View {
    let token: String
    var style: Font.TextStyle = .body

    var body: some View {
        Text(CaptureCopy.tokenDisplay(token))
            .font(.system(style, design: .monospaced))
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

    var body: some View {
        Button {
            model.copyCaptureToken()
        } label: {
            if icon {
                Label("Copy", systemImage: "doc.on.doc")
            } else {
                Text("Copy")
            }
        }
        .disabled(!CaptureCopy.hasToken(model.captureToken))
    }
}

/// The caption under the token explaining what to do with it.
struct CaptureTokenExplainer: View {
    var body: some View {
        Text(CaptureCopy.explainer)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
