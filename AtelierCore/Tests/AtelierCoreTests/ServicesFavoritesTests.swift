// AtelierCore — App Services favorites tests (011 · U5)
//
// The service half of the star: `setFavorite` round-trips, is idempotent (and
// SAYS so, via the changed-row count callers build undo on), reaches every
// membership of a multi-collection asset at once, and survives a delete/restore.
// Plus the `favoritesOnly` search conjunct, which is exercised in combination —
// with a tag filter, with free text, with a collection scope — not just alone,
// because "alone" is the one case a broken conjunct can still pass.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: favorites (011 · U5)")
struct ServicesFavoritesTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one DISTINCT asset into a collection. `title` feeds `source_fts`, so
    /// the search cases can combine the favorites conjunct with real free text.
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

    // MARK: - The writer

    @Test("setFavorite stores and clears the flag")
    func roundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        // A newly ingested asset is not a favorite — the v19 default, seen from
        // the funnel rather than from the migration.
        #expect(try fetchAsset(temp, asset)?.isFavorite == false)

        #expect(try await services.setFavorite(true, for: asset) == true)
        #expect(try fetchAsset(temp, asset)?.isFavorite == true)

        #expect(try await services.setFavorite(false, for: asset) == true)
        #expect(try fetchAsset(temp, asset)?.isFavorite == false)
    }

    /// Favoriting a favorite is a no-op — and REPORTS itself as one. The count is
    /// what the shell's undo registration keys off, so "0 rows changed" has to be
    /// the answer, not just "nothing broke".
    @Test("setFavorite is idempotent and reports zero changed rows")
    func idempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        #expect(try await services.setFavorite(true, for: [asset]) == 1)
        #expect(try await services.setFavorite(true, for: [asset]) == 0)
        #expect(try await services.setFavorite(true, for: [asset]) == 0)
        #expect(try fetchAsset(temp, asset)?.isFavorite == true)

        // …and the same on the way back down.
        #expect(try await services.setFavorite(false, for: [asset]) == 1)
        #expect(try await services.setFavorite(false, for: [asset]) == 0)
    }

    @Test("a batch reports only the rows it actually changed")
    func batchCountsOnlyChanges() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let already = try await seedAsset(services, into: refs.id)
        let fresh = try await seedAsset(services, into: refs.id)
        try await services.setFavorite(true, for: already)

        // Two ids in, one of them already starred → one row changed.
        #expect(try await services.setFavorite(true, for: [already, fresh]) == 1)
        #expect(try fetchAsset(temp, fresh)?.isFavorite == true)
    }

    @Test("an empty set and a duplicated id are both no-ops, not errors")
    func degenerateInputs() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        #expect(try await services.setFavorite(true, for: []) == 0)
        // The same id twice must count ONCE — the caller's undo is built on this
        // number, and a double-count would claim a row that doesn't exist.
        #expect(try await services.setFavorite(true, for: [asset, asset]) == 1)
    }

    /// A multi-select over a grid can name an asset that was deleted a moment ago.
    /// The batch writer swallows that rather than failing the whole press.
    @Test("an unknown id is ignored, and the known ids still land")
    func unknownIDIgnored() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        #expect(try await services.setFavorite(true, for: [asset, UUID()]) == 1)
        #expect(try fetchAsset(temp, asset)?.isFavorite == true)
    }

    /// The invariant the column placement exists for: the star is a property of
    /// the ASSET, so an asset in three collections is favorited in all three.
    @Test("a multi-collection asset is favorited in every collection at once")
    func favoriteIsPerAssetNotPerMembership() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let alpha = try await services.createCollection(name: "Alpha")
        let beta = try await services.createCollection(name: "Beta")
        let gamma = try await services.createCollection(name: "Gamma")
        let asset = try await seedAsset(services, into: alpha.id)
        try await services.addAssets([asset], to: beta.id)
        try await services.addAssets([asset], to: gamma.id)

        try await services.setFavorite(true, for: asset)

        for collection in [alpha, beta, gamma] {
            let items = try await services.collectionItems(in: collection.id)
            #expect(items.count == 1)
            #expect(items.first?.asset.isFavorite == true)
        }
    }

    @Test("favoritedAssetIDs returns exactly the starred ids among those asked for")
    func favoritedSubset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let starred = try await seedAsset(services, into: refs.id)
        let plain = try await seedAsset(services, into: refs.id)
        let elsewhere = try await seedAsset(services, into: refs.id)
        try await services.setFavorite(true, for: [starred, elsewhere])

        #expect(try await services.favoritedAssetIDs(among: [starred, plain]) == [starred])
        #expect(try await services.favoritedAssetIDs(among: []) == [])
        #expect(try await services.favoritedAssetIDs(among: [plain]) == [])
    }

    /// The delete-undo backup carries whole domain records, so the star has to come
    /// back with the asset — otherwise ⌘Z after a delete silently unstars.
    @Test("a recoverable delete restores the flag with the asset")
    func survivesDeleteUndo() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)
        try await services.setFavorite(true, for: asset)

        let backup = try await services.deleteAssetsRecoverable([asset])
        #expect(try fetchAsset(temp, asset) == nil)
        try await services.restoreDeletedAssets(backup)
        #expect(try fetchAsset(temp, asset)?.isFavorite == true)
    }

    // MARK: - The search conjunct

    @Test("favoritesOnly narrows a plain listing")
    func filterAlone() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let starred = try await seedAsset(services, into: refs.id, title: "Chair")
        _ = try await seedAsset(services, into: refs.id, title: "Table")
        try await services.setFavorite(true, for: starred)

        let all = try await services.searchAssets(limit: 50)
        #expect(all.count == 2)
        let favorites = try await services.searchAssets(favoritesOnly: true, limit: 50)
        #expect(favorites.map(\.asset.id) == [starred])
        // Explicit `false` must change nothing — the parameter is a narrowing
        // filter, never a mode.
        #expect(try await services.searchAssets(favoritesOnly: false, limit: 50).count == 2)
    }

    /// AND, not OR: an asset that matches the TEXT but is not a favorite must not
    /// come back, and neither must a favorite that doesn't match the text.
    @Test("favoritesOnly is a conjunct with free text, not a replacement for it")
    func filterWithText() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let favoriteChair = try await seedAsset(services, into: refs.id, title: "Chair study")
        _ = try await seedAsset(services, into: refs.id, title: "Chair sketch")
        let favoriteTable = try await seedAsset(services, into: refs.id, title: "Table study")
        try await services.setFavorite(true, for: [favoriteChair, favoriteTable])

        // Text alone finds both chairs…
        let chairs = try await services.searchAssets(text: "Chair ", limit: 50)
        #expect(chairs.count == 2)
        // …the conjunct keeps only the starred one, and does NOT let the starred
        // TABLE in through an OR.
        let starredChairs = try await services.searchAssets(
            text: "Chair ", favoritesOnly: true, limit: 50)
        #expect(starredChairs.map(\.asset.id) == [favoriteChair])
    }

    /// The same, with the STRUCTURED tag filter — the other arm that could be
    /// accidentally OR-ed, and the one the 011 doc names explicitly.
    @Test("favoritesOnly is a conjunct with a tag filter")
    func filterWithTag() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let taggedFavorite = try await seedAsset(services, into: refs.id, title: "A")
        let taggedPlain = try await seedAsset(services, into: refs.id, title: "B")
        let untaggedFavorite = try await seedAsset(services, into: refs.id, title: "C")
        let tag = try await services.applyTag("brutalist", to: taggedFavorite, source: .user)
        _ = try await services.applyTag("brutalist", to: taggedPlain, source: .user)
        try await services.setFavorite(true, for: [taggedFavorite, untaggedFavorite])

        // Tag alone: both tagged.
        #expect(try await services.searchAssets(tagIDs: [tag.id], limit: 50).count == 2)
        // Tag AND favorite: only the one that is both — the untagged favorite is
        // excluded, and so is the tagged non-favorite.
        let both = try await services.searchAssets(
            tagIDs: [tag.id], favoritesOnly: true, limit: 50)
        #expect(both.map(\.asset.id) == [taggedFavorite])
    }

    /// Three-way: text AND tag AND favorite, so the conjuncts are proven to stack
    /// rather than the last one written winning.
    @Test("favoritesOnly stacks with a tag filter AND free text at once")
    func filterWithTagAndText() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let winner = try await seedAsset(services, into: refs.id, title: "Concrete stair")
        let noStar = try await seedAsset(services, into: refs.id, title: "Concrete ramp")
        let noTag = try await seedAsset(services, into: refs.id, title: "Concrete wall")
        let noText = try await seedAsset(services, into: refs.id, title: "Timber beam")
        let tag = try await services.applyTag("brutalist", to: winner, source: .user)
        _ = try await services.applyTag("brutalist", to: noStar, source: .user)
        _ = try await services.applyTag("brutalist", to: noText, source: .user)
        try await services.setFavorite(true, for: [winner, noTag, noText])

        let hits = try await services.searchAssets(
            text: "Concrete ", tagIDs: [tag.id], favoritesOnly: true, limit: 50)
        #expect(hits.map(\.asset.id) == [winner])
    }

    @Test("favoritesOnly is a conjunct with a collection scope")
    func filterWithCollectionScope() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let inside = try await services.createCollection(name: "Inside")
        let outside = try await services.createCollection(name: "Outside")
        let scopedFavorite = try await seedAsset(services, into: inside.id, title: "A")
        _ = try await seedAsset(services, into: inside.id, title: "B")
        let elsewhereFavorite = try await seedAsset(services, into: outside.id, title: "C")
        try await services.setFavorite(true, for: [scopedFavorite, elsewhereFavorite])

        let hits = try await services.searchAssets(
            collectionIDs: [inside.id], favoritesOnly: true, limit: 50)
        #expect(hits.map(\.asset.id) == [scopedFavorite])
    }

    /// Unstarring must actually remove a hit from the filtered result — the filter
    /// reads the live column, not a snapshot taken at ingest.
    @Test("clearing the flag drops the asset out of the filtered results")
    func filterFollowsWrites() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id, title: "Chair")
        try await services.setFavorite(true, for: asset)
        #expect(try await services.searchAssets(favoritesOnly: true, limit: 50).count == 1)

        try await services.setFavorite(false, for: asset)
        #expect(try await services.searchAssets(favoritesOnly: true, limit: 50).isEmpty)
    }
}
