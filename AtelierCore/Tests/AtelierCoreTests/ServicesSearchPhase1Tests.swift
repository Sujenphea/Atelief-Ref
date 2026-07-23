// AtelierCore — search overhaul Phase 1 integration tests (044/045)
//
// End-to-end coverage for the keyword-backbone changes, exercised through the
// real FTS5 pipeline (not the string builder — that's FTSQueryBuilderTests):
//   • prefix / type-ahead matching + trailing-space suppression (5A/14A);
//   • the newly-indexed user-given name / note (1A);
//   • collection-name and `tag:`-style (tagNameContains) free-text arms (2A/17A);
//   • multi-collection OR scope (16A);
//   • `.relevance` ordering as a RELATIVE order, and its cursor rejection (3A/11A).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: search overhaul Phase 1 (044/045)")
struct ServicesSearchPhase1Tests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one DISTINCT asset (unique hash + url so 18A dedup never collapses
    /// two calls) into `c`, optionally with a source title, and return its id.
    @discardableResult
    private func seed(
        _ services: AppServices, into c: UUID,
        platform: Platform = .web, title: String? = nil
    ) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let url = platform == .web ? "https://e/\(unique)" : "https://x/\(unique)"
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: platform, originalURL: url, title: title, capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c).asset.id
    }

    private func ids(_ hits: [AssetDetail]) -> [UUID] { hits.map(\.asset.id) }

    // MARK: prefix / type-ahead (5A/14A)

    @Test("a partial word finds the fuller term as the user types (prefix)")
    func prefixMatchesLongerWord() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let target = try await seed(services, into: c.id, title: "Typography Poster")

        // "typo" (no trailing space) → prefix → finds "Typography".
        #expect(try await ids(services.searchAssets(text: "typo")) == [target])
    }

    @Test("a trailing space finishes the word → exact, so a partial no longer hits")
    func trailingSpaceIsExact() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await seed(services, into: c.id, title: "Typography Poster")

        // "typo " (trailing space) → exact "typo" → no whole word "typo" exists.
        #expect(try await services.searchAssets(text: "typo ").isEmpty)
    }

    @Test("a lone 1-char query is exact-only (no huge-slice prefix)")
    func singleCharExactOnly() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await seed(services, into: c.id, title: "Typography")

        // "t" must not prefix-match "Typography"; only a standalone "t" token would.
        #expect(try await services.searchAssets(text: "t").isEmpty)
    }

    // MARK: user-given name / note (1A)

    @Test("naming an asset makes it findable by that name (v12 asset_fts + triggers)")
    func nameIsSearchable() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "untitled")
        // Not findable before naming…
        #expect(try await services.searchAssets(text: "moodboard").isEmpty)
        try await services.setName("Moodboard Hero", for: a)
        // …and findable after (the sync trigger re-indexed the row).
        #expect(try await ids(services.searchAssets(text: "moodboard")) == [a])
    }

    @Test("an asset's note is searchable; clearing it removes the hit")
    func noteIsSearchableAndClearable() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "untitled")
        try await services.setNote("reference for the brutalist stairwell", for: a)
        #expect(try await ids(services.searchAssets(text: "brutalist")) == [a])
        try await services.setNote(nil, for: a)
        #expect(try await services.searchAssets(text: "brutalist").isEmpty)
    }

    // MARK: collection-name free-text arm (2A)

    @Test("free text finds an item by the name of a collection it lives in")
    func collectionNameFoldedIntoFreeText() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let interiors = try await services.createCollection(name: "Interiors")
        let other = try await services.createCollection(name: "Misc")
        let inside = try await seed(services, into: interiors.id, title: "chair")
        _ = try await seed(services, into: other.id, title: "chair")

        // "interior" prefix-matches the collection NAME → its member surfaces.
        #expect(try await ids(services.searchAssets(text: "interior")) == [inside])
    }

    // MARK: tag: name filter (17A)

    @Test("tagNameContains restricts to assets carrying a name-matching tag")
    func tagNameContainsFilters() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let tagged = try await seed(services, into: c.id, title: "one")
        let untagged = try await seed(services, into: c.id, title: "two")
        _ = untagged
        _ = try await services.applyTag("brutalism", to: tagged, source: .user)

        #expect(try await ids(services.searchAssets(tagNameContains: "brutal")) == [tagged])
        // A `#`-only / blank needle is inert (no conjunct → all assets).
        #expect(try await services.searchAssets(tagNameContains: "#").count == 2)
    }

    @Test("tagNameContains ANDs with a structured tagIDs filter (both must hold)")
    func tagNameContainsComposesWithTagIDs() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let both = try await seed(services, into: c.id, title: "a")
        let onlyStructured = try await seed(services, into: c.id, title: "b")

        let refTag = try await services.applyTag("reference", to: both, source: .user)
        _ = try await services.applyTag("brutalism", to: both, source: .user)
        _ = try await services.applyTag("reference", to: onlyStructured, source: .user)

        // Structured filter = carries "reference"; needle = a tag containing "brut".
        // Only `both` satisfies both conjuncts.
        let hits = try await services.searchAssets(
            tagIDs: [refTag.id], tagNameContains: "brut")
        #expect(ids(hits) == [both])
    }

    // MARK: multi-collection OR scope (16A)

    @Test("collectionIDs scopes to membership in ANY listed collection (OR)")
    func collectionIDsAreOred() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "A")
        let b = try await services.createCollection(name: "B")
        let c = try await services.createCollection(name: "C")
        let inA = try await seed(services, into: a.id)
        let inB = try await seed(services, into: b.id)
        _ = try await seed(services, into: c.id)

        let hits = try await services.searchAssets(collectionIDs: [a.id, b.id])
        #expect(Set(ids(hits)) == [inA, inB])
        // Empty list = whole library (no scope).
        #expect(try await services.searchAssets(collectionIDs: []).count == 3)
    }

    // MARK: relevance ordering (3A/11A) — RELATIVE order only, never bm25 floats

    @Test("a name/title match outranks an OCR-only match under .relevance")
    func relevanceRanksStrongFieldAboveOCR() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Strong: the query term is the source TITLE.
        let strong = try await seed(services, into: c.id, title: "helvetica specimen")
        // Weak: the term appears only in derived OCR text.
        let weak = try await seed(services, into: c.id, title: "untitled scan")
        _ = try await services.upsertAnalysis(
            assetID: weak, ocrText: "a page set in helvetica", analyzerVersion: 1)

        let hits = try await services.searchAssets(text: "helvetica", sort: .relevance)
        // Both match; the title match ranks first.
        #expect(ids(hits) == [strong, weak])
    }

    @Test("a direct-field match outranks a match only via collection name")
    func relevanceRanksDirectFieldAboveCollectionName() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        // One collection NAMED to match the query, one plain.
        let named = try await services.createCollection(name: "helvetica refs")
        let plain = try await services.createCollection(name: "plain")
        // A: its own user-given name matches the query (tier-0, asset_fts).
        let direct = try await seed(services, into: plain.id, title: "untitled")
        try await services.setName("helvetica sheet", for: direct)
        // B: matches ONLY because it lives in the "helvetica refs" collection
        //    (the indirect LIKE arm — a weaker tier than a direct field).
        let viaCollection = try await seed(services, into: named.id, title: "untitled")

        let hits = try await services.searchAssets(text: "helvetica", sort: .relevance)
        #expect(ids(hits) == [direct, viaCollection])
    }

    @Test(".relevance with a keyset cursor throws (relevance isn't pageable)")
    func relevanceWithCursorThrows() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "brass")
        // A cursor value is enough to trip the guard; its contents don't matter.
        let cursor = AssetPageCursor(createdAt: Date(), id: a)
        await #expect(throws: AtelierError.relevanceSortUnpageable) {
            _ = try await services.searchAssets(
                text: "brass", sort: .relevance, after: cursor)
        }
    }
}
