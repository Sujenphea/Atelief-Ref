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
        let items = try await services.collectionItems(in: c.id)
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

        print("""
        [scale] N=\(n)
          seed:            \(ms(seedElapsed)) ms  (\(ms(seedElapsed) / Double(n)) ms/asset)
          collectionItems: \(ms(listElapsed)) ms  (\(items.count) rows)
          search 'swatch': \(ms(searchElapsed)) ms  (page of \(hits.count))
        """)
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1_000_000_000_000_000
    }
}
