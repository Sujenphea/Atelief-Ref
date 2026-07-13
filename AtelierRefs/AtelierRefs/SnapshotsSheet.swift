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
    }

    private var header: some View {
        HStack {
            Text("Snapshots").font(.headline)
            Spacer()
            Button {
                model.snapshotNow()
            } label: {
                Label("Snapshot Now", systemImage: "camera")
            }
            .disabled(model.snapshotManager == nil)
            Button("Done") { model.showSnapshots = false }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
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
            List(snapshots, id: \.url) { snapshot in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                        Text(Self.label(for: snapshot.reason))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { confirming = snapshot }
                }
                .padding(.vertical, 2)
            }
        }
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
