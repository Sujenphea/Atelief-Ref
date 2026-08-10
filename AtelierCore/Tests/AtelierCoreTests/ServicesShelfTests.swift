// AtelierCore — App Services archive-shelf tests (023 · A)
//
// The write half of the shelf: `archive` / `unarchive` round-trip, are
// idempotent (and SAY so, via the changed-row count the shell builds undo on),
// and — the assertion the whole feature rests on — touch NOTHING but the one
// column. Archiving that quietly dropped a membership would still pass a
// "the item disappeared" test and fail the user the moment they unarchived,
// so losslessness is asserted at full fidelity here rather than by row counts.
//
// House style mirrors `ServicesFavoritesTests`, the nearest neighbour: same
// per-asset flag shape, same batch/idempotence/missing-id contract.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: archive shelf (023 · A)")
struct ServicesShelfTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    @discardableResult
    private func seedAsset(
        _ services: AppServices, into collectionID: UUID, title: String? = nil
    ) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", title: title,
            capturedAt: Date())
        return try await services.ingest(draft, from: source, into: collectionID).asset.id
    }

    private func fetchAsset(_ temp: TempDatabase, _ id: UUID) throws -> Asset? {
        try temp.database.read { try Asset.fetchOne($0, key: id.uuidString.lowercased()) }
    }

    // MARK: - The writers

    @Test("archive stamps a timestamp; unarchive clears it")
    func roundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        // A newly ingested asset is not archived — the v20 default, seen from
        // the funnel rather than from the migration.
        #expect(try fetchAsset(temp, asset)?.archivedAt == nil)

        let before = Date()
        #expect(try await services.archive([asset]) == 1)
        let stamped = try #require(try fetchAsset(temp, asset)?.archivedAt)
        // Server-authoritative and plausible: the service stamps its own clock,
        // so the value must sit in the window the call actually spanned.
        #expect(stamped >= before.addingTimeInterval(-1))
        #expect(stamped <= Date().addingTimeInterval(1))

        #expect(try await services.unarchive([asset]) == 1)
        #expect(try fetchAsset(temp, asset)?.archivedAt == nil)
    }

    /// Archiving an archived item is a no-op — and REPORTS itself as one, which
    /// is what the shell's undo registration keys off.
    @Test("archive is idempotent and reports zero changed rows")
    func idempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        #expect(try await services.archive([asset]) == 1)
        #expect(try await services.archive([asset]) == 0)
        #expect(try await services.archive([asset]) == 0)

        // …and the same on the way back off the shelf.
        #expect(try await services.unarchive([asset]) == 1)
        #expect(try await services.unarchive([asset]) == 0)
    }

    /// The shelf orders by `archived_at`, so a second archive of the same item
    /// must not silently reshuffle it to the top. This is the assertion that
    /// makes "idempotent" mean the timestamp too, not just the row count.
    @Test("re-archiving keeps the ORIGINAL timestamp, so shelf order is stable")
    func reArchiveKeepsOriginalTimestamp() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        try await services.archive([asset])
        let first = try #require(try fetchAsset(temp, asset)?.archivedAt)
        // Push the stored stamp back a week so a re-stamp would be unmistakable
        // (two `Date()` calls in one test can land in the same millisecond).
        let backdated = first.addingTimeInterval(-7 * 24 * 60 * 60)
        try temp.database.write { db in
            try db.execute(
                sql: "UPDATE asset SET archived_at = ? WHERE id = ?",
                arguments: [backdated, asset.uuidString.lowercased()])
        }

        #expect(try await services.archive([asset]) == 0)
        #expect(try fetchAsset(temp, asset)?.archivedAt == backdated)
    }

    @Test("a batch archives only the rows it actually changes")
    func batchCountsOnlyChanges() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let already = try await seedAsset(services, into: refs.id)
        let fresh = try await seedAsset(services, into: refs.id)
        try await services.archive([already])

        // Two ids in, one already on the shelf → one row changed.
        #expect(try await services.archive([already, fresh]) == 1)
        #expect(try fetchAsset(temp, fresh)?.archivedAt != nil)
    }

    @Test("a duplicated id counts once; an empty set is a no-op")
    func duplicatesAndEmpty() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        #expect(try await services.archive([asset, asset, asset]) == 1)
        #expect(try await services.archive([]) == 0)
        #expect(try await services.unarchive([]) == 0)
    }

    /// A multi-select over a grid can be reloaded underneath the user, so one
    /// stale id must not fail the batch — the rest still archive.
    @Test("a missing id is ignored rather than failing the batch")
    func missingIDIgnored() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        #expect(try await services.archive([asset, UUID()]) == 1)
        #expect(try fetchAsset(temp, asset)?.archivedAt != nil)
    }

    // MARK: - Losslessness

    /// The premise of the whole feature over delete: archiving destroys nothing,
    /// so unarchiving has nothing to reconstruct. Asserted at FULL FIDELITY over
    /// an asset in two collections and one space — ordered membership arrays,
    /// manual order values, the space placement, tags, note and the star — not
    /// at count level, because a delete-and-recreate implementation would pass a
    /// count-level test and fail this one.
    @Test("archive touches one column: memberships, placement, tags, note survive")
    func archivingIsLossless() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let left = try await services.createCollection(name: "Left")
        let right = try await services.createCollection(name: "Right")
        let board = try await services.createSpace(name: "Board")

        let subject = try await seedAsset(services, into: left.id)
        // Neighbours, so "order survived" is a real claim and not vacuous.
        let before1 = try await seedAsset(services, into: left.id)
        let after1 = try await seedAsset(services, into: left.id)
        try await services.addAssets([subject], to: right.id)
        _ = try await services.addAssetToSpace(
            assetID: subject, to: board.id, x: 12, y: 34, w: 56, h: 78, z: 2)
        try await services.setName("Kept", for: subject)
        try await services.setNote("A note that must survive", for: subject)
        try await services.setFavorite(true, for: subject)
        _ = try await services.applyTag("brutalism", to: subject, source: .user)

        /// `includeArchived` is the parameter under test as much as the verbs
        /// are: the SAME snapshot read either hides the subject or does not.
        func snapshot(includeArchived: Bool) async throws -> (
            left: [UUID], right: [UUID], placement: [SpaceItem],
            tagNames: [String], asset: Asset?
        ) {
            (
                left: try await services.collectionItems(
                    in: left.id, sort: .manual, includeArchived: includeArchived)
                    .map(\.asset.id),
                right: try await services.collectionItems(
                    in: right.id, sort: .manual, includeArchived: includeArchived)
                    .map(\.asset.id),
                placement: try await services.spaceItems(in: board.id).map(\.item),
                tagNames: try await services.tags(for: subject).map(\.name),
                asset: try fetchAsset(temp, subject)
            )
        }

        let before = try await snapshot(includeArchived: false)
        #expect(before.left.contains(subject))     // the fixture is real
        #expect(before.right.contains(subject))

        try await services.archive([subject])
        // Archived is a state of the ASSET, applied at the READ. The membership
        // rows are untouched while it is archived — which is exactly why the
        // same read, asked to include archived items, still sees the ORIGINAL
        // arrays, neighbours and order intact.
        let hidden = try await snapshot(includeArchived: false)
        #expect(!hidden.left.contains(subject))
        #expect(hidden.right.isEmpty)
        #expect(hidden.left == before.left.filter { $0 != subject })

        let during = try await snapshot(includeArchived: true)
        #expect(during.left == before.left)
        #expect(during.right == before.right)

        try await services.unarchive([subject])
        let after = try await snapshot(includeArchived: false)

        #expect(after.left == before.left)
        #expect(after.right == before.right)
        #expect(after.placement.map(\.id) == before.placement.map(\.id))
        #expect(after.placement.map(\.x) == before.placement.map(\.x))
        #expect(after.placement.map(\.y) == before.placement.map(\.y))
        #expect(after.placement.map(\.z) == before.placement.map(\.z))
        #expect(after.tagNames == before.tagNames)
        #expect(after.asset?.name == "Kept")
        #expect(after.asset?.note == "A note that must survive")
        #expect(after.asset?.isFavorite == true)
        #expect(after.asset?.archivedAt == nil)
        #expect(after.asset?.viewCount == before.asset?.viewCount)
        #expect(after.asset?.blobHash == before.asset?.blobHash)
        #expect(after.asset?.createdAt == before.asset?.createdAt)
    }

    /// Archive hides an item from browsing; it does not freeze it. A write verb
    /// that silently no-ops on something you cannot currently see is worse than
    /// one that works (023 · edge case 4).
    @Test("an archived asset stays taggable, favoritable and editable")
    func archivedAssetsStayWritable() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)
        try await services.archive([asset])
        let stamped = try #require(try fetchAsset(temp, asset)?.archivedAt)

        _ = try await services.applyTag("still-editable", to: asset, source: .user)
        #expect(try await services.setFavorite(true, for: asset) == true)
        try await services.setNote("written while on the shelf", for: asset)

        let after = try #require(try fetchAsset(temp, asset))
        #expect(after.isFavorite == true)
        #expect(after.note == "written while on the shelf")
        #expect(try await services.tags(for: asset).map(\.name) == ["still-editable"])
        // …and none of that took it off the shelf.
        #expect(after.archivedAt == stamped)
    }

    /// Deleting an archived item is an ordinary recoverable delete, and ⌘Z must
    /// put it back ARCHIVED — not resurrect it into the middle of a collection
    /// the user had already tidied. `DeletedAssetsBackup` captures whole `Asset`
    /// rows, so this works by construction; the test exists because "restore
    /// forgets one column" is a silent, plausible regression (023 · edge case 4).
    @Test("delete → undo restores an archived item still archived")
    func deleteUndoKeepsTheShelf() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)
        try await services.archive([asset])
        let stamped = try #require(try fetchAsset(temp, asset)?.archivedAt)

        let backup = try await services.deleteAssetsRecoverable([asset])
        #expect(try fetchAsset(temp, asset) == nil)

        try await services.restoreDeletedAssets(backup)

        let restored = try #require(try fetchAsset(temp, asset))
        #expect(restored.archivedAt == stamped)
        // …and it is on the shelf, not in the collection.
        #expect(try await services.shelfAssets().map(\.asset.id) == [asset])
        #expect(try await services.collectionItems(
            in: refs.id, includeArchived: false).isEmpty)
    }

    // MARK: - The mixed-selection read

    @Test("archivedAssetIDs reports exactly the archived subset")
    func archivedSubset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let shelved = try await seedAsset(services, into: refs.id)
        let visible = try await seedAsset(services, into: refs.id)
        try await services.archive([shelved])

        let ghost = UUID()
        let subset = try await services.archivedAssetIDs(among: [shelved, visible, ghost])

        #expect(subset == [shelved])
        #expect(try await services.archivedAssetIDs(among: []).isEmpty)
    }
}
