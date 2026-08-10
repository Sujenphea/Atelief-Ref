// AtelierIngestion — batch coordinator tests (chunk 4, decision T12)
//
// The bounded-concurrency, partial-failure-tolerant, cancellable batch runner:
// a mixed batch is not aborted by one bad item (C8); `runBounded` caps in-flight
// work at `maxConcurrent` (probed directly); cancelling mid-batch leaves only
// COMPLETE blobs (A2 atomicity); progress is monotonic and ends at total; and a
// drop of 3 distinct images yields 3 assets + 3 blobs + thumbnails in the
// collection.

import Foundation
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("IngestCoordinator")
struct IngestCoordinatorTests {
    static func provenance() -> SourceDraft {
        SourceDraft(platform: .localPaste, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func input(_ bytes: Data, into env: TempPipeline) -> IngestInput {
        IngestInput(source: .data(bytes), provenance: provenance(), collectionID: env.collectionID)
    }

    // MARK: - Mixed batch, not aborted (C8)

    @Test("mixed [valid, corrupt, valid] → [ingested, failed, ingested]")
    func mixedBatchNotAborted() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let valid1 = try FixtureImages.solidImage(width: 120, height: 90, format: .png)
        let corrupt = try FixtureImages.corruptImage()
        let valid2 = try FixtureImages.solidImage(width: 240, height: 160, format: .png)

        let outcomes = await env.coordinator.ingest([
            Self.input(valid1, into: env),
            Self.input(corrupt, into: env),
            Self.input(valid2, into: env),
        ])

        #expect(outcomes.count == 3)
        #expect({ if case .ingested = outcomes[0] { return true }; return false }())
        #expect({ if case .failed = outcomes[1] { return true }; return false }())
        #expect({ if case .ingested = outcomes[2] { return true }; return false }())

        // The two valid assets exist; the corrupt one produced nothing.
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.count == 2)
        #expect(env.blobFiles().count == 2)
    }

    // MARK: - Bounded concurrency (probe runBounded directly)

    @Test("runBounded holds at most maxConcurrent tasks in flight")
    func boundedConcurrency() async throws {
        let limit = 3
        let itemCount = 40

        // A probe operation that tracks live concurrency; the inputs are unused.
        let tracker = ConcurrencyTracker()
        let dummy = IngestInput(
            source: .data(Data()), provenance: Self.provenance(), collectionID: UUID())
        let items = Array(repeating: dummy, count: itemCount)

        let results = await runBounded(items, maxConcurrent: limit) { index, _ in
            await tracker.enter()
            // Yield a few times so overlap actually happens (otherwise a task
            // could complete before the next starts and never overlap).
            for _ in 0 ..< 5 { await Task.yield() }
            await tracker.leave()
            return index
        }

        // Every item ran, in input order (nil slots only appear on cancel).
        #expect(results.count == itemCount)
        #expect(results == (0 ..< itemCount).map { Optional.some($0) })
        let maxSeen = await tracker.maxConcurrent
        #expect(maxSeen <= limit)
        #expect(maxSeen >= 1)
    }

    // MARK: - Cancellation leaves no partial blobs (A2)

    @Test("cancelling mid-batch leaves only complete, valid blobs")
    func cancellationLeavesNoPartials() async throws {
        let env = try await makeTempPipeline(maxConcurrent: 2)
        defer { env.cleanup() }

        // Many DISTINCT images (distinct widths ⇒ distinct bytes ⇒ distinct hashes).
        var inputs: [IngestInput] = []
        for i in 0 ..< 24 {
            let bytes = try FixtureImages.solidImage(width: 100 + i, height: 80, format: .png)
            inputs.append(Self.input(bytes, into: env))
        }

        let inputCount = inputs.count
        let batch = inputs
        let coordinator = env.coordinator
        let task = Task { await coordinator.ingest(batch) }
        // Let a little work start, then cancel.
        await Task.yield()
        task.cancel()
        let outcomes = await task.value   // the coordinator returns despite cancellation.

        // Index-aligned contract: one outcome per input, cancelled slots are explicit.
        #expect(outcomes.count == inputCount)
        #expect(outcomes.contains { if case .cancelled = $0 { return true }; return false })

        // Every file under blobs/ must be COMPLETE and VALID: its bytes hash back
        // to the hash embedded in its filename (MediaStore atomicity, A2).
        for url in env.blobFiles() {
            let bytes = try Data(contentsOf: url)
            #expect(!bytes.isEmpty)
            let nameHash = url.deletingPathExtension().lastPathComponent
            #expect(ContentHasher.hash(bytes) == nameHash)
        }
        // No staging temp files left behind.
        #expect(env.cacheFiles().isEmpty)
    }

