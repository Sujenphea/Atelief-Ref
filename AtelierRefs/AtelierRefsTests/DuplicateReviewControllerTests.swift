//
//  DuplicateReviewControllerTests.swift
//  AtelierRefsTests
//
//  012 · I5 — the near-duplicate review surface, driven against a real (temp)
//  library. The grouping maths is already pinned in AtelierIngestion
//  (`NearDuplicateClusteringTests`) and the inventory query in AtelierCore
//  (`ServicesDuplicateHashesTests`), so what is left is the part only the app has,
//  and it is the part that can hurt someone:
//
//   · a delete from a cluster is an ORDINARY delete — same recoverable path, so
//     ⌘Z brings the copy back and ⇧⌘Z takes it away again;
//   · a cluster shrunk to its last copy stops existing rather than offering it;
//   · an asset deleted underneath the surface is never proposed again.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Duplicate review (012 · I5)")
struct DuplicateReviewControllerTests {

    private struct Rig {
        let model: IngestionModel
        let services: AppServices
        let review: DuplicateReviewController
        let collection: UUID
    }

    private func makeRig() async throws -> Rig {
        let dbPath = NSTemporaryDirectory() + "dup-review-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        let collection = try await services.createCollection(name: "Refs")
        return Rig(
            model: model, services: services,
            review: DuplicateReviewController(), collection: collection.id)
    }

    /// A distinct, VALID 64-hex content hash per seed — the ingest validator rejects
    /// anything else, which a mnemonic marker trips on its first non-hex letter.
    private func blobHash(_ index: Int) -> String {
        String(format: "%064x", index &+ 1)
    }

