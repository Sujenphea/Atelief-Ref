// AtelierCore — the Unsorted invariant (F3), through the public surface
//
// "Unsorted" is the home for assets that live in NO real folder, not a folder in
// its own right. Two rules make that literally true, and this suite pins both
// against every membership funnel:
//
//   1. Filed ⇒ not unsorted — gaining a real membership drops the Unsorted one.
//   2. Unfiled ⇒ unsorted — losing the last membership re-homes to Unsorted.
//
// Plus the two deliberate exemptions: removing FROM Unsorted (else the grid's
// Remove could never clear it) and verbatim restore (undo must invert exactly).
//
// House style mirrors `ServicesMoveTests`: temp DB fixture, unique (hash, url)
// per ingest so 18A dedup never collapses fixtures.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

/// A valid (lowercase-hex, C8) blob hash derived deterministically from a
/// readable tag, so fixtures stay dedup-proof AND assertable by name.
private func invariantHash(_ tag: String) -> String {
    tag.utf8.map { String(format: "%02x", $0) }.joined()
}

@Suite("Services: Unsorted invariant (F3)")
struct ServicesUnsortedInvariantTests {

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

    private func sourceDraft(url: String) -> SourceDraft {
        SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
    }

    /// Ingest a fresh, dedup-proof asset into `collectionID`; returns its id.
    @discardableResult
    private func seedAsset(
        _ services: AppServices, into collectionID: UUID, tag: String
    ) async throws -> UUID {
        let result = try await services.ingest(
            assetDraft(hash: invariantHash(tag)),
            from: sourceDraft(url: "https://example.com/\(tag)"),
            into: collectionID)
        return result.asset.id
    }

    /// The ids of the collections an asset belongs to.
    private func homes(
        _ services: AppServices, of assetID: UUID
    ) async throws -> Set<UUID> {
        Set(try await services.collections(for: assetID).map(\.id))
    }

    private func memberAssetIDs(
        _ services: AppServices, of collectionID: UUID
    ) async throws -> [UUID] {
        try await services.collectionItems(in: collectionID).map { $0.asset.id }
    }

    private var unsorted: UUID { Collection.unsortedID }

    // MARK: Rule 1 — filed ⇒ not unsorted

