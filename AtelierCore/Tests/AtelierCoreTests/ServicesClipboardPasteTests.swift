// AtelierCore — the service half of in-app ⌘C/⌘V (019 · clipboard fidelity)
//
// Pasting the app's own copy routes to `addAssets` (via
// `IngestionModel.copyToCollection`) instead of re-ingesting the blob, so the
// asset ROW survives the round trip. These tests pin what that buys, at the only
// level where it is observable: a second MEMBERSHIP of the SAME asset, with its
// note, tags, source and `created_at` untouched.
//
// The regression this file exists for is `webAssetKeepsItsIdentity`: before 019,
// ⌘C→⌘V put only blob file URLs on the pasteboard, so the paste re-imported them
// as a `.localDrag` capture with no `original_url` — which `findDuplicate` cannot
// match against a `.web` source, minting a NEW asset and losing everything the
// user had written on the old one. The test asserts both halves: the re-ingest
// really does fork the asset, and `addAssets` really does not.
//
// House style mirrors `ServicesMoveTests`: temp DB fixture, hex-encoded tags for
// dedup-proof blob hashes, everything through the public surface.

import Foundation
import Testing
@testable import AtelierCore

/// A valid (lowercase-hex, C8) blob hash derived deterministically from a
/// readable tag, so fixtures stay dedup-proof AND assertable by name.
private func hexHash(_ tag: String) -> String {
    tag.utf8.map { String(format: "%02x", $0) }.joined()
}

@Suite("Services: in-app paste keeps the asset (019)")
struct ServicesClipboardPasteTests {

    // MARK: Fixtures

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    /// A remotely-captured asset: `.web` provenance WITH an `original_url`, the
    /// exact shape whose dedup misses on a byte re-import.
    private func seedWebAsset(
        _ services: AppServices, into collectionID: UUID, tag: String
    ) async throws -> Asset {
        try await services.ingest(
            assetDraft(hash: hexHash(tag)),
            from: SourceDraft(
                platform: .web, originalURL: "https://example.com/\(tag)",
                authorHandle: "@photographer", title: "Sunset over \(tag)",
                capturedAt: Date(timeIntervalSince1970: 1_000_000)),
            into: collectionID).asset
    }

    private func memberAssetIDs(
        _ services: AppServices, of collectionID: UUID
    ) async throws -> [UUID] {
        try await services.collectionItems(in: collectionID, includeArchived: false).map { $0.asset.id }
    }

    // MARK: - The regression (019): a .web asset survives a cross-collection paste

    @Test("pasting a .web asset into another collection leaves its id unchanged")
    func webAssetKeepsItsIdentity() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let original = try await seedWebAsset(services, into: src.id, tag: "kept")

        // The user's own work on the asset — precisely what the old paste lost.
        try await services.setNote("the one with the pier", for: original.id)
        try await services.applyTag("dusk", to: original.id, source: .user)
        // The stored row, read back BEFORE the paste — `created_at` is compared
        // against this rather than the in-memory draft, which carries sub-second
        // precision SQLite's second-resolution timestamps do not.
        let before = try await services.getAsset(id: original.id)

        // ⌘V, post-019: the private payload's ids go straight to `addAssets`.
        try await services.addAssets([original.id], to: dst.id)

        #expect(try await memberAssetIDs(services, of: dst.id) == [original.id])
        let after = try await services.getAsset(id: original.id)
        #expect(after.asset.id == original.id)
        #expect(after.asset.note == "the one with the pier")
        #expect(after.asset.createdAt == before.asset.createdAt)
        #expect(after.source.id == before.source.id)
        #expect(after.source.platform == .web)
        #expect(after.source.originalURL == "https://example.com/kept")
        #expect(after.source.title == "Sunset over kept")
        #expect(try await services.tags(for: original.id).map(\.name) == ["dusk"])
    }

    @Test("the old byte re-import DOES fork the asset — why the payload branch exists")
    func byteReimportForksTheWebAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let original = try await seedWebAsset(services, into: src.id, tag: "forked")
        try await services.setNote("keep me", for: original.id)

        // What ⌘V used to do: the blob's own file URL re-read by the importer, so
        // the incoming provenance is a fresh local capture with NO original_url.
        // `findDuplicate` matches on hash PLUS provenance, so this misses.
        let reimported = try await services.ingest(
            assetDraft(hash: hexHash("forked")),
            from: SourceDraft(platform: .localDrag, originalURL: nil, capturedAt: Date()),
            into: dst.id)

        #expect(reimported.wasDeduplicated == false)
        #expect(reimported.asset.id != original.id)
        #expect(reimported.asset.note == nil)
        // Same bytes, so no disk is wasted — but the row (and the note) is new.
        #expect(reimported.asset.blobHash == original.blobHash)
    }

    // MARK: - Membership arithmetic

    @Test("a cross-collection paste adds exactly ONE membership and keeps the source")
    func addsExactlyOneMembership() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let asset = try await seedWebAsset(services, into: src.id, tag: "once")

        try await services.addAssets([asset.id], to: dst.id)

        // A copy, not a move: the asset is in BOTH, once each.
        #expect(try await memberAssetIDs(services, of: src.id) == [asset.id])
        #expect(try await memberAssetIDs(services, of: dst.id) == [asset.id])
    }

    @Test("pasting into the SAME collection is a no-op (one membership, not two)")
    func samecollectionPasteIsNoop() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let asset = try await seedWebAsset(services, into: src.id, tag: "already")

        try await services.addAssets([asset.id], to: src.id)

        #expect(try await memberAssetIDs(services, of: src.id) == [asset.id])
    }

    @Test("a repeated paste into the same target stays at one membership")
    func repeatedPasteIsIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let asset = try await seedWebAsset(services, into: src.id, tag: "twice")

        try await services.addAssets([asset.id], to: dst.id)
        try await services.addAssets([asset.id], to: dst.id)

        #expect(try await memberAssetIDs(services, of: dst.id) == [asset.id])
    }

    // MARK: - Stale ids fail CLOSED (copy → delete → paste)

    @Test("a deleted id fails the whole paste closed — nothing half-added")
    func staleIDFailsClosed() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let live = try await seedWebAsset(services, into: src.id, tag: "live")
        let doomed = try await seedWebAsset(services, into: src.id, tag: "doomed")

        // ⌘C, then the copied item is deleted, then ⌘V.
        _ = try await services.deleteAssets([doomed.id])

        await #expect(throws: AtelierError.self) {
            try await services.addAssets([live.id, doomed.id], to: dst.id)
        }
        // One transaction: the surviving id is NOT added behind the failure.
        #expect(try await memberAssetIDs(services, of: dst.id) == [])
    }

    // MARK: - Undo (the paste's inverse is the membership drop)

    @Test("removing the pasted membership restores the prior state, asset intact")
    func undoRestores() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let asset = try await seedWebAsset(services, into: src.id, tag: "undone")
        try await services.setNote("still here", for: asset.id)

        try await services.addAssets([asset.id], to: dst.id)
        try await services.removeAssets([asset.id], from: dst.id)

        #expect(try await memberAssetIDs(services, of: dst.id) == [])
        #expect(try await memberAssetIDs(services, of: src.id) == [asset.id])
        // Undoing a paste never touches the asset itself.
        #expect(try await services.getAsset(id: asset.id).asset.note == "still here")
    }
}
