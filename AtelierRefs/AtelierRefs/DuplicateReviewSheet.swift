//
//  DuplicateReviewSheet.swift
//  AtelierRefs
//
//  012 · I5 — the "Duplicates" review surface. One row per near-identical group:
//  the copies side by side, each with the facts you actually choose between (size
//  on disk, pixel dimensions, when it was captured, where it came from), and a
//  single action per copy — delete THIS one.
//
//  The screen is built around one promise, and the copy on it says so out loud:
//  **nothing here happens on its own.** It merges nothing, it pre-selects nothing,
//  it ticks no "keep the biggest" box for you. Every removal is a deliberate click
//  on a specific image, confirmed, and it goes through the same recoverable delete
//  as the grid — so ⌘Z brings it back, the files go to the Trash rather than
//  vanishing, and a pre-destructive snapshot is taken first.
//
//  Two UI rules follow directly from the clustering's semantics:
//
//   • **A group of one is never shown.** When a group shrinks to a single copy it
//     disappears from the list rather than lingering with a disabled button —
//     there is nothing left to compare, and the one thing this surface must never
//     do is invite the user to delete the last remaining copy of something.
//   • **The same image can appear in two groups**, because A~B and B~C does not
//     make A and C copies (see ``NearDuplicateClustering``). Both groups are shown
//     honestly rather than merged into a claim the hashes don't support.
//

import AtelierCore
import AtelierIngestion
import SwiftUI

struct DuplicateReviewSheet: View {
    @ObservedObject var model: IngestionModel
    /// Observed separately from `model` for the reason `BackupController` documents:
    /// a nested `ObservableObject` doesn't propagate through its owner, so scan
    /// progress would never reach this view.
    @StateObject private var review = DuplicateReviewController()

    /// The copy awaiting delete confirmation. The shell's shared delete dialog is
    /// attached to the main window and would open BEHIND this sheet, so the
    /// confirmation lives here — the delete itself still goes through the model's
    /// one recoverable path.
    @State private var confirming: PendingRemoval?

