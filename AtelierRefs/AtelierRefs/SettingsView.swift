//
//  SettingsView.swift
//  AtelierRefs
//
//  010 · Phase 2 — the standard macOS Settings scene (⌘,). A home for the pieces
//  that previously had none: the browser-capture pairing secret (copy /
//  regenerate), the on-disk Library location, and a way to replay the first-run
//  setup guide. Shares the app's single ``IngestionModel`` (lifted to App level).
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: IngestionModel

    /// The first-run flag ``ContentView`` gates onboarding on — flipping it false
    /// here re-shows the setup guide on the next main-window appearance.
    @AppStorage("AtelierDidCompleteOnboarding") private var didCompleteOnboarding = false

    @State private var confirmRegenerate = false

    var body: some View {
        Form {
            captureSection
            librarySection
            setupSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }

    // MARK: - Browser capture

    private var captureSection: some View {
        Section("Browser Capture") {
            LabeledContent("Endpoint") {
                Text(CaptureCopy.endpoint(port: model.capturePort))
                    .textSelection(.enabled)
                    .foregroundStyle(model.captureEndpointRunning ? .primary : .secondary)
            }
            LabeledContent("Pairing token") {
                HStack(spacing: 8) {
                    CaptureTokenText(token: model.captureToken)
                    CaptureTokenCopyButton(model: model)
                }
            }
            Button("Regenerate Token…", role: .destructive) { confirmRegenerate = true }
                .disabled(!CaptureCopy.hasToken(model.captureToken))
                .confirmationDialog(
                    "Regenerate the pairing token?",
                    isPresented: $confirmRegenerate, titleVisibility: .visible
                ) {
                    Button("Regenerate", role: .destructive) { model.regenerateCaptureToken() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The current token stops working immediately. You'll need to "
                         + "paste the new token into the Chrome extension to re-pair.")
                }
            CaptureTokenExplainer()
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section("Library") {
            LabeledContent("Location") {
                Text(model.libraryRoot?.path(percentEncoded: false) ?? "Opening…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("Show in Finder") { model.revealLibraryInFinder() }
                .disabled(model.libraryRoot == nil)
            Text("Your images, database, and thumbnails live here. Snapshots (File ▸ "
                 + "Snapshot Now) are your in-app recovery points.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("Setup") {
            Button("Show Setup Guide Again") { didCompleteOnboarding = false }
            Text("Re-opens the first-run walkthrough (install the extension, pair the "
                 + "token, capture something) on the main window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button("Export Diagnostics…") { model.exportDiagnostics() }
            Text("Saves a plain-text report (versions, sizes, counts) and reveals it in "
                 + "Finder — for attaching to a bug report. It contains no library content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
