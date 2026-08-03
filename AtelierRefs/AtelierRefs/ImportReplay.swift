//
//  ImportReplay.swift
//  AtelierRefs
//
//  008 · H7 — the replay layer: `[ImportPlan]` walked through the SHIPPED public
//  writers, and nothing else.
//
//  There is no private back door here on purpose. Every row this type creates is
//  created by `createCollection`, `ingest`, `ingestContent`, `addAssets`,
//  `applyTag`, `setFavorite`, `setName`, `setNote`, `setGridOrder` or
//  `setCanvasPlacement` —
//  the same funnel the app itself writes through. The consequence is the point:
//  an importer cannot produce a library state the app could not have produced,
//  so validation, the Unsorted invariant, membership uniqueness and 18A's
//  content-hash dedup are not re-implemented, re-tested or re-broken here.
//
//  Four rules the file exists to keep:
//
//  1. **A new root collection is the destination.** Never a merge into existing
//     folders. `createCollection` disambiguates a duplicate sibling name
//     Finder-style, so importing the same archive twice yields "Archive" and
//     "Archive 2" — two separate containers rather than one silently clobbered.
//  2. **One asset, N memberships.** An `ImportItem.key` seen again is added with
//     `addAssets`, never re-ingested. Even so, two DIFFERENT keys can resolve to
//     one asset when 18A dedup matches, which is why the grid order is
//     deduplicated before `setGridOrder` sees it.
//  3. **Additive on a deduplicated asset, never destructive.** Tags — and the
//     favorite star (011 · U5) — are applied whichever way an asset resolved:
//     both are new information and both writers are idempotent, and neither can
//     erase anything (an archive's `is_favorite: false` is not replayed at all).
//     `name` and `note` are applied only to a NEWLY created asset: overwriting
//     them on a dedup hit would silently discard an edit the user made in THIS
//     library, which is the clobber the destination rule exists to prevent.
//  4. **The cancel flag is asked before any error is classified** (008 ·
//     H5b/H5c/H6, the fourth job to inherit it). Cancelling tears down in-flight
//     work, and those throws are a consequence of the user pressing Stop.
//

import AtelierCore
import AtelierIngestion
import Foundation