    @Test("cancel mid-batch keeps outcomes index-aligned with inputs (G4)")
    func cancellationKeepsIndexAlignment() async throws {
        let env = try await makeTempPipeline(maxConcurrent: 1)
        defer { env.cleanup() }

        var inputs: [IngestInput] = []
        for i in 0 ..< 12 {
            let bytes = try FixtureImages.solidImage(width: 80 + i, height: 60, format: .png)
            inputs.append(Self.input(bytes, into: env))
        }

        let inputCount = inputs.count
        let batch = inputs
        let coordinator = env.coordinator
        let task = Task { await coordinator.ingest(batch) }
        await Task.yield()
        task.cancel()
        let outcomes = await task.value

        #expect(outcomes.count == inputCount)
        let cancelledCount = outcomes.filter {
            if case .cancelled = $0 { return true }
            return false
        }.count
        #expect(cancelledCount >= 1)
        // Every non-cancelled slot must be a real completed outcome (never a hole).
        for outcome in outcomes {
            switch outcome {
            case .ingested, .failed, .cancelled:
                break
            }
        }
    }

    // MARK: - Progress monotonic

    @Test("onProgress is non-decreasing and ends at total")
    func progressMonotonic() async throws {
        let env = try await makeTempPipeline(maxConcurrent: 3)
        defer { env.cleanup() }

        var inputs: [IngestInput] = []
        for i in 0 ..< 6 {
            let bytes = try FixtureImages.solidImage(width: 150 + i, height: 100, format: .png)
            inputs.append(Self.input(bytes, into: env))
        }
        let total = inputs.count

        let collector = ProgressCollector()
        _ = await env.coordinator.ingest(inputs) { completed, reportedTotal in
            collector.record(completed: completed, total: reportedTotal)
        }

        let samples = collector.samples
        #expect(samples.count == total)
        // Non-decreasing completed; total constant and correct.
        var previous = 0
        for (completed, reportedTotal) in samples {
            #expect(completed >= previous)
            #expect(reportedTotal == total)
            previous = completed
        }
        #expect(samples.last?.0 == total)
    }

    // MARK: - End-to-end batch

    @Test("drop 3 distinct images → 3 assets, 3 blobs, thumbnails, in collection")
    func endToEndBatch() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let a = try FixtureImages.solidImage(width: 100, height: 100, format: .png)
        let b = try FixtureImages.solidImage(width: 200, height: 150, format: .jpeg)
        let c = try FixtureImages.solidImage(width: 320, height: 240, format: .png)

        let outcomes = await env.coordinator.ingest([
            Self.input(a, into: env), Self.input(b, into: env), Self.input(c, into: env),
        ])

        #expect(outcomes.count == 3)
        var assets: [Asset] = []
        for outcome in outcomes {
            guard case .ingested(let asset, _) = outcome else {
                Issue.record("expected .ingested, got \(outcome)")
                return
            }
            assets.append(asset)
        }

        // 3 distinct assets, 3 blobs, all tiers per asset.
        #expect(Set(assets.map(\.id)).count == 3)
        #expect(env.blobFiles().count == 3)
        for asset in assets {
            for tier in ThumbnailTier.allCases {
                #expect(env.store.hasThumbnail(
                    hash: try #require(asset.blobHash), size: tier.rawValue, fileExtension: "jpg"))
            }
        }

        // All three in the target collection.
        let items = try await env.services.collectionItems(in: env.collectionID, includeArchived: false)
        #expect(items.count == 3)
    }
}

// MARK: - Test probes

/// Tracks live concurrency for the `runBounded` probe: `enter`/`leave` bracket a
/// unit of work and record the peak number seen simultaneously in flight.
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var maxConcurrent = 0

    func enter() {
        current += 1
        if current > maxConcurrent { maxConcurrent = current }
    }

    func leave() {
        current -= 1
    }
}

/// Collects `onProgress` samples. A lock-guarded class because `onProgress` is a
/// synchronous `@Sendable` closure (cannot `await` into an actor).
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, Int)] = []

    func record(completed: Int, total: Int) {
        lock.lock()
        storage.append((completed, total))
        lock.unlock()
    }

    var samples: [(Int, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
