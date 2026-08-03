//
//  RestoreBackupSheet.swift
//  AtelierRefs
//
//  008 · H5c — pick which backup in the chosen folder to restore from.
//
//  A LIST rather than a single "Restore" button, even when the folder holds one
//  backup. The folder is namespaced by library id and may hold several; and more
//  importantly, restoring is the moment a user most needs to see exactly what
//  they are about to get — when it was taken, how much of it there is — before
//  it replaces what they have. A button labelled "Restore" with that hidden
//  behind it is the wrong shape at the wrong moment.
//
//  Modelled on `SnapshotsSheet`, which asks the same question about local
//  snapshots: same row shape, same confirm-then-relaunch story.
//

import AtelierIngestion
import SwiftUI

struct RestoreBackupSheet: View {
    @ObservedObject var model: IngestionModel
    /// Observed separately from `model` — the scan and its results live on the
    /// controller, so they wouldn't reach this view through its owner.
    @ObservedObject var restore: RestoreController

    @State private var confirming: BackupSource?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 460, minHeight: 320)
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { source in
            // Return commits, as in every confirmation dialog here — a
            // `role: .destructive` button is left unbound otherwise (see
            // ``ContentView``'s delete dialog for the mechanism).
            Button("Restore", role: .destructive) {
                model.restoreFromBackup(source)
                confirming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { source in
            Text(BackupTarget.restoreConfirmation(for: source))
        }
    }

    private var header: some View {
        HStack {
            Text("Restore from Backup").font(Theme.Typography.bodyEmphasis)
            Spacer()
            Button("Done") { model.showRestoreBackups = false }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if restore.isScanning {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the backup folder…")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if restore.candidates.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("Nothing to restore")
                Text(restore.scanMessage ?? BackupTarget.noBackupsFound)
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            VStack(spacing: 0) {
                List(restore.candidates, id: \.libraryID) { source in
                    row(for: source)
                }
                Text(BackupTarget.restoreExplainer)
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private func row(for source: BackupSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.completedAt.formatted(date: .abbreviated, time: .shortened))
                Text(BackupTarget.description(of: source))
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                // The library id, because a folder holding two libraries offers
                // no other way to tell which row is which.
                Text(source.libraryID)
                    .font(Theme.Typography.caption).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Restore…") { confirming = source }
        }
        .padding(.vertical, 2)
    }
}
