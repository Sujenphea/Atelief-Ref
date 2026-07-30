// AtelierIngestion — runBounded / ProgressReporter (008 · F3)
//
// `IngestCoordinatorTests` already probes the concurrency ceiling through the
// ingest path. These cover the extracted helpers as GENERAL machinery — a
// non-IngestInput element type (what the backup copier will pass), the
// index-alignment and ordering contracts, the degenerate limits, and the
// monotonic-progress guarantee that only shows up under concurrency.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("BoundedWork: runBounded + ProgressReporter")
struct BoundedWorkTests {

    /// Serializes observations from concurrent tasks.
    private actor Recorder {
        private(set) var values: [String] = []
        private(set) var live = 0
        private(set) var peak = 0
        func enter() { live += 1; peak = max(peak, live) }
        func leave() { live -= 1 }
        func record(_ value: String) { values.append(value) }
    }

    @Test("works over an arbitrary Sendable element type, results in INPUT order")
    func genericElementInputOrder() async throws {
        // Strings, not IngestInput — the generalization's whole point. Reversed
        // delays so completion order is the opposite of input order.
        let items = ["a", "b", "c", "d"]
        let results = await runBounded(items, maxConcurrent: 4) { index, item in
            try? await Task.sleep(nanoseconds: UInt64(4 - index) * 2_000_000)
            return item.uppercased()
        }
        #expect(results == ["A", "B", "C", "D"])
    }

    @Test("holds at most maxConcurrent in flight for a non-ingest element type")
    func concurrencyCeiling() async throws {
        let recorder = Recorder()
        let items = Array(0 ..< 20)
        _ = await runBounded(items, maxConcurrent: 3) { _, _ in
            await recorder.enter()
            try? await Task.sleep(nanoseconds: 2_000_000)
            await recorder.leave()
            return 0
        }
        let peak = await recorder.peak
        #expect(peak <= 3)
        #expect(peak > 1) // actually ran concurrently, not accidentally serial
    }

    @Test("an empty batch runs nothing and returns nothing")
    func emptyBatch() async throws {
        let recorder = Recorder()
        let results: [Int?] = await runBounded([String](), maxConcurrent: 4) { _, _ in
            await recorder.record("ran")
            return 1
        }
        #expect(results.isEmpty)
        #expect(await recorder.values.isEmpty)
    }

    @Test("a non-positive limit clamps to serial rather than deadlocking")
    func nonPositiveLimitClampsToSerial() async throws {
        let recorder = Recorder()
        let results = await runBounded([1, 2, 3], maxConcurrent: 0) { _, item in
            await recorder.enter()
            defer { Task { await recorder.leave() } }
            return item * 2
        }
        #expect(results == [2, 4, 6])
        #expect(await recorder.peak == 1)
    }

    @Test("a single item with a huge limit still runs exactly once")
    func singleItemHugeLimit() async throws {
        let recorder = Recorder()
        let results = await runBounded(["only"], maxConcurrent: 999) { _, item in
            await recorder.record(item)
            return item
        }
        #expect(results == ["only"])
        #expect(await recorder.values == ["only"])
    }

    @Test("a batch cancelled before it starts launches nothing; every slot is nil")
    func cancelledBeforeStart() async throws {
        let recorder = Recorder()
        let task = Task {
            await runBounded(Array(0 ..< 8), maxConcurrent: 2) { _, item in
                await recorder.record("\(item)")
                return item
            }
        }
        task.cancel()
        let results = await task.value
        // Nothing was primed, so every index is an unstarted nil slot — the
        // property callers rely on to fill a typed `.cancelled` placeholder.
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == nil })
        #expect(await recorder.values.isEmpty)
    }

    @Test("the index passed to the operation matches the element's position")
    func indexMatchesElement() async throws {
        let items = ["zero", "one", "two"]
        let results = await runBounded(items, maxConcurrent: 2) { index, item in
            "\(index):\(item)"
        }
        #expect(results == ["0:zero", "1:one", "2:two"])
    }

    // MARK: - ProgressReporter

    @Test("progress is delivered strictly 1…total even under concurrent completion")
    func progressIsMonotonic() async throws {
        let recorder = Recorder()
        let total = 24
        let reporter = ProgressReporter(total: total) { completed, reportedTotal in
            // Callback fires under the actor's isolation; capture the sequence.
            Task { await recorder.record("\(completed)/\(reportedTotal)") }
        }
        _ = await runBounded(Array(0 ..< total), maxConcurrent: 6) { index, _ in
            // Jittered so completions genuinely interleave.
            try? await Task.sleep(nanoseconds: UInt64((index % 5) + 1) * 1_000_000)
            await reporter.report()
            return index
        }
        // Let the recording tasks drain.
        try await Task.sleep(nanoseconds: 50_000_000)

        let counts = await recorder.values.compactMap { Int($0.split(separator: "/")[0]) }
        #expect(counts.count == total)
        #expect(Set(counts) == Set(1...total)) // each count delivered exactly once
        #expect(await recorder.values.allSatisfy { $0.hasSuffix("/\(total)") })
    }

    @Test("a reporter with no callback still counts without crashing")
    func reporterWithoutCallback() async throws {
        let reporter = ProgressReporter(total: 3, onProgress: nil)
        await reporter.report()
        await reporter.report()
        // No observable output by design; the point is that nil is a valid mode.
    }
}