    @Test("addAssets into a real folder drops the asset's Unsorted membership")
    func addEvictsUnsorted() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: unsorted, tag: "a")

        try await services.addAssets([asset], to: refs.id)

        #expect(try await homes(services, of: asset) == [refs.id])
        #expect(try await memberAssetIDs(services, of: unsorted).isEmpty)
    }

    /// The eviction is the one thing about an add a caller cannot predict, so the add
    /// reports it (356). A UI watching the Unsorted feed reads this to know its verb was
    /// also a departure; guessing at it means a second copy of rule 1 in every client.
    @Test("addAssets returns the assets it evicted from Unsorted — and only those")
    func addReportsTheEviction() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let moods = try await services.createCollection(name: "Moods")
        let unfiled = try await seedAsset(services, into: unsorted, tag: "e")
        let filed = try await seedAsset(services, into: refs.id, tag: "f")

        // Mixed batch: only the unsorted one has a membership to lose.
        #expect(try await services.addAssets([unfiled, filed], to: moods.id) == [unfiled])
        // Nothing left to evict the second time round.
        #expect(try await services.addAssets([unfiled, filed], to: moods.id).isEmpty)
    }

    /// Into Unsorted there is no eviction to report by construction — rule 1 only fires
    /// on the way IN to a real collection.
    @Test("addAssets into Unsorted reports no eviction")
    func addIntoUnsortedReportsNothing() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id, tag: "g")

        #expect(try await services.addAssets([asset], to: unsorted).isEmpty)
    }

    @Test("a second real folder is additive — multi-membership still works")
    func addToSecondFolderKeepsBoth() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let moods = try await services.createCollection(name: "Moods")
        let asset = try await seedAsset(services, into: unsorted, tag: "b")

        try await services.addAssets([asset], to: refs.id)
        try await services.addAssets([asset], to: moods.id)

        #expect(try await homes(services, of: asset) == [refs.id, moods.id])
    }

    @Test("addAssets into Unsorted is skipped for an already-filed asset")
    func addIntoUnsortedSkipsFiled() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id, tag: "c")

        try await services.addAssets([asset], to: unsorted)

        #expect(try await homes(services, of: asset) == [refs.id])
    }

    @Test("addAssets into Unsorted still files an asset that lives nowhere")
    func addIntoUnsortedAcceptsUnfiled() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id, tag: "d")
        // Leave it homeless the only way that can: remove from Unsorted's exempt
        // sibling path is not it — remove from `refs` re-homes, so drop that row
        // and then the Unsorted one.
        try await services.removeAssets([asset], from: refs.id)
        try await services.removeAssets([asset], from: unsorted)
        #expect(try await homes(services, of: asset).isEmpty)

        try await services.addAssets([asset], to: unsorted)

        #expect(try await homes(services, of: asset) == [unsorted])
    }

    @Test("moveAssets into a real folder drops the Unsorted membership too")
    func moveEvictsUnsorted() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let moods = try await services.createCollection(name: "Moods")
        let asset = try await seedAsset(services, into: unsorted, tag: "e")
        try await services.addAssets([asset], to: refs.id)   // filed, Unsorted gone
        try await services.addAssets([asset], to: unsorted)  // skipped (already filed)

        try await services.moveAssets([asset], from: refs.id, to: moods.id)

        #expect(try await homes(services, of: asset) == [moods.id])
    }

    @Test("moveAssets INTO Unsorted only re-homes an asset with nowhere else")
    func moveIntoUnsortedRespectsOtherHomes() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let moods = try await services.createCollection(name: "Moods")
        // Filed in BOTH folders: moving out of `refs` leaves `moods`, so it is
        // still filed and must NOT gain an Unsorted row.
        let filed = try await seedAsset(services, into: refs.id, tag: "f")
        try await services.addAssets([filed], to: moods.id)
        // Filed only in `refs`: moving to Unsorted is a real un-triage.
        let lone = try await seedAsset(services, into: refs.id, tag: "g")

        try await services.moveAssets([filed, lone], from: refs.id, to: unsorted)

        #expect(try await homes(services, of: filed) == [moods.id])
        #expect(try await homes(services, of: lone) == [unsorted])
    }

    @Test("ingest re-capturing known bytes never lands the asset in two homes")
    func ingestDedupHonorsInvariant() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: unsorted, tag: "h")

        // Re-capture the SAME bytes + provenance into a real folder: 18A dedup
        // resolves to the existing asset, which must leave Unsorted.
        let intoRefs = try await services.ingest(
            assetDraft(hash: invariantHash("h")),
            from: sourceDraft(url: "https://example.com/h"), into: refs.id)
        #expect(intoRefs.wasDeduplicated)
        #expect(try await homes(services, of: asset) == [refs.id])

        // Re-capture again into Unsorted: it is filed now, so the row is skipped.
        let intoUnsorted = try await services.ingest(
            assetDraft(hash: invariantHash("h")),
            from: sourceDraft(url: "https://example.com/h"), into: unsorted)
        #expect(intoUnsorted.wasDeduplicated)
        #expect(try await homes(services, of: asset) == [refs.id])
    }

    // MARK: Rule 2 — unfiled ⇒ unsorted

    @Test("removing the LAST real membership re-homes the asset to Unsorted")
    func removeLastMembershipRehomes() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id, tag: "i")

        try await services.removeAssets([asset], from: refs.id)

        #expect(try await homes(services, of: asset) == [unsorted])
    }

    @Test("removing one of several memberships does NOT re-home")
    func removeOneOfManyKeepsFiled() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let moods = try await services.createCollection(name: "Moods")
        let asset = try await seedAsset(services, into: refs.id, tag: "j")
        try await services.addAssets([asset], to: moods.id)

        try await services.removeAssets([asset], from: refs.id)

        #expect(try await homes(services, of: asset) == [moods.id])
    }

    @Test("a re-homed asset is APPENDED to Unsorted, behind what is already there")
    func rehomeAppendsToUnsorted() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let resident = try await seedAsset(services, into: unsorted, tag: "k")
        let filed = try await seedAsset(services, into: refs.id, tag: "l")

        try await services.removeAssets([filed], from: refs.id)

        #expect(try await memberAssetIDs(services, of: unsorted) == [resident, filed])
    }

    @Test("removing FROM Unsorted is exempt — the verb is not undone by rule 2")
    func removeFromUnsortedIsExempt() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services, into: unsorted, tag: "m")

        try await services.removeAssets([asset], from: unsorted)

        #expect(try await homes(services, of: asset).isEmpty)
    }

    @Test("a batch re-home covers every unfiled asset in it, in batch order")
    func batchRehome() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let moods = try await services.createCollection(name: "Moods")
        let first = try await seedAsset(services, into: refs.id, tag: "n")
        let second = try await seedAsset(services, into: refs.id, tag: "o")
        let alsoMoods = try await seedAsset(services, into: refs.id, tag: "p")
        try await services.addAssets([alsoMoods], to: moods.id)

        try await services.removeAssets([first, second, alsoMoods], from: refs.id)

        #expect(try await memberAssetIDs(services, of: unsorted) == [first, second])
        #expect(try await homes(services, of: alsoMoods) == [moods.id])
    }

    // MARK: Exemption — verbatim restore

    @Test("delete-undo restores memberships verbatim, legacy both-places included")
    func restoreIsVerbatim() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id, tag: "q")
        // A LEGACY row, written under the schema directly: the funnel can no longer
        // produce this shape, and migration v16 is what clears it in the field.
        // Restore must reproduce exactly what it captured, not silently normalize.
        try await temp.database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO collection_item (id, collection_id, asset_id, added_at, manual_order)
                VALUES (?, ?, ?, ?, 0);
                """, arguments: [
                    UUID().uuidString.lowercased(),
                    Collection.unsortedID.uuidString.lowercased(),
                    asset.uuidString.lowercased(),
                    Date(),
                ])
        }
        #expect(try await homes(services, of: asset) == [refs.id, unsorted])

        let backup = try await services.deleteAssetsRecoverable([asset])
        try await services.restoreDeletedAssets(backup)

        #expect(try await homes(services, of: asset) == [refs.id, unsorted])
    }
}
