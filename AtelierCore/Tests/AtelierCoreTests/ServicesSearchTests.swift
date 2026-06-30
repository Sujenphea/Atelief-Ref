// AtelierCore — App Services search tests (chunk 6, P16 + FTS5)
//
// FTS5 text match over the source's title/author fields, the platform filter,
// the unfiltered (bounded) listing, keyset pagination (full coverage, no gaps,
// no overlap, limit honored + clamped), and FTS query sanitization (arbitrary
// punctuation must NOT throw a malformed-MATCH error).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: search (P16/FTS5)")
struct ServicesSearchTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 640, height: 480, duration: nil, fileSize: 2048,
            downloadState: .downloaded)
    }

    @discardableResult
    private func ingest(
        _ services: AppServices, into c: UUID,
        hash: String, platform: Platform = .web,
        url: String? = nil, title: String? = nil,
        handle: String? = nil, name: String? = nil
    ) async throws -> IngestResult {
        let resolvedURL = url ?? (platform == .web ? "https://e/\(hash)" : nil)
        let source = SourceDraft(
            platform: platform, originalURL: resolvedURL, authorHandle: handle,
            authorName: name, title: title, capturedAt: Date())
        return try await services.ingest(assetDraft(hash: hash), from: source, into: c)
    }

    // MARK: FTS text match

    @Test("a source title token finds its asset; a non-matching token finds nothing")
    func ftsTitleMatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let brass = try await ingest(services, into: c.id, hash: "a1", title: "Brass Lamp")
        _ = try await ingest(services, into: c.id, hash: "b2", title: "Oak Chair")

        let hits = try await services.searchAssets(text: "brass")
        #expect(hits.map(\.asset.id) == [brass.asset.id])

        let miss = try await services.searchAssets(text: "zelkova")
        #expect(miss.isEmpty)
    }

    @Test("FTS matches author handle and author name too")
    func ftsAuthorMatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let byHandle = try await ingest(
            services, into: c.id, hash: "a1", title: "x", handle: "@designer")
        let byName = try await ingest(
            services, into: c.id, hash: "b2", title: "y", name: "Ada Lovelace")

        #expect(try await services.searchAssets(text: "designer").map(\.asset.id) == [byHandle.asset.id])
        #expect(try await services.searchAssets(text: "lovelace").map(\.asset.id) == [byName.asset.id])
    }

    @Test("a multi-term query ANDs the terms")
    func ftsMultiTerm() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let both = try await ingest(services, into: c.id, hash: "a1", title: "Brass Wood Table")
        _ = try await ingest(services, into: c.id, hash: "b2", title: "Brass Lamp")

        // "brass wood" → both terms must appear → only the first asset.
        let hits = try await services.searchAssets(text: "brass wood")
        #expect(hits.map(\.asset.id) == [both.asset.id])
    }

    // MARK: platform filter

    @Test("platform filter restricts to the source's platform")
    func platformFilter() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await ingest(services, into: c.id, hash: "a1", platform: .web, title: "w")
        let pin = try await ingest(
            services, into: c.id, hash: "b2", platform: .pinterest,
            url: "https://pinterest.com/p", title: "p")

        let hits = try await services.searchAssets(platform: .pinterest)
        #expect(hits.map(\.asset.id) == [pin.asset.id])
    }

    @Test("platform filter composes with text match")
    func platformPlusText() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Same title token on two platforms; filter narrows to one.
        _ = try await ingest(services, into: c.id, hash: "a1", platform: .web, title: "Sunset")
        let pin = try await ingest(
            services, into: c.id, hash: "b2", platform: .pinterest,
            url: "https://pinterest.com/p", title: "Sunset")

        let hits = try await services.searchAssets(text: "sunset", platform: .pinterest)
        #expect(hits.map(\.asset.id) == [pin.asset.id])
    }

    // MARK: text == nil lists all (bounded)

    @Test("text nil lists all assets, bounded by limit")
    func listAllBounded() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        for i in 0..<7 {
            _ = try await ingest(services, into: c.id, hash: String(format: "%02x", i), title: "t\(i)")
        }
        #expect(try await services.searchAssets().count == 7)
        #expect(try await services.searchAssets(limit: 3).count == 3)  // bounded
    }

    @Test("blank text is treated as no filter (lists all)")
    func blankTextListsAll() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await ingest(services, into: c.id, hash: "a1", title: "one")
        _ = try await ingest(services, into: c.id, hash: "b2", title: "two")
        #expect(try await services.searchAssets(text: "   ").count == 2)
    }

    // MARK: keyset pagination

    @Test("keyset pagination covers every row once, in order, no gaps or overlap")
    func keysetPagination() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let total = 13
        for i in 0..<total {
            _ = try await ingest(services, into: c.id, hash: String(format: "%04x", i), title: "t\(i)")
        }

        // The full ordering, fetched in one shot (limit covers all), is the oracle.
        let oracle = try await services.searchAssets(limit: 500).map(\.asset.id)
        #expect(oracle.count == total)

        // Page through with limit 4, following the cursor.
        let pageSize = 4
        var collected: [UUID] = []
        var cursor: AssetPageCursor? = nil
        var pages = 0
        while true {
            let page = try await services.searchAssets(limit: pageSize, after: cursor)
            if page.isEmpty { break }
            #expect(page.count <= pageSize)               // limit honored
            collected.append(contentsOf: page.map(\.asset.id))
            let last = page[page.count - 1].asset
            cursor = AssetPageCursor(createdAt: last.createdAt, id: last.id)
            pages += 1
            if page.count < pageSize { break }
            #expect(pages <= total)                       // termination guard
        }

        #expect(collected == oracle)                       // same order, full coverage
        #expect(Set(collected).count == collected.count)   // no overlap
        #expect(collected.count == total)                  // no gaps
    }

    @Test("limit is clamped to a sane range")
    func limitClamped() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        for i in 0..<5 {
            _ = try await ingest(services, into: c.id, hash: String(format: "%02x", i), title: "t\(i)")
        }
        // limit 0 / negative clamps UP to >= 1 (returns at least one row).
        #expect(try await services.searchAssets(limit: 0).count == 1)
        #expect(try await services.searchAssets(limit: -10).count == 1)
        // A huge limit clamps DOWN to <= 500 but still returns all 5 present.
        #expect(try await services.searchAssets(limit: 10_000).count == 5)
    }

    // MARK: FTS sanitization — arbitrary input must not throw

    @Test("punctuation, spaces, and stray quotes do not throw a malformed-MATCH error")
    func sanitizedQueryDoesNotThrow() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await ingest(services, into: c.id, hash: "a1", title: "Brass Wood")

        // None of these should throw; each just returns some (possibly empty) result.
        let nasty = [
            "brass wood", "   ", "\"", "a\"b", "(foo OR bar)",
            "NEAR(x y)", "co:lon", "-minus", "star*", "emoji 🔥 brass",
        ]
        for q in nasty {
            _ = try await services.searchAssets(text: q)
        }
        // And the well-formed phrase still finds the asset.
        #expect(try await services.searchAssets(text: "brass wood").count == 1)
    }
}
