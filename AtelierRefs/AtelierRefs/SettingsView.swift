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
    /// Observed separately from `model` (008 · H5): a nested `ObservableObject`
    /// doesn't propagate its changes through its owner, so progress ticks would
    /// never reach this view otherwise.
    @ObservedObject var backup: BackupController

    /// The first-run flag ``ContentView`` gates onboarding on — flipping it false
    /// here re-shows the setup guide on the next main-window appearance.
    @AppStorage("AtelierDidCompleteOnboarding") private var didCompleteOnboarding = false

    @State private var confirmRegenerate = false

    var body: some View {
        Form {
            captureSection
            librarySection
            backupSection
            setupSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        // Re-resolve on every appearance: the window outlives any single visit,
        // and a drive can be unplugged between two of them.
        .onAppear { model.refreshBackupFolder() }
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

    // MARK: - Off-device backup (008 H4)

    private var backupSection: some View {
        Section("Backup") {
            LabeledContent("Folder") {
                Text(backupFolderText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(model.backupFolderURL == nil ? .secondary : .primary)
            }
            HStack {
                Button(model.backupFolder.hasFolder ? "Change Folder…" : "Choose Folder…") {
                    BackupFolderPanel.present { url in
                        if let url { model.setBackupFolder(url) }
                    }
                }
                .disabled(backup.isRunning)
                if model.backupFolder.hasFolder {
                    Button("Clear", role: .destructive) { model.clearBackupFolder() }
                        .disabled(backup.isRunning)
                }
            }
            // Shown only when something is actually wrong — an unreachable drive,
            // a revoked grant, a folder inside the library.
            if let message = model.backupFolderMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            backupRunRow
            Text(BackupTarget.explainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Back Up Now" / "Stop", the progress bar while a run is in flight, and
    /// the last-run line (008 · H5).
    @ViewBuilder
    private var backupRunRow: some View {
        HStack {
            Button("Back Up Now") { model.runBackupNow() }
                .disabled(!model.canRunBackup)
            if backup.isRunning {
                Button("Stop") { backup.cancel() }
                // Deliberately not `.destructive`: stopping keeps everything
                // already copied, so it destroys nothing.
                ProgressView(value: backup.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
            }
        }
        // Only once there is a target — "Never backed up" beside a "Choose
        // Folder…" button states the obvious twice.
        if model.backupFolder.hasFolder, !backup.isRunning {
            Text(BackupTarget.statusLine(for: backup.lastRun))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // A run that couldn't start says why, and what to do about it.
        if let message = backup.lastRun?.message, !backup.isRunning {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The folder row's text: the resolved path, else the reason there isn't one.
    /// A chosen-but-unreachable target reads as "Unavailable" rather than blank,
    /// so the row never implies the target was forgotten (it wasn't — the
    /// bookmark is kept precisely so reconnecting a drive is enough).
    private var backupFolderText: String {
        if let url = model.backupFolderURL {
            return url.path(percentEncoded: false)
        }
        return model.backupFolder.hasFolder ? "Unavailable" : "None chosen"
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