nonisolated struct LibraryImporter: Sendable {

    let services: AppServices
    let store: MediaStore

    init(services: AppServices, store: MediaStore) {
        self.services = services
        self.store = store
    }

    // MARK: - The run

    /// Create a root collection named `destinationName` and replay `plans` under
    /// it, returning what actually happened.
    ///
    /// Throws only `CancellationError`. An individual collection or membership
    /// that fails is RECORDED and the run continues: a half-imported archive the
    /// user can see the shape of beats an all-or-nothing abort on one bad row,
    /// and the report names every casualty (004's batch-outcome lesson).
    func replay(
        _ plans: [ImportPlan],
        into destinationName: String,
        isCancelled: @Sendable () -> Bool = { false },
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ImportReport {
        var report = ImportReport()
        try check(isCancelled)

        let destination = try await services.createCollection(name: destinationName)
        report.destinationID = destination.id
        report.destinationName = destination.name

        // Source key → the collection / asset it became in THIS library.
        var collectionIDs: [String: UUID] = [:]
        var assetIDs: [String: UUID] = [:]
        var newAssetIDs: Set<UUID> = []
        // Keys whose collection could not be created; their children are failed
        // too rather than quietly re-homed at the top of the import.
        var failedKeys: Set<String> = []

        let ordered = Self.parentsFirst(plans)
        for (index, plan) in ordered.enumerated() {
            try check(isCancelled)

            if let parentKey = plan.parentKey, failedKeys.contains(parentKey) {
                failedKeys.insert(plan.key)
                report.failed.append(ImportFailure(
                    collection: plan.name,
                    message: "its parent folder couldn’t be created"))
                continue
            }

            // The real nesting, from the KEY. A plan whose parent isn't among
            // the plans lands directly under the destination.
            let parentID = plan.parentKey.flatMap { collectionIDs[$0] } ?? destination.id
            let collection: Collection
            do {
                collection = try await services.createCollection(
                    name: plan.name, description: plan.description, parent: parentID)
            } catch {
                if isCancelled() { throw CancellationError() }
                failedKeys.insert(plan.key)
                report.failed.append(ImportFailure(
                    collection: plan.name, message: Self.message(for: error)))
                continue
            }
            collectionIDs[plan.key] = collection.id
            report.collections += 1

            // The manual order, as resolved asset ids. Deduplicated because two
            // source keys can land on one asset: `setGridOrder` would otherwise
            // assign that asset two positions and keep the last.
            var orderedAssetIDs: [UUID] = []
            var placed: Set<UUID> = []

            for item in plan.items {
                try check(isCancelled)
                do {
                    let resolved = try await materialize(
                        item, in: collection.id, existing: assetIDs[item.key])
                    assetIDs[item.key] = resolved.id
                    if resolved.isNew { newAssetIDs.insert(resolved.id) }
                    report.memberships += 1
                    if placed.insert(resolved.id).inserted {
                        orderedAssetIDs.append(resolved.id)
                    }
                    try await decorate(item, asset: resolved, in: collection.id)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isCancelled() { throw CancellationError() }
                    report.failed.append(ImportFailure(
                        collection: plan.name, item: item.key,
                        message: Self.message(for: error)))
                }
            }

            if !orderedAssetIDs.isEmpty {
                do {
                    try await services.setGridOrder(
                        collectionID: collection.id, orderedAssetIDs: orderedAssetIDs)
                } catch {
                    if isCancelled() { throw CancellationError() }
                    report.failed.append(ImportFailure(
                        collection: plan.name, message: Self.message(for: error)))
                }
            }

            onProgress(Double(index + 1) / Double(max(ordered.count, 1)))
        }

        report.assets = Set(assetIDs.values).count
        report.newAssets = newAssetIDs.count
        onProgress(1)
        return report
    }

    // MARK: - One membership

    /// The asset a membership resolved to, and whether this call created it.
    private struct Resolved {
        var id: UUID
        var isNew: Bool
    }

    /// Put `item`'s asset in `collectionID`, creating it the first time its key
    /// is seen and adding a membership every time after.
    private func materialize(
        _ item: ImportItem, in collectionID: UUID, existing: UUID?
    ) async throws -> Resolved {
        // Second and later mentions of one source asset: a MEMBERSHIP, not an
        // ingest. Re-ingesting would depend on dedup to collapse it, and dedup
        // is a property of the provenance the source shipped — not something a
        // replay should lean on when it already knows the answer.
        if let existing {
            try await services.addAssets([existing], to: collectionID)
            return Resolved(id: existing, isNew: false)
        }

        switch item.body {
        case let .media(kind, bytes, downloadState):
            let stored = try storeBytes(bytes)
            let draft = AssetDraft(
                kind: kind, blobHash: stored.hash, mimeType: bytes.mimeType,
                width: bytes.width, height: bytes.height, duration: bytes.duration,
                fileSize: stored.size, downloadState: downloadState)
            let result = try await services.ingest(
                draft, from: item.source, into: collectionID)
            return Resolved(id: result.asset.id, isNew: !result.wasDeduplicated)

        case let .content(draft, card):
            var facts: ContentBlobFacts?
            if let card {
                let stored = try storeBytes(card)
                facts = ContentBlobFacts(
                    blobHash: stored.hash, mimeType: card.mimeType,
                    width: card.width, height: card.height, fileSize: stored.size)
            }
            let result = try await services.ingestContent(
                draft, blob: facts, from: item.source, into: collectionID)
            return Resolved(id: result.asset.id, isNew: !result.wasDeduplicated)
        }
    }

    /// Everything about an item that isn't the asset row itself: tags, the
    /// per-membership canvas placement, and — for a newly created asset only —
    /// its name and note (see the file header, rule 3).
    private func decorate(
        _ item: ImportItem, asset: Resolved, in collectionID: UUID
    ) async throws {
        for tag in item.tags {
            _ = try await services.applyTag(tag.name, to: asset.id, source: tag.source)
        }
        // The star rides with the TAGS, not with name/note (rule 3): favoriting is
        // additive and idempotent, so applying it to a deduplicated asset can only
        // add information. `false` is never replayed — see `ImportItem.isFavorite`.
        if item.isFavorite {
            try await services.setFavorite(true, for: asset.id)
        }
        if asset.isNew {
            if let name = item.name { try await services.setName(name, for: asset.id) }
            if let note = item.note { try await services.setNote(note, for: asset.id) }
        }
        if let placement = item.placement, placement != CanvasPlacement() {
            try await services.setCanvasPlacement(
                collectionID: collectionID, assetID: asset.id,
                x: placement.x, y: placement.y,
                w: placement.w, h: placement.h, z: placement.z)
        }
    }

    // MARK: - Bytes

    /// Store a file's bytes in the content-addressed blob store, returning the
    /// hash they actually have and the size they actually are.
    ///
    /// The hash is COMPUTED, never taken from the source (see ``ImportBytes``).
    /// `storeBlobFile` streams file-to-file and is idempotent by existence, so
    /// importing an archive whose blobs this library already holds copies
    /// nothing.
    private func storeBytes(_ bytes: ImportBytes) throws -> (hash: String, size: Int) {
        let hash = try ContentHasher.hash(contentsOf: bytes.url)
        let fileExtension = ImageMetadata.fileExtension(forMIMEType: bytes.mimeType)
        try store.storeBlobFile(
            copyingFrom: bytes.url, hash: hash, fileExtension: fileExtension)
        let size = (try? bytes.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return (hash, size)
    }

    // MARK: - Ordering

    /// `plans` reordered so a parent always precedes its children, depth-first.
    ///
    /// A plan whose `parentKey` is absent from `plans` is a root: an importer
    /// must not be able to strand a collection by naming a parent it didn't
    /// ship. Anything still unreached afterwards is appended rather than
    /// dropped — a cycle cannot come out of this app, but a manifest is a FILE,
    /// and losing a folder silently is worse than nesting it shallowly.
    static func parentsFirst(_ plans: [ImportPlan]) -> [ImportPlan] {
        let known = Set(plans.map(\.key))
        var childrenOf: [String: [ImportPlan]] = [:]
        var roots: [ImportPlan] = []
        for plan in plans {
            if let parentKey = plan.parentKey, parentKey != plan.key, known.contains(parentKey) {
                childrenOf[parentKey, default: []].append(plan)
            } else {
                roots.append(plan)
            }
        }

        var out: [ImportPlan] = []
        var seen: Set<String> = []
        var stack = roots
        while !stack.isEmpty {
            let plan = stack.removeFirst()
            guard seen.insert(plan.key).inserted else { continue }
            out.append(plan)
            stack.insert(contentsOf: childrenOf[plan.key] ?? [], at: 0)
        }
        out.append(contentsOf: plans.filter { !seen.contains($0.key) })
        return out
    }

    // MARK: - Helpers

    /// A writer's error in one short line, for the report and the log. Not user
    /// prose — the user-facing sentence is the summary's count of failures.
    static func message(for error: any Error) -> String {
        if let error = error as? AtelierError { return String(describing: error) }
        return (error as NSError).localizedDescription
    }

    private func check(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
