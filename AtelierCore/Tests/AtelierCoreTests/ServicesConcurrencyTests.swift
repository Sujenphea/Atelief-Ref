// AtelierCore — App Services concurrency tests (chunk 5, decision T12)
//
// Verifies the reason we chose `DatabasePool`/WAL (A3): concurrent reads during
// writes succeed, and the concurrent identical-ingest race resolves to ONE asset
// (the serialized writer means the second ingest's 18A dedup lookup sees the
// first). Without these, the cost of Pool over Queue would be unproven.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Services: concurrency (T12)")
struct ServicesConcurrencyTests {

    private func assetDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
    }
    private func source() -> SourceDraft {
        SourceDraft(platform: .web, originalURL: "https://example.com/same", capturedAt: Date())
    }

    @Test("many concurrent writes all land; concurrent reads never lock")
    func concurrentWritesAndReads() async throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let services = AppServices(database: temp.database)
        let collection = try await services.createCollection(name: "C")

        // 20 distinct assets ingested concurrently, interleaved with reads.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    _ = try await services.ingest(
                        self.assetDraft(hash: String(format: "%08x", i)),
                        from: SourceDraft(
                            platform: .web,
                            originalURL: "https://example.com/\(i)",
                            capturedAt: Date()),
                        into: collection.id)
                }
                // A concurrent reader running against the WAL snapshot.
                group.addTask {
                    _ = try temp.database.read { db in try Asset.fetchCount(db) }
                }
            }
            try await group.waitForAll()
        }

        let assets = try temp.database.read { db in try Asset.fetchCount(db) }
        let items = try temp.database.read { db in try CollectionItem.fetchCount(db) }
        #expect(assets == 20) // every serialized write committed
        #expect(items == 20)
    }

    @Test("concurrent identical ingests resolve to ONE asset (18A under WAL)")
    func concurrentIdenticalIngestRace() async throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let services = AppServices(database: temp.database)
        let collection = try await services.createCollection(name: "C")

        // Fire the SAME bytes + provenance into the SAME collection from many
        // tasks at once. The serialized writer means exactly one creates the
        // asset; the rest dedup against it.
        let results = try await withThrowingTaskGroup(of: IngestResult.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await services.ingest(
                        self.assetDraft(hash: "cafebabe"),
                        from: self.source(),
                        into: collection.id)
                }
            }
            var collected: [IngestResult] = []
            for try await r in group { collected.append(r) }
            return collected
        }

        // Exactly one creation, the rest deduped — and one asset + one membership.
        let created = results.filter { !$0.wasDeduplicated }.count
        #expect(created == 1)
        let ids = Set(results.map(\.asset.id))
        #expect(ids.count == 1) // all tasks resolved to the same asset
        let assets = try temp.database.read { db in try Asset.fetchCount(db) }
        let items = try temp.database.read { db in try CollectionItem.fetchCount(db) }
        #expect(assets == 1)
        #expect(items == 1)
    }
}
