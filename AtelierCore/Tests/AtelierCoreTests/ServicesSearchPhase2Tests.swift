// AtelierCore — search overhaul Phase 2 integration tests (044 · 046)
//
// End-to-end coverage for the trigram substring backbone, through the real FTS5
// pipeline (the pure string builder is FTSQueryBuilderTests):
//   • mid-word substring recall on the short fields — title, user name, tag,
//     collection (1A/2A · trigram tables v13);
//   • the ≥3-char eligibility boundary and its unicode61 / LIKE fallback (3A);
//   • multi-term AND substring semantics;
//   • `.relevance` tiering: whole-word > substring > OCR (4A), RELATIVE order only.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: search overhaul Phase 2 — trigram (044/046)")
struct ServicesSearchPhase2Tests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one DISTINCT asset into `c` (unique hash+url so 18A dedup never
    /// collapses two calls), optionally with a source title. Returns its id.
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

    // MARK: substring recall on the short fields (2A)

    @Test("a mid-word substring in the source title surfaces the item (air → chair)")
    func substringInTitle() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let target = try await seed(services, into: c.id, title: "Chair Study")
        // "air" is NOT a prefix of "Chair" — only a trigram substring finds it.
        #expect(try await ids(services.searchAssets(text: "air")) == [target])
    }

    @Test("a mid-word substring in the user-given name surfaces the item")
    func substringInName() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "untitled")
        try await services.setName("Brutalism", for: a)
        #expect(try await ids(services.searchAssets(text: "utal")) == [a])
    }

    @Test("a mid-word substring of a tag name surfaces its asset (free text)")
    func substringInTagName() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "untitled")
        _ = try await services.applyTag("modernism", to: a, source: .user)
        // "dern" is inside "modernism" but not a prefix → trigram substring arm.
        #expect(try await ids(services.searchAssets(text: "dern")) == [a])
    }

    @Test("a mid-word substring of a collection name surfaces its members")
    func substringInCollectionName() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let interiors = try await services.createCollection(name: "Interiors")
        let other = try await services.createCollection(name: "Misc")
        let inside = try await seed(services, into: interiors.id, title: "x")
        _ = try await seed(services, into: other.id, title: "x")
        #expect(try await ids(services.searchAssets(text: "erior")) == [inside])
    }

    // MARK: multi-term AND substring

    @Test("multi-term substring ANDs — every term must appear in the field")
    func multiTermAndSubstring() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let both = try await seed(services, into: c.id, title: "Art Deco Poster")
        _ = try await seed(services, into: c.id, title: "Art Nouveau")
        // "art deco" → "art" AND "deco" as substrings → only the first title.
        #expect(try await ids(services.searchAssets(text: "art deco")) == [both])
    }

    // MARK: ≥3-char eligibility boundary + fallback (3A)

    @Test("a <3-char query does NOT substring-match (keeps Phase-1 prefix semantics)")
    func shortQueryFallsBackToPrefix() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await seed(services, into: c.id, title: "Chair")
        // "ai" (2 chars) is trigram-ineligible; unicode61 prefix "ai"* can't match
        // "Chair" (doesn't start with "ai") → no hit. Substring is a ≥3-char power.
        #expect(try await services.searchAssets(text: "ai").isEmpty)
        // …but the ≥3-char "air" DOES find it (trigram engaged).
        #expect(try await ids(services.searchAssets(text: "air")).count == 1)
    }

    @Test("a trailing space finishes the word → EXACT, suppressing substring too")
    func trailingSpaceSuppressesSubstring() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await seed(services, into: c.id, title: "Typography Poster")
        // "typo" (no space) substring-finds "Typography"…
        #expect(try await ids(services.searchAssets(text: "typo")).count == 1)
        // …but "typo " signals a finished word → exact "typo", which is no whole
        // word in the title AND no substring arm runs → no hit (5A parity).
        #expect(try await services.searchAssets(text: "typo ").isEmpty)
    }

    @Test("a <3-char tag: needle still filters via the LIKE fallback")
    func shortTagNeedleFallsBack() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "one")
        let b = try await seed(services, into: c.id, title: "two")
        _ = b
        _ = try await services.applyTag("sf", to: a, source: .user)
        // "sf" (2 chars) can't form a trigram; the LIKE fallback still matches it.
        #expect(try await ids(services.searchAssets(tagNameContains: "sf")) == [a])
    }

    @Test("a ≥3-char tagNameContains substring filters via trigram")
    func tagNameContainsSubstringTrigram() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id, title: "one")
        _ = try await services.applyTag("brutalism", to: a, source: .user)
        // "utal" is a mid-word substring — trigram, not prefix.
        #expect(try await ids(services.searchAssets(tagNameContains: "utal")) == [a])
    }

    // MARK: relevance tiering — word > substring > OCR (4A), RELATIVE order only

    @Test("a whole-word hit outranks a substring-only hit, which outranks OCR")
    func relevanceWordThenSubstringThenOCR() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // WORD: the query is a standalone word in the title → tier 0 (bm25).
        let word = try await seed(services, into: c.id, title: "helvetica specimen")
        // SUBSTRING-only: "helvetica" is embedded in a longer token, so unicode61
        // never word-/prefix-matches it — only the trigram substring arm does.
        let substring = try await seed(services, into: c.id, title: "untitled")
        try await services.setName("preHelveticaBold", for: substring)
        // OCR-only: the term appears solely in derived OCR text → ranks last.
        let ocr = try await seed(services, into: c.id, title: "untitled scan")
        _ = try await services.upsertAnalysis(
            assetID: ocr, ocrText: "a page set in helvetica", analyzerVersion: 1)

        let hits = try await services.searchAssets(text: "helvetica", sort: .relevance)
        #expect(ids(hits) == [word, substring, ocr])
    }
}