    /// Ingest one downloaded image and stamp it with a known perceptual signature.
    /// The signature is the whole point of the fixture, so it is written directly
    /// rather than produced by hashing a synthesised picture — this suite is about
    /// what the surface does with signatures, not about dHash.
    @discardableResult
    private func seed(_ rig: Rig, _ index: Int, hash: UInt64) async throws -> UUID {
        // `created_at` has millisecond resolution and the inventory is ordered by
        // it, so seeds are spaced far enough apart that "oldest first" is a real
        // assertion rather than a uuid tie-break.
        try await Task.sleep(for: .milliseconds(2))
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.test/\(index)",
            authorHandle: nil, authorName: nil, title: "Ref \(index)", capturedAt: Date())
        let draft = AssetDraft(
            kind: .image, blobHash: blobHash(index), mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 1024,
            downloadState: .downloaded)
        let asset = try await rig.services.ingest(draft, from: source, into: rig.collection).asset
        try await rig.services.upsertAnalysis(
            assetID: asset.id, phash: Int64(bitPattern: hash), analyzerVersion: 1)
        return asset.id
    }

    /// A non-degenerate base signature (0 and `UInt64.max` are excluded by design).
    private static let base: UInt64 = 0xA5A5_5A5A_0F0F_F0F0

    /// `base` with `count` low bits flipped — a copy `count` bits away.
    private static func near(_ count: Int) -> UInt64 {
        var hash = base
        for bit in 0 ..< count { hash ^= (1 as UInt64) << UInt64(bit) }
        return hash
    }

    private func exists(_ rig: Rig, _ id: UUID) async -> Bool {
        (try? await rig.services.getAsset(id: id)) != nil
    }

    // MARK: - Scanning

    @Test("an empty library proposes nothing")
    func emptyLibrary() async throws {
        let rig = try await makeRig()
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.isEmpty)
        #expect(rig.review.comparedCount == 0)
        #expect(rig.review.lastError == nil)
        #expect(rig.review.scannedAt != nil)
    }

    @Test("a library of unrelated images proposes nothing")
    func noDuplicates() async throws {
        let rig = try await makeRig()
        for step in 0 ..< 3 {
            var hash = Self.base
            for bit in (step * 16) ..< (step * 16 + 16) { hash ^= (1 as UInt64) << UInt64(bit) }
            try await seed(rig, 30 + step, hash: hash)
        }
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.isEmpty)
        // It compared them — "no duplicates" here means clean, not un-analysed.
        #expect(rig.review.comparedCount == 3)
    }

    @Test("near copies are grouped, and the far one is left alone")
    func groupsNearCopies() async throws {
        let rig = try await makeRig()
        let original = try await seed(rig, 0, hash: Self.base)
        let copy = try await seed(rig, 1, hash: Self.near(2))
        var far = Self.base
        for bit in 20 ..< 40 { far ^= (1 as UInt64) << UInt64(bit) }
        let unrelated = try await seed(rig, 2, hash: far)

        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.count == 1)
        #expect(rig.review.clusters.first?.id == [original, copy])
        #expect(rig.review.clusters.first?.widestDistance == 2)
        #expect(rig.review.clusters.first?.members.map(\.asset.id) == [original, copy])
        #expect(!(rig.review.clusters.first?.id.contains(unrelated) ?? true))
    }

    @Test("an un-analysed library has nothing to compare, and says so")
    func unanalysedLibrary() async throws {
        let rig = try await makeRig()
        // Two identical images, neither analysed — no signatures, no proposals.
        let source = SourceDraft(
            platform: .web, originalURL: "https://example.test/u", authorHandle: nil,
            authorName: nil, title: nil, capturedAt: Date())
        for index in 90 ... 91 {
            let draft = AssetDraft(
                kind: .image, blobHash: blobHash(index), mimeType: "image/png",
                width: 10, height: 10, duration: nil, fileSize: 10,
                downloadState: .downloaded)
            _ = try await rig.services.ingest(draft, from: source, into: rig.collection)
        }
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.isEmpty)
        #expect(rig.review.comparedCount == 0)
    }

    // MARK: - Deleting a copy is an ordinary delete

    @Test("deleting a copy goes through the recoverable path — ⌘Z brings it back")
    func deleteIsUndoable() async throws {
        let rig = try await makeRig()
        let keep = try await seed(rig, 5, hash: Self.base)
        let drop = try await seed(rig, 3, hash: Self.near(1))
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.count == 1)

        rig.model.deleteReviewedDuplicates(assetIDs: [drop])
        await rig.model.waitForWrites()
        var droppedExists = await exists(rig, drop)
        let keptExists = await exists(rig, keep)
        #expect(!droppedExists)
        #expect(keptExists)
        // Registered on the SAME undo stack, under the same verb, as a grid delete.
        #expect(rig.model.canUndo)
        #expect(rig.model.undoActionName == "Delete")

        rig.model.undo()
        await rig.model.waitForWrites()
        droppedExists = await exists(rig, drop)
        #expect(droppedExists)

        rig.model.redo()
        await rig.model.waitForWrites()
        droppedExists = await exists(rig, drop)
        #expect(!droppedExists)
    }

    /// An undone delete restores the ASSET; its analysis row is derived data and is
    /// not in the backup (it cascaded away with the delete), so the restored copy is
    /// silent here until the background backfill re-hashes it. That is the honest
    /// behaviour and worth pinning: the surface stays QUIET about an image it has no
    /// current signature for, rather than proposing it on stale grouping.
    @Test("an undone delete restores the copy; it rejoins the group once re-analysed")
    func undoRestoresTheCluster() async throws {
        let rig = try await makeRig()
        let keep = try await seed(rig, 12, hash: Self.base)
        let drop = try await seed(rig, 13, hash: Self.near(1))
        await rig.review.scan(services: rig.services)

        rig.model.deleteReviewedDuplicates(assetIDs: [drop])
        await rig.model.waitForWrites()
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.isEmpty)

        rig.model.undo()
        await rig.model.waitForWrites()
        let restored = await exists(rig, drop)
        #expect(restored)
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.isEmpty)
        #expect(rig.review.comparedCount == 1)

        // What the idle analysis backfill does on its next pass.
        try await rig.services.upsertAnalysis(
            assetID: drop, phash: Int64(bitPattern: Self.near(1)), analyzerVersion: 1)
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.map(\.id) == [[keep, drop]])
    }

    @Test("deleting nothing does nothing")
    func emptyDeleteIsANoOp() async throws {
        let rig = try await makeRig()
        try await seed(rig, 4, hash: Self.base)
        rig.model.deleteReviewedDuplicates(assetIDs: [])
        await rig.model.waitForWrites()
        #expect(!rig.model.canUndo)
    }

    // MARK: - A shrinking cluster

    @Test("forgetting a copy leaves the rest of a three-copy group reviewable")
    func forgetShrinksGroup() async throws {
        let rig = try await makeRig()
        let a = try await seed(rig, 14, hash: Self.base)
        let b = try await seed(rig, 15, hash: Self.near(1))
        let c = try await seed(rig, 16, hash: Self.near(2))
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.map(\.id) == [[a, b, c]])

        rig.review.forget(assetID: b)
        #expect(rig.review.clusters.map(\.id) == [[a, c]])
        #expect(rig.review.clusters.first?.members.map(\.asset.id) == [a, c])
    }

    @Test("a group down to its last copy stops existing — that copy is never offered")
    func lastCopyIsNeverOffered() async throws {
        let rig = try await makeRig()
        let a = try await seed(rig, 6, hash: Self.base)
        let b = try await seed(rig, 7, hash: Self.near(1))
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.count == 1)

        rig.review.forget(assetID: b)
        // Not "a group of one with a disabled button" — no group at all.
        #expect(rig.review.clusters.isEmpty)
        // And the survivor is still in the library: shrinking a group deletes nothing.
        let survivorExists = await exists(rig, a)
        #expect(survivorExists)
    }

    // MARK: - Never propose an action on something that isn't there

    @Test("an asset deleted underneath the surface is dropped from its group")
    func vanishedMemberDropped() async throws {
        let rig = try await makeRig()
        let a = try await seed(rig, 17, hash: Self.base)
        let b = try await seed(rig, 18, hash: Self.near(1))
        let c = try await seed(rig, 19, hash: Self.near(2))
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.map(\.id) == [[a, b, c]])

        // Gone by another route entirely — a grid delete in the window behind this
        // sheet, or a restore. The surface must not keep offering it.
        _ = try await rig.services.deleteAssets([b])
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.map(\.id) == [[a, c]])
        #expect(rig.review.clusters.allSatisfy { !$0.id.contains(b) })
    }

    @Test("a group whose members all vanished disappears entirely")
    func vanishedGroupDisappears() async throws {
        let rig = try await makeRig()
        let a = try await seed(rig, 20, hash: Self.base)
        let b = try await seed(rig, 21, hash: Self.near(1))
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.count == 1)

        _ = try await rig.services.deleteAssets([a, b])
        await rig.review.scan(services: rig.services)
        #expect(rig.review.clusters.isEmpty)
        #expect(rig.review.comparedCount == 0)
    }

    @Test("every proposed member still exists at the moment it is proposed")
    func proposedMembersAreLive() async throws {
        let rig = try await makeRig()
        try await seed(rig, 9, hash: Self.base)
        try await seed(rig, 10, hash: Self.near(1))
        try await seed(rig, 11, hash: Self.near(3))
        await rig.review.scan(services: rig.services)

        for cluster in rig.review.clusters {
            for id in cluster.id {
                let live = await exists(rig, id)
                #expect(live)
            }
            // The hydrated members and the grouping never disagree about who is in.
            #expect(cluster.members.map(\.asset.id) == cluster.id)
        }
    }

    // MARK: - Housekeeping

    @Test("resetting forgets the scan, so a closed library can't be reviewed")
    func resetClearsState() async throws {
        let rig = try await makeRig()
        try await seed(rig, 22, hash: Self.base)
        try await seed(rig, 23, hash: Self.base)
        await rig.review.scan(services: rig.services)
        #expect(!rig.review.clusters.isEmpty)

        rig.review.reset()
        #expect(rig.review.clusters.isEmpty)
        #expect(rig.review.scannedAt == nil)
        #expect(rig.review.comparedCount == 0)
    }

    @Test("the surface states the threshold it actually used")
    func thresholdIsPublished() {
        #expect(DuplicateReviewController().distance == NearDuplicateClustering.defaultDistance)
        #expect(NearDuplicateClustering.defaultDistance == 5)
    }
}