    /// A specific copy inside a specific group. The asset id alone wouldn't do:
    /// one asset can appear in two groups, and the dialog names the group it was
    /// pressed in.
    private struct PendingRemoval: Identifiable, Equatable {
        let clusterID: [UUID]
        let detail: AssetDetail
        var id: [UUID] { clusterID + [detail.asset.id] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 460)
        .task { await rescan() }
        // A ⌘Z restore (or a redo) puts assets back that this list has already
        // forgotten. Re-read rather than try to patch: the library is the truth.
        .onChange(of: model.undoToken) { _, _ in Task { await rescan() } }
        .confirmationDialog(
            "Delete this copy?",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { pending in
            // Return commits, as in every confirmation dialog here — a
            // `role: .destructive` button is left unbound otherwise (see
            // ``ContentView``'s delete dialog for the mechanism). It matters more on
            // this screen than anywhere else: reviewing duplicates is a long run of
            // identical confirmations, and reaching for the mouse on each one is the
            // whole cost of the sweep.
            Button("Delete", role: .destructive) { remove(pending) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { _ in
            Text("This copy moves to the Trash and is removed from every collection. "
                + "The other copies in this group are untouched. You can undo this "
                + "with ⌘Z, and restore the file from the Trash.")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicates").font(Theme.Typography.pageTitle)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await rescan() }
            } label: {
                if review.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    }
                } else {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.services == nil || review.isScanning)
            Button("Done") { model.showDuplicates = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    /// The honest one-liner under the title: what was compared, and how close two
    /// images have to be before this screen will say anything about them.
    private var subtitle: String {
        guard review.scannedAt != nil else {
            return "Groups of near-identical images. Nothing is ever merged or "
                + "deleted for you."
        }
        let compared = review.comparedCount
        let noun = compared == 1 ? "image" : "images"
        return "\(compared) analysed \(noun) compared, within \(review.distance) "
            + "of 64 signature bits. Nothing is merged or deleted for you."
    }

    @ViewBuilder
    private var content: some View {
        if let error = review.lastError {
            ContentUnavailableView(
                "Couldn't scan", systemImage: "exclamationmark.triangle",
                description: Text(error))
        } else if review.isScanning, review.clusters.isEmpty {
            ProgressView("Comparing images…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if review.clusters.isEmpty {
            ContentUnavailableView(
                emptyTitle, systemImage: "square.on.square.dashed",
                description: Text(emptyMessage))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(review.clusters) { cluster in
                        ClusterRow(
                            cluster: cluster,
                            thumbnailURL: { model.thumbnailURL(forAsset: $0) },
                            onDelete: { detail in
                                confirming = PendingRemoval(
                                    clusterID: cluster.id, detail: detail)
                            })
                    }
                }
                .padding(Theme.Spacing.lg)
            }
        }
    }

    private var emptyTitle: String {
        review.comparedCount == 0 && review.scannedAt != nil
            ? "Nothing to compare yet" : "No near-duplicates found"
    }

    private var emptyMessage: String {
        // The distinction matters: an un-analysed library finds nothing because it
        // has nothing to compare, not because it is clean. Saying "no duplicates"
        // in that case would be a lie the user can't see through.
        review.comparedCount == 0 && review.scannedAt != nil
            ? "Images are compared once they've been analysed in the background. "
                + "Leave the app open for a while and rescan."
            : "None of your images are close enough to each other to be worth a "
                + "second look."
    }

    // MARK: - Actions

    private func rescan() async {
        guard let services = model.services else { return }
        await review.scan(services: services)
    }

    /// Hand the delete to the model's ONE recoverable path, then drop the copy from
    /// the list so the row stops offering it immediately. The list is authoritative
    /// again on the next scan.
    private func remove(_ pending: PendingRemoval) {
        confirming = nil
        model.deleteReviewedDuplicates(assetIDs: [pending.detail.asset.id])
        review.forget(assetID: pending.detail.asset.id)
    }
}

// MARK: - One group

/// One near-duplicate group: a heading that states how close the copies are, then
/// the copies themselves in a horizontal strip.
private struct ClusterRow: View {
    let cluster: DuplicateReviewCluster
    let thumbnailURL: (Asset) -> URL?
    let onDelete: (AssetDetail) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                Text(heading).font(Theme.Typography.bodyEmphasis)
                Text(closeness)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    ForEach(cluster.members, id: \.asset.id) { detail in
                        CopyCard(
                            detail: detail, url: thumbnailURL(detail.asset),
                            onDelete: { onDelete(detail) })
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var heading: String {
        "\(cluster.members.count) copies"
    }

    /// How close the group actually is, in the units the threshold is expressed in
    /// — never a percentage, which would imply a confidence this hash can't give.
    private var closeness: String {
        cluster.widestDistance == 0
            ? "identical signatures"
            : "up to \(cluster.widestDistance) of 64 bits apart"
    }
}

// MARK: - One copy

/// One copy inside a group: the image, the facts you'd choose between, and the
/// single destructive action — for THIS copy, never for the group.
private struct CopyCard: View {
    let detail: AssetDetail
    let url: URL?
    let onDelete: () -> Void

    private static let side: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            AssetContentThumbnail(
                asset: detail.asset, url: url, cornerRadius: Theme.Radius.tile,
                bucket: thumbnailPixelBucket(pointLongSide: Self.side, scale: 2))
                .frame(width: Self.side, height: Self.side)

            Text(title)
                .font(Theme.Typography.label)
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Delete This Copy", role: .destructive, action: onDelete)
                .controlSize(.small)
        }
        .frame(width: Self.side)
    }

    private var title: String {
        detail.asset.name ?? detail.source.title ?? "Untitled"
    }

    /// Dimensions, size on disk, and capture date — the three things that actually
    /// distinguish two copies of the same picture. Absent facts are omitted rather
    /// than shown as a dash.
    private var facts: [String] {
        var lines: [String] = []
        if let width = detail.asset.width, let height = detail.asset.height {
            lines.append("\(width) × \(height)")
        }
        if let bytes = detail.asset.fileSize {
            lines.append(LibraryStatsCopy.size(Int64(bytes)))
        }
        lines.append(detail.asset.createdAt.formatted(date: .abbreviated, time: .omitted))
        return lines
    }
}
