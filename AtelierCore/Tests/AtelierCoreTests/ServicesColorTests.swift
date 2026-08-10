// AtelierCore — the color bucket store and its search conjunct (085 · C1)
//
// Three layers, failing for different reasons:
//   1. The WRITE contract — `replaceColors` is a replacement, not an append, and
//      the table's composite key only holds if the caller cannot pass a bucket
//      twice (hence the dictionary).
//   2. The BACKFILL queue — "has colors, has no buckets" is the entire state,
//      so the cases are about what must and must not appear in it.
//   3. The CONJUNCT — the properties that separate a WHERE clause from a
//      post-filter: pages stay full length, and an asset matching two of the
//      requested colors comes back ONCE.
//
// Bucket values here are raw integers on purpose. This layer does not know what
// a color is, and the tests must not pretend otherwise — `ColorPalette` lives in
// AtelierIngestion and is tested there.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: color buckets and the color conjunct (085 · C1)")
struct ServicesColorTests {

    // Stand-ins for palette entries. Named so the intent reads, numbered to
    // match `ColorBucket`'s raw values without importing it.
    private let red = 3
    private let orange = 4
    private let green = 7
    private let blue = 9

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

    // MARK: - Write

    @Test("colors round-trip, most-covering first")
    func roundTripOrderedByCoverage() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        try await services.replaceColors(assetID: asset, buckets: [red: 0.2, blue: 0.5, green: 0.3], paletteVersion: 1)
        let stored = try await services.colors(for: asset)
        #expect(stored.map(\.bucket) == [blue, green, red])
        #expect(stored.first?.coverage == 0.5)
    }

    /// The detail page's swatch row must not reshuffle between reads of data
    /// that did not change, so equal coverage falls back to the bucket value.
    @Test("equal coverage orders by bucket, deterministically")
    func tiesOrderByBucket() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        try await services.replaceColors(assetID: asset, buckets: [blue: 0.25, red: 0.25, green: 0.25], paletteVersion: 1)
        for _ in 0..<5 {
            let stored = try await services.colors(for: asset)
            #expect(stored.map(\.bucket) == [red, green, blue])
        }
    }

    /// A re-derivation must not leave a bucket the asset no longer has. Append
    /// semantics would accumulate every palette the analyzer ever produced.
    @Test("replaceColors REPLACES — a dropped bucket does not survive")
    func replaceIsWholesale() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        try await services.replaceColors(assetID: asset, buckets: [red: 0.6, blue: 0.4], paletteVersion: 1)
        try await services.replaceColors(assetID: asset, buckets: [green: 1.0], paletteVersion: 1)
        let stored = try await services.colors(for: asset)
        #expect(stored.map(\.bucket) == [green])
    }

    @Test("an empty dictionary clears the asset's rows")
    func emptyClears() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)

        try await services.replaceColors(assetID: asset, buckets: [red: 1.0], paletteVersion: 1)
        try await services.replaceColors(assetID: asset, buckets: [:], paletteVersion: 1)
        #expect(try await services.colors(for: asset).isEmpty)
    }

    @Test("writing colors for a missing asset throws notFound")
    func unknownAssetThrows() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.self) {
            try await services.replaceColors(
                assetID: UUID(), buckets: [self.red: 1.0], paletteVersion: 1)
        }
    }

    // MARK: - The backfill queue

    @Test("the queue holds assets with colors and no buckets, and drops them once filed")
    func queueDrainsAsItIsFilled() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)
        try await services.upsertAnalysis(
            assetID: asset, colors: ##"[{"hex":"#ff0000","coverage":1.0}]"##,
            analyzerVersion: 1)

        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: 1) == [asset])
        try await services.replaceColors(assetID: asset, buckets: [red: 1.0], paletteVersion: 1)
        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: 1).isEmpty)
    }

    /// No `colors` means nothing to derive from. Such an asset must not sit in
    /// the queue forever, being handed out and never satisfiable.
    @Test("an analyzed asset with NULL colors is not queued")
    func nullColorsIsNotQueued() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)
        try await services.upsertAnalysis(assetID: asset, colors: nil, analyzerVersion: 1)

        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: 1).isEmpty)
    }

    @Test("an un-analyzed asset is not queued")
    func unanalyzedIsNotQueued() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        try await seedAsset(services, into: refs.id)

        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: 1).isEmpty)
    }

    /// Archive hides an item; it does not exempt it from being indexed. If the
    /// shelf were skipped here, unarchiving would leave a permanent hole in the
    /// color filter that nothing would ever fill.
    @Test("an ARCHIVED asset is still queued")
    func archivedIsStillQueued() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: refs.id)
        try await services.upsertAnalysis(
            assetID: asset, colors: ##"[{"hex":"#ff0000","coverage":1.0}]"##,
            analyzerVersion: 1)
        try await services.archive([asset])

        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: 1) == [asset])
    }

    @Test("the queue respects its limit")
    func queueRespectsLimit() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        for _ in 0..<5 {
            let asset = try await seedAsset(services, into: refs.id)
            try await services.upsertAnalysis(
                assetID: asset, colors: ##"[{"hex":"#ff0000","coverage":1.0}]"##,
                analyzerVersion: 1)
        }
        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: 1, limit: 2).count == 2)
        #expect(try await services.assetIDsNeedingColorBuckets(paletteVersion: 1, limit: 0).count == 1,
                "clamped to at least 1")
    }

    // MARK: - The conjunct

    /// Seed `count` assets each carrying `bucket` at `coverage`.
    @discardableResult
    private func seedColored(
        _ services: AppServices, into collectionID: UUID,
        buckets: [Int: Double], title: String? = nil
    ) async throws -> UUID {
        let asset = try await seedAsset(services, into: collectionID, title: title)
        try await services.replaceColors(
            assetID: asset, buckets: buckets, paletteVersion: 1)
        return asset
    }

    @Test("the default match is ANY of the requested colors")
    func anyMatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let reddish = try await seedColored(services, into: refs.id, buckets: [red: 0.8])
        let bluish = try await seedColored(services, into: refs.id, buckets: [blue: 0.8])
        try await seedColored(services, into: refs.id, buckets: [green: 0.8])

        let hits = try await services.searchAssets(colorBuckets: [red, blue]).map(\.asset.id)
        #expect(Set(hits) == Set([reddish, bluish]))
    }

    @Test("ALL requires every requested color")
    func allMatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let both = try await seedColored(
            services, into: refs.id, buckets: [red: 0.5, blue: 0.5])
        try await seedColored(services, into: refs.id, buckets: [red: 0.9])

        let hits = try await services.searchAssets(
            colorBuckets: [red, blue], colorMatch: .all).map(\.asset.id)
        #expect(hits == [both])
    }

    /// A color merely PRESENT is not a color the image is. Without the floor,
    /// a 3% accent makes every photograph match every chip.
    @Test("a color below the coverage floor does not match")
    func coverageFloorExcludes() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let dominant = try await seedColored(services, into: refs.id, buckets: [red: 0.9])
        try await seedColored(services, into: refs.id, buckets: [red: 0.03])

        let hits = try await services.searchAssets(colorBuckets: [red]).map(\.asset.id)
        #expect(hits == [dominant])
    }

    @Test("the floor is a parameter, so a caller can widen it")
    func floorIsTunable() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let faint = try await seedColored(services, into: refs.id, buckets: [red: 0.03])

        #expect(try await services.searchAssets(colorBuckets: [red]).isEmpty)
        let widened = try await services.searchAssets(
            colorBuckets: [red], minimumColorCoverage: 0.01).map(\.asset.id)
        #expect(widened == [faint])
    }

    /// EXISTS rather than a JOIN. A join against a multi-row side multiplies the
    /// result, and an asset that is both red and blue would come back twice from
    /// a search for red-or-blue — a duplicate tile in the grid.
    @Test("an asset matching TWO requested colors is returned once")
    func noDuplicateRows() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let both = try await seedColored(
            services, into: refs.id, buckets: [red: 0.5, blue: 0.5])

        let hits = try await services.searchAssets(colorBuckets: [red, blue]).map(\.asset.id)
        #expect(hits == [both])
    }

    @Test("a duplicated bucket in the request changes nothing")
    func duplicateRequestIsHarmless() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let asset = try await seedColored(services, into: refs.id, buckets: [red: 0.8])

        let hits = try await services.searchAssets(
            colorBuckets: [red, red, red]).map(\.asset.id)
        #expect(hits == [asset])
    }

    @Test("no color filter returns everything, colored or not")
    func emptyFilterIsInert() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        try await seedColored(services, into: refs.id, buckets: [red: 0.8])
        try await seedAsset(services, into: refs.id)

        #expect(try await services.searchAssets(colorBuckets: []).count == 2)
        #expect(try await services.searchAssets().count == 2)
    }

    /// The conjunct rides the same query as every other predicate, so it must
    /// inherit the archive rule rather than re-open a hole in it (023 · A1).
    @Test("an archived asset never matches a color search")
    func archivedNeverMatches() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let shelved = try await seedColored(services, into: refs.id, buckets: [red: 0.9])
        let visible = try await seedColored(services, into: refs.id, buckets: [red: 0.9])

        try await services.archive([shelved])
        let hits = try await services.searchAssets(colorBuckets: [red]).map(\.asset.id)
        #expect(hits == [visible])
    }

    @Test("color composes with free text rather than replacing it")
    func composesWithText() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let wanted = try await seedColored(
            services, into: refs.id, buckets: [red: 0.9], title: "sunset ridge")
        try await seedColored(services, into: refs.id, buckets: [red: 0.9], title: "blue door")
        try await seedColored(
            services, into: refs.id, buckets: [green: 0.9], title: "sunset field")

        let hits = try await services.searchAssets(
            text: "sunset", colorBuckets: [red]).map(\.asset.id)
        #expect(hits == [wanted])
    }

    /// The whole reason this is a WHERE conjunct. A post-filter would hand back
    /// a short page and the keyset cursor would then page through the gaps.
    @Test("a filtered page is FULL length, not shortened after the fetch")
    func pagesAreNotShortened() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        // Interleave so a post-filter over a page of 5 would visibly shorten it.
        for index in 0..<12 {
            try await seedColored(
                services, into: refs.id,
                buckets: index.isMultiple(of: 2) ? [red: 0.9] : [green: 0.9])
        }
        let page = try await services.searchAssets(colorBuckets: [red], limit: 5)
        #expect(page.count == 5)

        let cursor = try #require(page.last.map {
            AssetPageCursor(createdAt: $0.asset.createdAt, id: $0.asset.id)
        })
        let next = try await services.searchAssets(
            colorBuckets: [red], limit: 5, after: cursor)
        #expect(next.count == 1, "6 red assets total: 5 then 1")
        #expect(Set(page.map(\.asset.id)).isDisjoint(with: Set(next.map(\.asset.id))))
    }
}
