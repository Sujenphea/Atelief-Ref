// AtelierCore — the library-stats reads (016 · A).
//
// Three aggregates over a MIXED fixture: counts by kind, counts by platform,
// and the per-blob usage rows the largest-items list ranks. What they pin is
// mostly about arithmetic honesty — one row per FILE (dedup collapses assets,
// not files), counts per ASSET (a ten-image carousel is ten items from
// Instagram, not one), and an ordering that doesn't move between two runs over
// an unchanged library.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: library stats (016 A)")
struct ServicesLibraryStatsTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func source(
        platform: Platform = .web, title: String? = nil, url: String? = nil
    ) -> SourceDraft {
        SourceDraft(
            platform: platform,
            originalURL: url ?? "https://example.com/\(UUID().uuidString)",
            title: title,
            capturedAt: Date())
    }

    /// Ingest one BYTE-BACKED asset, by default with its own source so 18A dedup
    /// never collapses two captures the fixture means to keep apart.
    @discardableResult
    private func seed(
        _ services: AppServices,
        into collection: UUID,
        kind: AssetKind = .image,
        hash: String,
        mime: String = "image/png",
        platform: Platform = .web,
        name: String? = nil,
        title: String? = nil,
        url: String? = nil
    ) async throws -> UUID {
        let draft = AssetDraft(
            kind: kind, blobHash: hash, mimeType: mime,
            width: 800, height: 600, fileSize: 4_096, downloadState: .downloaded)
        let id = try await services.ingest(
            draft, from: source(platform: platform, title: title, url: url),
            into: collection).asset.id
        if let name { try await services.setName(name, for: id) }
        return id
    }

    /// Ingest one MEDIA-LESS asset (003 · O1) — no blob, so it must never appear
    /// in the blob-usage rows.
    @discardableResult
    private func seedContent(
        _ services: AppServices, into collection: UUID,
        _ draft: AssetContentDraft, platform: Platform = .web
    ) async throws -> UUID {
        try await services.ingestContent(
            draft, from: source(platform: platform), into: collection).asset.id
    }

    // MARK: - Counts

    @Test("an empty library counts nothing at all")
    func emptyLibraryCounts() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }

        #expect(try await services.assetCountsByKind().isEmpty)
        #expect(try await services.assetCountsByPlatform().isEmpty)
        #expect(try await services.blobUsage().isEmpty)
    }

    @Test("counts by kind tally a mixed library, and omit the kinds with none")
    func countsByKind() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Mixed").id
        try await seed(services, into: c, hash: "aa11")
        try await seed(services, into: c, hash: "bb22")
        try await seed(services, into: c, hash: "cc33")
        try await seed(services, into: c, kind: .video, hash: "dd44", mime: "video/mp4")
        try await seedContent(
            services, into: c, .link(url: "https://a.example/1", title: "A"))

        let counts = try await services.assetCountsByKind()

        #expect(counts[.image] == 3)
        #expect(counts[.video] == 1)
        #expect(counts[.link] == 1)
        // Absent, not zero — the UI decides whether an empty kind gets a row.
        #expect(counts[.tweet] == nil)
        #expect(counts[.color] == nil)
    }

    @Test("counts by platform tally per ASSET, not per source")
    func countsByPlatform() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Mixed").id
        // One post, three images: three items from Instagram.
        let carousel = "https://instagram.com/p/abc"
        try await seed(services, into: c, hash: "aa11", platform: .instagram, url: carousel)
        try await seed(services, into: c, hash: "bb22", platform: .instagram, url: carousel)
        try await seed(services, into: c, hash: "cc33", platform: .instagram, url: carousel)
        try await seed(services, into: c, hash: "dd44", platform: .pinterest)
        try await seed(services, into: c, hash: "ee55", platform: .localDrag)

        let counts = try await services.assetCountsByPlatform()

        #expect(counts[.instagram] == 3)
        #expect(counts[.pinterest] == 1)
        #expect(counts[.localDrag] == 1)
        #expect(counts[.web] == nil)
    }

    @Test("kind and platform counts agree on the library's total")
    func countsAgree() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Mixed").id
        try await seed(services, into: c, hash: "aa11", platform: .twitter)
        try await seed(services, into: c, kind: .video, hash: "bb22",
                       mime: "video/mp4", platform: .cosmos)
        try await seed(services, into: c, hash: "cc33", platform: .localPaste)

        let byKind = try await services.assetCountsByKind().values.reduce(0, +)
        let byPlatform = try await services.assetCountsByPlatform().values.reduce(0, +)

        #expect(byKind == 3)
        #expect(byPlatform == byKind)
    }

    // MARK: - Blob usage

    @Test("blob usage is one row per FILE, ordered by hash")
    func blobUsageIsPerFile() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        try await seed(services, into: c, hash: "cc33")
        try await seed(services, into: c, hash: "aa11")
        try await seed(services, into: c, hash: "bb22")

        let usage = try await services.blobUsage()

        #expect(usage.map(\.blobHash) == ["aa11", "bb22", "cc33"])
        #expect(usage.allSatisfy { $0.assetCount == 1 })
    }

    @Test("a blob shared by several assets is ONE row carrying all of them")
    func sharedBlobCarriesEveryAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        // Same bytes, different provenance → two assets, one file on disk.
        let first = try await seed(services, into: c, hash: "d0be", url: "https://a.example/1")
        let second = try await seed(services, into: c, hash: "d0be", url: "https://b.example/2")

        let usage = try await services.blobUsage()

        #expect(usage.count == 1)
        #expect(usage[0].assetCount == 2)
        // Sorted, so the row is byte-identical between two reads.
        #expect(usage[0].assetIDs == [first, second].sorted { $0.uuidString < $1.uuidString })
    }

    @Test("media-less kinds are absent — they occupy no file to rank")
    func mediaLessKindsAreAbsent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        try await seed(services, into: c, hash: "aa11")
        try await seedContent(services, into: c, .color(hex: "#FF0000"))

        let usage = try await services.blobUsage()

        #expect(usage.map(\.blobHash) == ["aa11"])
    }

    @Test("the row carries the mime, kind and platform its file needs")
    func rowCarriesDescriptors() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        try await seed(services, into: c, kind: .video, hash: "aa11",
                       mime: "video/mp4", platform: .twitter)

        let usage = try await services.blobUsage()

        #expect(usage.count == 1)
        #expect(usage[0].mimeType == "video/mp4")
        #expect(usage[0].kind == .video)
        #expect(usage[0].platform == .twitter)
    }

    @Test("the display name is the asset's name, else the source title, else nil")
    func displayNameFallsBack() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        try await seed(services, into: c, hash: "aa11", name: "My Poster", title: "Post title")
        try await seed(services, into: c, hash: "bb22", title: "Only a title")
        try await seed(services, into: c, hash: "cc33")

        let usage = try await services.blobUsage()

        #expect(usage[0].displayName == "My Poster")
        #expect(usage[1].displayName == "Only a title")
        #expect(usage[2].displayName == nil)
    }

    @Test("two reads over an unchanged library return an identical list")
    func readsAreDeterministic() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs").id
        for marker in ["aa11", "bb22", "cc33", "dd44"] {
            try await seed(services, into: c, hash: marker)
        }

        #expect(try await services.blobUsage() == services.blobUsage())
    }
}
