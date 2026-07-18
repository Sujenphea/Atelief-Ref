// AtelierCore — smart collections / saved searches (015)
//
// The public saved-search surface: CRUD (create + read-back, name validation,
// list order, rename, rules-update, delete), the LIVE evaluation path proving
// every rule dimension maps 1:1 onto `searchAssets` (text / platform / tag / tag-
// match / collection / whole-library), and the interesting semantic edges — a
// deleted-tag conjunct is dropped (not silently empty) and badged, a renamed tag
// stays matched (rules store ids), and a corrupt rule blob throws rather than
// evaluating to nothing. Deleting a saved search never touches assets.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: saved searches (015)")
struct ServicesSavedSearchTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one image asset on `platform`, optionally titled (title feeds
    /// `source_fts`, so a titled asset is findable by text). Returns the asset.
    @discardableResult
    private func ingest(
        _ services: AppServices, into c: UUID, hash: String,
        platform: Platform = .web, title: String? = nil
    ) async throws -> Asset {
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 320, height: 240, duration: nil, fileSize: 1024,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: platform, originalURL: "https://e/\(hash)",
            authorHandle: nil, authorName: nil, title: title, capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c).asset
    }

    // MARK: - CRUD: create + read-back

    @Test("create then read-back returns the saved search with decodable rules")
    func createAndRead() async throws {
        let (services, _) = try makeServices()
        let rules = SearchRules(text: "grid", platform: .pinterest, tagMatch: .any)
        let created = try await services.createSavedSearch(name: "  Pinterest grid  ", rules: rules)

        #expect(created.name == "Pinterest grid")           // trimmed
        #expect(created.decodedRules == rules)               // rules round-trip

        let fetched = try await services.savedSearch(id: created.id)
        #expect(fetched?.id == created.id)
        #expect(fetched?.name == "Pinterest grid")
        #expect(fetched?.decodedRules == rules)
    }

    @Test("create stamps the current rule version even if the caller passes another")
    func createStampsVersion() async throws {
        let (services, _) = try makeServices()
        // A caller hands in a rule claiming a bogus future version; the store
        // stamps the version it actually wrote.
        let rules = SearchRules(text: "x", version: 999)
        let created = try await services.createSavedSearch(name: "v", rules: rules)
        #expect(created.decodedRules?.version == SearchRules.currentVersion)
    }

    @Test("an empty-name saved search is rejected (invalidName)")
    func emptyNameRejected() async throws {
        let (services, _) = try makeServices()
        await #expect(throws: AtelierError.invalidName) {
            try await services.createSavedSearch(name: "   ", rules: SearchRules())
        }
    }

    @Test("an empty rule (whole library) is a valid saved search")
    func emptyRuleAllowed() async throws {
        let (services, _) = try makeServices()
        let created = try await services.createSavedSearch(name: "Everything", rules: SearchRules())
        #expect(created.decodedRules == SearchRules())
    }

    @Test("savedSearch(id:) is nil for an unknown id")
    func getMissingIsNil() async throws {
        let (services, _) = try makeServices()
        #expect(try await services.savedSearch(id: UUID()) == nil)
    }

    @Test("savedSearches lists all, newest first")
    func listNewestFirst() async throws {
        let (services, _) = try makeServices()
        let a = try await services.createSavedSearch(name: "A", rules: SearchRules())
        let b = try await services.createSavedSearch(name: "B", rules: SearchRules())
        let c = try await services.createSavedSearch(name: "C", rules: SearchRules())
        let ids = try await services.savedSearches().map(\.id)
        // created_at DESC — most recent first. (Ties break by id DESC; here the
        // creations are ordered in time.)
        #expect(Set(ids) == [a.id, b.id, c.id])
        #expect(ids.first == c.id)
    }

    // MARK: - CRUD: rename / update / delete

    @Test("rename changes the name and bumps updatedAt")
    func rename() async throws {
        let (services, _) = try makeServices()
        let created = try await services.createSavedSearch(name: "old", rules: SearchRules())
        let renamed = try await services.renameSavedSearch(id: created.id, to: "  new  ")
        #expect(renamed.name == "new")
        #expect(renamed.updatedAt >= created.updatedAt)
        // Persisted.
        #expect(try await services.savedSearch(id: created.id)?.name == "new")
    }

    @Test("rename to empty is rejected; rename of a missing search is notFound")
    func renameEdges() async throws {
        let (services, _) = try makeServices()
        let created = try await services.createSavedSearch(name: "keep", rules: SearchRules())
        await #expect(throws: AtelierError.invalidName) {
            try await services.renameSavedSearch(id: created.id, to: " ")
        }
        await #expect(throws: AtelierError.self) {
            try await services.renameSavedSearch(id: UUID(), to: "ghost")
        }
    }

    @Test("updateSavedSearchRules replaces the rules and bumps updatedAt")
    func updateRules() async throws {
        let (services, _) = try makeServices()
        let created = try await services.createSavedSearch(
            name: "s", rules: SearchRules(platform: .twitter))
        let newRules = SearchRules(text: "poster", platform: .pinterest, tagMatch: .any)
        let updated = try await services.updateSavedSearchRules(id: created.id, rules: newRules)
        #expect(updated.decodedRules == newRules)
        #expect(updated.updatedAt >= created.updatedAt)
        #expect(try await services.savedSearch(id: created.id)?.decodedRules == newRules)
    }

    @Test("updateSavedSearchRules on a missing search is notFound")
    func updateRulesMissing() async throws {
        let (services, _) = try makeServices()
        await #expect(throws: AtelierError.self) {
            try await services.updateSavedSearchRules(id: UUID(), rules: SearchRules())
        }
    }

    @Test("delete removes the search; deleting a missing one is notFound")
    func delete() async throws {
        let (services, _) = try makeServices()
        let created = try await services.createSavedSearch(name: "temp", rules: SearchRules())
        try await services.deleteSavedSearch(id: created.id)
        #expect(try await services.savedSearch(id: created.id) == nil)
        await #expect(throws: AtelierError.self) {
            try await services.deleteSavedSearch(id: created.id)
        }
    }

    @Test("deleting a saved search never touches assets")
    func deleteLeavesAssetsUntouched() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let asset = try await ingest(services, into: c.id, hash: "a1")
        let search = try await services.createSavedSearch(
            name: "s", rules: SearchRules(collectionID: c.id))
        try await services.deleteSavedSearch(id: search.id)
        // The asset (and its membership) survive.
        #expect(try await services.searchAssets(text: nil).map(\.asset.id) == [asset.id])
    }

    // MARK: - Live evaluation: the 1:1 mapping onto searchAssets

    @Test("evaluate maps the platform rule onto the platform filter")
    func evaluatePlatform() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let p1 = try await ingest(services, into: c.id, hash: "a1", platform: .pinterest)
        let p2 = try await ingest(services, into: c.id, hash: "a2", platform: .pinterest)
        _ = try await ingest(services, into: c.id, hash: "a3", platform: .twitter)

        let hits = try await services.evaluate(rules: SearchRules(platform: .pinterest)).map(\.asset.id)
        #expect(Set(hits) == [p1.id, p2.id])
    }

    @Test("evaluate maps the text rule onto full-text search")
    func evaluateText() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let match = try await ingest(services, into: c.id, hash: "a1", title: "Helvetica specimen")
        _ = try await ingest(services, into: c.id, hash: "a2", title: "Garamond poster")

        let hits = try await services.evaluate(rules: SearchRules(text: "helvetica")).map(\.asset.id)
        #expect(hits == [match.id])
    }

    @Test("evaluate maps tag rules onto .all / .any tag filters")
    func evaluateTags() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let a1 = try await ingest(services, into: c.id, hash: "a1")
        let a2 = try await ingest(services, into: c.id, hash: "a2")
        let tagA = try await services.applyTag("ui", to: a1.id, source: .user)
        _ = try await services.applyTag("ui", to: a2.id, source: .user)
        let tagB = try await services.applyTag("editorial", to: a1.id, source: .user)

        // .all — must carry BOTH ⇒ only a1.
        let all = try await services.evaluate(
            rules: SearchRules(tagIDs: [tagA.id, tagB.id], tagMatch: .all)).map(\.asset.id)
        #expect(all == [a1.id])
        // .any — either tag ⇒ both.
        let any = try await services.evaluate(
            rules: SearchRules(tagIDs: [tagA.id, tagB.id], tagMatch: .any)).map(\.asset.id)
        #expect(Set(any) == [a1.id, a2.id])
    }

    @Test("evaluate maps the collection rule onto collection scope")
    func evaluateCollection() async throws {
        let (services, _) = try makeServices()
        let refs = try await services.createCollection(name: "Refs")
        let other = try await services.createCollection(name: "Other")
        let inRefs = try await ingest(services, into: refs.id, hash: "a1")
        _ = try await ingest(services, into: other.id, hash: "a2")

        let hits = try await services.evaluate(
            rules: SearchRules(collectionID: refs.id)).map(\.asset.id)
        #expect(hits == [inRefs.id])
    }

    @Test("an empty rule evaluates to the whole library")
    func evaluateEmptyIsEverything() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let a1 = try await ingest(services, into: c.id, hash: "a1")
        let a2 = try await ingest(services, into: c.id, hash: "a2")
        let hits = try await services.evaluate(rules: SearchRules()).map(\.asset.id)
        #expect(Set(hits) == [a1.id, a2.id])
    }

    @Test("evaluateSavedSearch runs a persisted search by id; unknown id is notFound")
    func evaluateByID() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let pin = try await ingest(services, into: c.id, hash: "a1", platform: .pinterest)
        _ = try await ingest(services, into: c.id, hash: "a2", platform: .twitter)
        let search = try await services.createSavedSearch(
            name: "Pins", rules: SearchRules(platform: .pinterest))

        #expect(try await services.evaluateSavedSearch(id: search.id).map(\.asset.id) == [pin.id])
        await #expect(throws: AtelierError.self) {
            try await services.evaluateSavedSearch(id: UUID())
        }
    }

    @Test("evaluate honors the limit (delegates to searchAssets paging)")
    func evaluateRespectsLimit() async throws {
        let (services, _) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        for i in 0 ..< 5 { _ = try await ingest(services, into: c.id, hash: "a\(i)") }
        #expect(try await services.evaluate(rules: SearchRules(), limit: 2).count == 2)
    }

    // MARK: - Semantic edges

    @Test("a deleted-tag conjunct is dropped at evaluation (not silently empty) and badged")
    func deletedTagDropped() async throws {
        let (services, temp) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let a1 = try await ingest(services, into: c.id, hash: "a1")
        let a2 = try await ingest(services, into: c.id, hash: "a2")
        let tagA = try await services.applyTag("ui", to: a1.id, source: .user)
        _ = try await services.applyTag("ui", to: a2.id, source: .user)
        let tagB = try await services.applyTag("editorial", to: a1.id, source: .user)

        let search = try await services.createSavedSearch(
            name: "ui + editorial",
            rules: SearchRules(tagIDs: [tagA.id, tagB.id], tagMatch: .all))
        // Before deletion: .all ⇒ only a1 carries both.
        #expect(try await services.evaluateSavedSearch(id: search.id).map(\.asset.id) == [a1.id])

        // Delete tag B at the row level (no service deletes a tag; a raw delete
        // cascades its asset_tag joins, exactly as a real deletion would).
        try await temp.database.pool.write { db in
            try db.execute(sql: "DELETE FROM tag WHERE id = ?",
                           arguments: [tagB.id.uuidString.lowercased()])
        }

        // The missing conjunct is DROPPED — the surviving [A] still filters, so
        // now BOTH ui-tagged assets match (broadened, not empty).
        let after = try await services.evaluateSavedSearch(id: search.id).map(\.asset.id)
        #expect(Set(after) == [a1.id, a2.id])
        // And the card can badge exactly which tag went missing.
        #expect(try await services.savedSearchMissingTags(id: search.id) == [tagB.id])
    }

    @Test("renaming a tag used in a rule keeps it matched (rules store ids, not names)")
    func renamedTagStillMatches() async throws {
        let (services, temp) = try makeServices()
        let c = try await services.createCollection(name: "Refs")
        let a1 = try await ingest(services, into: c.id, hash: "a1")
        let tagA = try await services.applyTag("ui", to: a1.id, source: .user)
        let search = try await services.createSavedSearch(
            name: "ui", rules: SearchRules(tagIDs: [tagA.id], tagMatch: .all))

        // Rename the tag row in place (its id is unchanged).
        try await temp.database.pool.write { db in
            try db.execute(sql: "UPDATE tag SET name = ? WHERE id = ?",
                           arguments: ["renamed", tagA.id.uuidString.lowercased()])
        }

        #expect(try await services.evaluateSavedSearch(id: search.id).map(\.asset.id) == [a1.id])
        #expect(try await services.savedSearchMissingTags(id: search.id).isEmpty)
    }

    @Test("a corrupt rule blob throws invalidSavedSearchRules, not an empty result")
    func corruptRulesThrow() async throws {
        let (services, temp) = try makeServices()
        let search = try await services.createSavedSearch(name: "s", rules: SearchRules())
        // Corrupt the stored rules to un-decodable garbage.
        try await temp.database.pool.write { db in
            try db.execute(sql: "UPDATE saved_search SET rules = ? WHERE id = ?",
                           arguments: ["not json", search.id.uuidString.lowercased()])
        }
        await #expect(throws: AtelierError.invalidSavedSearchRules(id: search.id)) {
            try await services.evaluateSavedSearch(id: search.id)
        }
        // Missing-tags on a corrupt blob has nothing tag-specific to report.
        #expect(try await services.savedSearchMissingTags(id: search.id).isEmpty)
    }

    @Test("savedSearchMissingTags on an unknown id is notFound")
    func missingTagsUnknownID() async throws {
        let (services, _) = try makeServices()
        await #expect(throws: AtelierError.self) {
            try await services.savedSearchMissingTags(id: UUID())
        }
    }
}
