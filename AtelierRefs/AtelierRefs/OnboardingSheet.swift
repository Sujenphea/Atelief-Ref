//
//  OnboardingSheet.swift
//  AtelierRefs
//
//  010 · Phase 2 — the first-run walkthrough. The pairing flow already exists;
//  it was just undiscoverable. This sheet makes the path INTO the app explicit:
//  install the extension → pair the token → capture something. Shown once (gated
//  on `AtelierDidCompleteOnboarding`), replayable from Settings.
//

import SwiftUI

struct OnboardingSheet: View {
    @ObservedObject var model: IngestionModel
    /// Called when the user finishes / dismisses — the caller persists the flag.
    let onFinish: () -> Void

    /// Flips the moment a capture lands while the guide is open — a LIVE pairing
    /// confirmation (the token is pasted into the extension out-of-band, so the app
    /// only learns pairing worked when the first capture arrives).
    @State private var receivedFirstCapture = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    step(1, "Install the browser extension",
                         "Load the AtelierRefs extension in Chrome, then open its "
                         + "options page.")
                    step(2, "Pair the capture token",
                         "Copy the token below and paste it into the extension's "
                         + "options to authorize captures. It stays on your Mac.",
                         accessory: AnyView(tokenRow))
                    step(3, "Capture something",
                         "Right-click an image on any page ▸ Save to Atelier, or paste "
                         + "/ drop an image straight into the window. It lands in "
                         + "Unsorted.",
                         accessory: receivedFirstCapture ? capturedConfirmation : nil)
                    outro
                    backupNote
                }
                .padding(24)
            }

            footer
        }
        .frame(width: 520, height: 560)
        // A capture landing while the guide is open confirms pairing succeeded.
        .onChange(of: model.lastCaptureBatch) { _, batch in
            if batch != nil { receivedFirstCapture = true }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to AtelierRefs")
                .font(.title2.bold())
            Text("Your reference library — set up capture in three quick steps.")
                .font(Theme.Typography.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var tokenRow: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("127.0.0.1:\(String(model.capturePort))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 14)
                    Text(model.captureToken.isEmpty ? "Opening library…" : model.captureToken)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .redacted(reason: model.captureToken.isEmpty ? .placeholder : [])
                    Spacer(minLength: 0)
                    Button("Copy") { model.copyCaptureToken() }
                        .controlSize(.small)
                        .disabled(model.captureToken.isEmpty)
                }
                endpointStatus
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.tile))
        )
    }

    /// A live indicator for the local capture endpoint — listening, or the port is
    /// busy so captures can't land (a real, actionable state, not just static
    /// instructions).
    ///
    /// The dot is ``CaptureEndpointDot``, shared with the Capture pane: this drew its
    /// own green/orange circle, so the app stated the same rule in two places. The
    /// SENTENCE stays local — the address is already printed on the row above, so this
    /// surface says "Listening for captures" where the pane names the endpoint.
    private var endpointStatus: some View {
        HStack(spacing: 6) {
            CaptureEndpointDot(running: model.captureEndpointRunning, size: 7)
            Text(model.captureEndpointRunning
                 ? "Listening for captures"
                 : "Endpoint unavailable — port \(model.capturePort) is in use")
                .font(Theme.Typography.caption)
                .foregroundStyle(model.captureEndpointRunning
                                 ? Color.secondary : Theme.Colors.warning)
        }
        .accessibilityElement(children: .combine)
    }

    /// Shown under step 3 once a capture lands while the guide is open — the pairing
    /// worked end to end.
    private var capturedConfirmation: AnyView {
        AnyView(
            Label("Nice — your first capture landed in Unsorted.", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        )
    }

    /// The closing note — deliberately NOT a numbered step, so the header's "three
    /// quick steps" matches the three numbered setup rows above.
    private var outro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You're set")
                .font(Theme.Typography.bodyEmphasis)
            Text("Organize into collections, arrange spaces, and snapshot from "
                 + "File ▸ Snapshot Now. Re-open this guide any time from Settings (⌘,).")
                .font(Theme.Typography.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    /// Where to set up an off-device backup (008 · H5d).
    ///
    /// Deliberately NOT a numbered step, for the same reason ``outro`` isn't:
    /// choosing a backup folder is not part of getting capture working, and
    /// putting it in the flow would hold the first capture behind a decision the
    /// user may not have made yet (which drive? which cloud folder?). But the
    /// default cadence is `manual` and no folder is chosen out of the box, so
    /// without this the machine-loss case is unprotected until someone goes
    /// looking in Settings — and snapshots, the thing they HAVE seen mentioned,
    /// live inside the library and die with it. Naming it once here is the
    /// difference between an opt-in and a secret.
    private var backupNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Keep a copy somewhere else", systemImage: "externaldrive.badge.timemachine")
                .font(Theme.Typography.bodyEmphasis)
            Text("Snapshots live inside your library, so they won't survive losing "
                 + "this Mac. In Settings (⌘,) ▸ Backup, pick a folder on another "
                 + "drive and set it to run daily.")
                .font(Theme.Typography.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Get Started") { onFinish() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Step row

    private func step(_ number: Int, _ title: String, _ detail: String,
                      accessory: AnyView? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(Theme.Typography.bodyEmphasis)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.tint, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.Typography.bodyEmphasis)
                Text(detail)
                    .font(Theme.Typography.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let accessory { accessory.padding(.top, 4) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)")
    }
}
