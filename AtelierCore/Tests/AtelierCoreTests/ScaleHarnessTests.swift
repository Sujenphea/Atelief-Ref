//
//  ScaleHarnessTests.swift
//  AtelierCoreTests
//
//  010 · Phase 3 — a runnable scale-seeding + timing harness. Seeds N assets into
//  a temp library and times the hot library reads (collection listing + FTS
//  search). The DEFAULT N is small so CI stays fast; a developer bumps it for a
//  real pass:
//
//      ATELIER_SCALE_N=20000 swift test --filter ScaleHarness
//
//  It asserts CORRECTNESS at scale (no latency assertions — those would flake in
//  CI); the printed timings are the measurement. The full 10k–50k Instruments /
//  grid-scroll pass still runs on a dev machine (the app UI isn't exercised here).
//

import Foundation
import Testing
@testable import AtelierCore

@Suite("ScaleHarness")
struct ScaleHarnessTests {

    /// Seed count — env-overridable so CI runs a tiny smoke while a developer can
    /// drive a real 10k–50k pass without editing code.
    private var seedCount: Int {
        if let raw = ProcessInfo.processInfo.environment["ATELIER_SCALE_N"],
           let n = Int(raw), n > 0 { return n }
        return 300
    }

    @Test("seed N assets, then time the collection listing + FTS search")
    func seedAndTimeReads() async throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let services = AppServices(database: temp.database)
        let c = try await services.createCollection(name: "Scale")
        let n = seedCount

        // Seed: N byte-backed assets, each with a distinct hash + a searchable
        // title token ("ref<i>") plus a shared token ("swatch") for a broad match.
        let seedStart = ContinuousClock.now
        for i in 0..<n {
            let source = SourceDraft(
                platform: .web, originalURL: "https://e/\(i)",
                authorHandle: nil, authorName: nil,
                title: "ref\(i) swatch", capturedAt: Date())
            let draft = AssetDraft(
                kind: .image, blobHash: String(format: "%040x", i), mimeType: "image/png",
                width: 640, height: 480, duration: nil, fileSize: 2048,
                downloadState: .downloaded)
            _ = try await services.ingest(draft, from: source, into: c.id)
        }
        let seedElapsed = ContinuousClock.now - seedStart

        // Time: the full collection listing (P16 returns the whole array).
        let listStart = ContinuousClock.now
        let items = try await services.collectionItems(in: c.id, includeArchived: false)
        let listElapsed = ContinuousClock.now - listStart
        #expect(items.count == n)

        // Time: a single-token FTS search (paged; the shared token matches all).
        let searchStart = ContinuousClock.now
        let hits = try await services.searchAssets(text: "swatch", limit: 50)
        let searchElapsed = ContinuousClock.now - searchStart
        #expect(!hits.isEmpty)

        // A specific token resolves to exactly one asset even at scale.
        let one = try await services.searchAssets(text: "ref\(n - 1)")
        #expect(one.count == 1)

        // The shelf (023 · A). Archive a QUARTER of the library, then time the
        // three reads the shelf changes:
        //
        //   • `shelfAssets` — the one genuinely new cost. Library-wide
        //     `archived_at IS NOT NULL` with a sort and NO collection scope, and
        //     the read whose row count only ever grows. It deliberately returns
        //     the full array with no cursor in v1; this number is what decides
        //     whether that stays true, which is the whole reason it is measured
        //     here rather than argued about.
        //   • `collectionItems` again — the browse read now carries the
        //     predicate, so the delta against the un-archived timing above is
        //     what the hot path actually pays.
        //   • `searchAssets` again — same question for the FTS path, where the
        //     conjunct sits alongside the MATCH.
        let toArchive = try await services.collectionItems(in: c.id, includeArchived: false)
            .prefix(n / 4)
            .map(\.asset.id)
        let archiveStart = ContinuousClock.now
        let archivedCount = try await services.archive(Array(toArchive))
        let archiveElapsed = ContinuousClock.now - archiveStart
        #expect(archivedCount == toArchive.count)

        let shelfStart = ContinuousClock.now
        let shelf = try await services.shelfAssets()
        let shelfElapsed = ContinuousClock.now - shelfStart
        #expect(shelf.count == toArchive.count)

        let listAfterStart = ContinuousClock.now
        let remaining = try await services.collectionItems(in: c.id, includeArchived: false)
        let listAfterElapsed = ContinuousClock.now - listAfterStart
        #expect(remaining.count == n - toArchive.count)

        let searchAfterStart = ContinuousClock.now
        let hitsAfter = try await services.searchAssets(text: "swatch", limit: 50)
        let searchAfterElapsed = ContinuousClock.now - searchAfterStart
        #expect(hitsAfter.allSatisfy { $0.asset.archivedAt == nil })

        print("""
        [scale] N=\(n)
          seed:            \(ms(seedElapsed)) ms  (\(ms(seedElapsed) / Double(n)) ms/asset)
          collectionItems: \(ms(listElapsed)) ms  (\(items.count) rows)
          search 'swatch': \(ms(searchElapsed)) ms  (page of \(hits.count))
        [scale] archived=\(shelf.count) of \(n)
          archive:         \(ms(archiveElapsed)) ms  (one UPDATE)
          shelfAssets:     \(ms(shelfElapsed)) ms  (\(shelf.count) rows, no cursor)
          collectionItems: \(ms(listAfterElapsed)) ms  (\(remaining.count) rows, predicate on)
          search 'swatch': \(ms(searchAfterElapsed)) ms  (page of \(hitsAfter.count))
        """)
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1_000_000_000_000_000
    }
}
