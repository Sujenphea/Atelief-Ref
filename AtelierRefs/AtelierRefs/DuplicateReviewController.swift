//
//  DuplicateReviewController.swift
//  AtelierRefs
//
//  012 · I5 — the app-side orchestrator for near-duplicate REVIEW. It reads the
//  library's perceptual signatures, groups them with the pure clusterer, and
//  hydrates just the assets that landed in a group so the user can look at both
//  and decide. That is the whole job.
//
//  What it deliberately is NOT, and each of these is a decision rather than an
//  omission:
//
//   • **It never merges and never deletes on its own.** Nothing here acts. The
//     only mutation is the user pressing Delete on ONE member of ONE cluster, and
//     even that is not performed here — it is handed to
//     ``IngestionModel/deleteReviewedDuplicates(assetIDs:)``, which is the very
//     same recoverable-delete path the grid uses, so the safety snapshot, the
//     undo registration and the deferred blob reap all come along unchanged.
//     There is no second delete in this feature.
//
//   • **It remembers nothing between scans.** Dismissing (closing the sheet) does
//     not suppress a cluster; the next scan proposes it again. Suppression memory
//     is real scope — a table, a migration, and a rule for what happens when the
//     analyzer version bumps — and it is not in this change. A group the user
//     chose to keep re-appearing is a mild annoyance; a group silently hidden by
//     state the user can't see would be worse.
//
//   • **It never widens a cluster.** Two review groups that share a member stay
//     two groups (see ``NearDuplicateClustering``'s transitivity note). Merging
//     them is exactly the chaining the clusterer refuses.
//
//  Shaped after ``LibraryStatsController`` (016 · A): the work runs off the main
//  actor, the state is `@MainActor`, and the controller owns nothing but that
//  state — every service it calls is already tested where it lives.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import os

/// One reviewable group: the pure cluster plus the assets it names, hydrated for
/// display. The two travel together so shrinking a group can go on using the pure,
/// tested rule rather than a second copy of it here.
struct DuplicateReviewCluster: Identifiable, Equatable {
    /// The grouping as the clusterer produced it (signatures and distances).
    let group: NearDuplicateCluster
    /// The grouped assets, in the group's order — oldest first, so the first row is
    /// the copy the user has had longest.
    let members: [AssetDetail]

    /// The member ids, which is also the group's identity: an asset can legitimately
    /// appear in two clusters, so no single member's id would do.
    var id: [UUID] { group.memberIDs }
    /// The widest Hamming distance inside the group; 0 = identical signatures.
    var widestDistance: Int { group.widestDistance }
}

@MainActor
final class DuplicateReviewController: ObservableObject {

    /// The review groups, as last scanned. Empty until ``scan(services:)`` runs.
    @Published private(set) var clusters: [DuplicateReviewCluster] = []
    /// Whether a scan is in flight — gates the Rescan button.
    @Published private(set) var isScanning = false
    /// When the last successful scan finished; `nil` before the first one.
    @Published private(set) var scannedAt: Date?
    /// How many analyzed images the last scan considered — the honest denominator
    /// behind "no duplicates found" (an un-analyzed library finds nothing because
    /// there is nothing to compare, not because it is clean).
    @Published private(set) var comparedCount = 0
    /// Why the last scan failed, in words; `nil` when all is well.
    @Published private(set) var lastError: String?

    /// The Hamming cutoff in force. Held here rather than read at each call site so
    /// the sheet can state the number it is actually using.
    let distance = NearDuplicateClustering.defaultDistance

    /// Rescan from scratch: read every live signature, group them, hydrate the
    /// grouped assets.
    ///
    /// Authoritative, never incremental. The library changes underneath this
    /// surface — a delete, a ⌘Z restore, a capture landing from the browser — and
    /// re-reading is both simpler and safer than patching a cached graph; a stale
    /// cluster here would offer a delete on an asset that is already gone.
    ///
    /// A restored (undone) delete brings the ASSET back but not its analysis row:
    /// that is derived data, it cascaded away with the delete, and the recoverable
    /// backup deliberately doesn't carry it. So a just-restored copy is absent from
    /// this list until the idle backfill re-hashes it. Staying quiet about an image
    /// whose signature we no longer hold is the right way round — the alternative is
    /// proposing a delete on grouping we can't currently justify.
    func scan(services: AppServices) async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        defer { isScanning = false }

        do {
            let inventory = try await services.perceptualHashes()
            let hashes = inventory.map {
                // The signed↔unsigned reinterpretation, at the imaging seam where
                // it belongs (Core stores bits, not numbers).
                HashedAsset(id: $0.assetID, hash: UInt64(bitPattern: $0.phash))
            }
            // Grouping is pure CPU over the whole library — off the main actor.
            let groups = await Task.detached(priority: .userInitiated) {
                NearDuplicateClustering.clusters(of: hashes)
            }.value

            let details = try await hydrate(groups, services: services)
            // Anything that vanished between the inventory read and now drops out,
            // and any group left with fewer than two members stops existing.
            let live = NearDuplicateClustering.retaining(groups, liveIDs: Set(details.keys))
            clusters = live.compactMap { group in
                let members = group.memberIDs.compactMap { details[$0] }
                guard members.count == group.members.count else { return nil }
                return DuplicateReviewCluster(group: group, members: members)
            }
            comparedCount = hashes.count
            scannedAt = Date()
        } catch {
            lastError = "Couldn't scan for duplicates: \(error.localizedDescription)"
            AppLog.model.error(
                "duplicate scan failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drop `assetID` from every cluster it appears in, discarding any group left
    /// with fewer than two members.
    ///
    /// Called the instant a delete is handed off, so the row the user just acted on
    /// stops offering that copy immediately rather than after the write lands. The
    /// shrink rule is the pure one — a cluster of one has nothing to compare and
    /// would be proposing its LAST remaining copy for deletion, so it is removed
    /// rather than shown with a disabled button.
    func forget(assetID: UUID) {
        clusters = clusters.compactMap { cluster in
            guard cluster.id.contains(assetID) else { return cluster }
            // The shrink rule itself is the pure one, so the surface and the tests
            // agree by construction rather than by resemblance.
            guard let shrunk = NearDuplicateClustering
                .reconciled([cluster.group], removing: [assetID]).first
            else { return nil }
            return DuplicateReviewCluster(
                group: shrunk, members: cluster.members.filter { $0.asset.id != assetID })
        }
    }

    /// Forget the last scan — called when the library closes, so the sheet can't
    /// show groups from a library that is no longer open.
    func reset() {
        clusters = []
        scannedAt = nil
        comparedCount = 0
        lastError = nil
    }

    /// Fetch each clustered asset. A member that no longer exists is simply absent
    /// from the result — `getAsset` throws `.notFound` for an asset deleted under
    /// us, and that is the answer, not an error. Only clustered assets are fetched,
    /// so this is a handful of reads even on a large library.
    private func hydrate(
        _ groups: [NearDuplicateCluster], services: AppServices
    ) async throws -> [UUID: AssetDetail] {
        var details: [UUID: AssetDetail] = [:]
        for id in Set(groups.flatMap(\.memberIDs)) {
            guard let detail = try? await services.getAsset(id: id) else { continue }
            details[id] = detail
        }
        return details
    }
}
