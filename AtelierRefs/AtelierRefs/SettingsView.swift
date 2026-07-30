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
                Text("127.0.0.1:\(String(model.capturePort))")
                    .textSelection(.enabled)
                    .foregroundStyle(model.captureEndpointRunning ? .primary : .secondary)
            }
            LabeledContent("Pairing token") {
                HStack(spacing: 8) {
                    Text(model.captureToken.isEmpty ? "—" : model.captureToken)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Copy") { model.copyCaptureToken() }
                        .disabled(model.captureToken.isEmpty)
                }
            }
            Button("Regenerate Token…", role: .destructive) { confirmRegenerate = true }
                .disabled(model.captureToken.isEmpty)
                .confirmationDialog(
                    "Regenerate the pairing token?",
                    isPresented: $confirmRegenerate, titleVisibility: .visible
                ) {
                    Button("Regenerate", role: .destructive) { model.regenerateCaptureToken() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The current token stops working immediately. You'll need to "
                         + "paste the new token into the browser extension to re-pair.")
                }
            Text("Paste this token into the AtelierRefs browser extension's options to "
                 + "authorize captures. It never leaves your Mac.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
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
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("Setup") {
            Button("Show Setup Guide Again") { didCompleteOnboarding = false }
            Text("Re-opens the first-run walkthrough (install the extension, pair the "
                 + "token, capture something) on the main window.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button("Export Diagnostics…") { model.exportDiagnostics() }
            Text("Saves a plain-text report (versions, sizes, counts) and reveals it in "
                 + "Finder — for attaching to a bug report. It contains no library content.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }
}
