//
//  SnapshotsSheet.swift
//  AtelierRefs
//
//  The manual backup surface (008 H3): take a snapshot now, or restore the
//  library from an earlier one. Restore is staged and completes on the next
//  launch (the live DB can only be swapped safely before the pool opens), so the
//  action explains that and the current library is set aside, never deleted.
//

import AtelierCore
import SwiftUI

struct SnapshotsSheet: View {
    @ObservedObject var model: IngestionModel
    @State private var confirming: SnapshotFile?
    @State private var deleting: SnapshotFile?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 460, minHeight: 380)
        .confirmationDialog(
            "Restore this snapshot?",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { snapshot in
            Button("Restore", role: .destructive) {
                model.stageRestore(snapshot)
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { snapshot in
            Text("Your current library is set aside (not deleted) and replaced with "
                + "this \(Self.label(for: snapshot.reason).lowercased()) snapshot from "
                + "\(snapshot.date.formatted(date: .abbreviated, time: .shortened)). "
                + "The restore completes the next time you open AtelierRefs.")
        }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { snapshot in
            Button("Delete", role: .destructive) {
                model.deleteSnapshot(snapshot)
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { snapshot in
            Text("This backup file is removed from disk. Your live library is not "
                + "affected. This can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Snapshots").font(.headline)
            Spacer()
            Button {
                model.snapshotNow()
            } label: {
                if model.isSnapshotting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Label("Snapshot Now", systemImage: "camera")
                }
            }
            .disabled(model.snapshotManager == nil || model.isSnapshotting)
            Button("Done") { model.showSnapshots = false }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        // Referencing the version subscribes the sheet so it re-reads the list when
        // a snapshot lands or is deleted.
        let _ = model.snapshotsVersion
        let snapshots = model.availableSnapshots()
        if snapshots.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle).foregroundStyle(.tertiary)
                Text("No snapshots yet")
                Text("A snapshot is taken automatically before risky changes, and daily.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            VStack(spacing: 0) {
                List(snapshots, id: \.url) { snapshot in
                    row(for: snapshot)
                }
                snapshotsFooter(snapshots)
            }
        }
    }

    private func row(for snapshot: SnapshotFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                HStack(spacing: 6) {
                    Text(Self.label(for: snapshot.reason))
                    Text("·")
                    Text(Self.sizeText(model.snapshotByteSize(snapshot)))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore…") { confirming = snapshot }
            Button {
                deleting = snapshot
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this snapshot")
        }
        .padding(.vertical, 2)
    }

    /// A summary of how much disk the backups occupy — the read-only list gave no
    /// sense of footprint before (034 P2).
    private func snapshotsFooter(_ snapshots: [SnapshotFile]) -> some View {
        let total = snapshots.reduce(Int64(0)) { $0 + model.snapshotByteSize($1) }
        return HStack {
            Text("\(snapshots.count) snapshot\(snapshots.count == 1 ? "" : "s")")
            Spacer()
            Text(Self.sizeText(total))
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func label(for reason: SnapshotReason) -> String {
        switch reason {
        case .daily: "Automatic (daily)"
        case .manual: "Manual"
        case .preMigration: "Before an app update"
        case .preDestructive: "Before a delete"
        }
    }
}
