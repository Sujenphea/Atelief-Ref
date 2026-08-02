// AtelierIngestion — the storage scan + the pure stats aggregation (016 · A).
//
// The scan's contract is arithmetic, so these assert EXACT byte totals over
// blobs of known size rather than "roughly right" — a size pane whose figures
// are approximately correct is a size pane nobody believes.
//
// The two adversarial cases the 016 risks section names get their own tests:
// the user emptying the Trash while the scan runs (a file vanishing between
// enumeration and `stat`), and restoring from it (a file reappearing). Both are
// things a user does, not error conditions, so neither may crash and neither
// may produce a total that includes bytes which aren't there.

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("Library storage scan (016 A)")
struct LibraryStorageScanTests {

    /// A 64-hex content hash whose first four chars shard it (`ab/cd/…`).
    private func hash(_ marker: String) -> String {
        let padded = marker + String(repeating: "0", count: max(0, 64 - marker.count))
        return String(padded.prefix(64))
    }

    /// Store a blob of EXACTLY `bytes` bytes.
    @discardableResult
    private func seedBlob(
        _ lib: TempLibrary, hash: String, bytes: Int, ext: String = "png"
    ) throws -> URL {
        try lib.store.storeBlob(
            Data(repeating: 0x41, count: bytes), hash: hash, fileExtension: ext)
    }

    private func seedThumbnail(
        _ lib: TempLibrary, hash: String, tier: ThumbnailTier, bytes: Int
    ) throws {
        try lib.store.storeThumbnail(
            Data(repeating: 0x42, count: bytes),
            hash: hash, size: tier.rawValue, fileExtension: "jpg")
    }

    private func scanner(_ lib: TempLibrary) -> LibraryStorageScanner {
        LibraryStorageScanner(layout: lib.layout)
    }

    // MARK: - Exact totals

    @Test("an empty library measures zero everywhere, and doesn't throw")
    func emptyLibrary() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let scan = try scanner(lib).scan()

        #expect(scan.usage == LibraryStorageUsage())
        #expect(scan.usage.totalBytes == 0)
        #expect(scan.blobSizes.isEmpty)
    }

    @Test("blob bytes total EXACTLY the seeded sizes, and are keyed by hash")
    func exactBlobTotals() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlob(lib, hash: hash("aa"), bytes: 1_000)
        try seedBlob(lib, hash: hash("bb"), bytes: 2_500)
        try seedBlob(lib, hash: hash("cc"), bytes: 40)

        let scan = try scanner(lib).scan()

        #expect(scan.usage.blobBytes == 3_540)
        #expect(scan.usage.blobFileCount == 3)
        #expect(scan.blobSizes[hash("aa")] == 1_000)
        #expect(scan.blobSizes[hash("bb")] == 2_500)
        #expect(scan.blobSizes[hash("cc")] == 40)
    }

    @Test("blobs, thumbnails, cache and snapshots are measured SEPARATELY")
    func tiersAreMeasuredApart() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlob(lib, hash: hash("aa"), bytes: 8_000)
        try seedThumbnail(lib, hash: hash("aa"), tier: .small, bytes: 100)
        try seedThumbnail(lib, hash: hash("aa"), tier: .medium, bytes: 300)
        try seedThumbnail(lib, hash: hash("aa"), tier: .large, bytes: 600)
        // Cache + snapshots are written directly: no store API produces them.
        try FileManager.default.createDirectory(
            at: lib.layout.cache, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 50).write(
            to: lib.layout.cache.appendingPathComponent("staged"))
        try FileManager.default.createDirectory(
            at: lib.layout.snapshots, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 70).write(
            to: lib.layout.snapshots.appendingPathComponent("snap.sqlite"))

        let scan = try scanner(lib).scan()

        #expect(scan.usage.blobBytes == 8_000)
        #expect(scan.usage.thumbnailBytes == 1_000)
        #expect(scan.usage.thumbnailFileCount == 3)
        #expect(scan.usage.cacheBytes == 50)
        #expect(scan.usage.snapshotBytes == 70)
        // The separation's whole purpose: the regenerable figure.
        #expect(scan.usage.regenerableBytes == 1_050)
        #expect(scan.usage.irreplaceableBytes == 8_070)
        #expect(scan.usage.totalBytes == 9_120)
    }

    @Test("the database and its sidecars are measured as one unit")
    func databaseTierIncludesSidecars() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        let base = lib.root.appendingPathComponent("library.sqlite")
        try Data(repeating: 0x45, count: 4_096).write(to: base)
        try Data(repeating: 0x46, count: 512).write(
            to: lib.root.appendingPathComponent("library.sqlite-wal"))

        let scan = try scanner(lib).scan()

        #expect(scan.usage.databaseBytes == 4_608)
        #expect(base.isFileURL)
    }

    @Test("the database file is NOT counted as a blob (it lives above the tiers)")
    func databaseIsNotABlob() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try Data(repeating: 0x45, count: 4_096).write(
            to: lib.root.appendingPathComponent("library.sqlite"))

        let scan = try scanner(lib).scan()

        #expect(scan.usage.blobBytes == 0)
        #expect(scan.blobSizes.isEmpty)
    }

    // MARK: - A library that moves under the scan (016 risks)

    @Test("a blob deleted mid-scan is SKIPPED — no crash, and no phantom bytes")
    func blobDeletedMidScanIsSkipped() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlob(lib, hash: hash("aa"), bytes: 1_000)
        try seedBlob(lib, hash: hash("bb"), bytes: 2_000)
        let doomed = try seedBlob(lib, hash: hash("cc"), bytes: 4_000)

        // The user empties the Trash while the scan runs. `isCancelled` is
        // polled per file in BOTH phases, so removing it here lands mid-scan
        // whichever phase reaches it first — and the answer is the same either
        // way: enumerated-then-gone is skipped at `stat`, never-enumerated is
        // never sized. That equivalence is exactly the property under test.
        let scan = try scanner(lib).scan(isCancelled: {
            try? FileManager.default.removeItem(at: doomed)
            return false
        })

        #expect(scan.usage.blobBytes == 3_000)
        #expect(scan.usage.blobFileCount == 2)
        #expect(scan.blobSizes[hash("cc")] == nil)
    }

    @Test("a scan whose whole blob directory vanishes mid-scan still completes")
    func entireDirectoryDeletedMidScan() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlob(lib, hash: hash("aa"), bytes: 1_000)
        try seedBlob(lib, hash: hash("bb"), bytes: 2_000)
        let blobs = lib.layout.blobs

        let scan = try scanner(lib).scan(isCancelled: {
            try? FileManager.default.removeItem(at: blobs)
            return false
        })

        // Nothing measurable is left, and that is a total, not a failure.
        #expect(scan.usage.blobBytes == 0)
        #expect(scan.blobSizes.isEmpty)
    }

    @Test("a blob restored from the Trash mid-scan never crashes the scan")
    func blobRestoredMidScanIsTolerated() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlob(lib, hash: hash("aa"), bytes: 1_000)
        let restoredURL = lib.store.blobURL(hash: hash("bb"), fileExtension: "png")
        let restoredBytes = Data(repeating: 0x41, count: 2_000)

        // The user drags a reaped blob back out of the Trash while the scan is
        // walking. Whether phase 1 had already listed that directory decides
        // whether this scan sees it — BOTH totals are correct answers to "what
        // was on disk when I looked", so the test pins the pair rather than
        // pretending the filesystem is transactional.
        let scan = try scanner(lib).scan(isCancelled: {
            try? FileManager.default.createDirectory(
                at: restoredURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? restoredBytes.write(to: restoredURL)
            return false
        })

        #expect(scan.usage.blobBytes == 1_000 || scan.usage.blobBytes == 3_000)
        // And the very next scan is unambiguous.
        let after = try scanner(lib).scan()
        #expect(after.usage.blobBytes == 3_000)
        #expect(after.blobSizes[hash("bb")] == 2_000)
    }

    // MARK: - Cancellation + progress

    @Test("cancelling throws rather than returning a half-measured library")
    func cancellationThrows() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        try seedBlob(lib, hash: hash("aa"), bytes: 1_000)
        try seedBlob(lib, hash: hash("bb"), bytes: 2_000)

        #expect(throws: CancellationError.self) {
            try scanner(lib).scan(isCancelled: { true })
        }
    }

    @Test("progress is monotonic and ends at 1")
    func progressReachesOne() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        for index in 0 ..< 12 {
            try seedBlob(lib, hash: hash(String(format: "%02x", index + 16)), bytes: 100)
        }

        // `@Sendable` closure over a class box: the scan is synchronous, so
        // there is no concurrent writer.
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        _ = try scanner(lib).scan(onProgress: { box.values.append($0) })

        #expect(box.values.last == 1)
        #expect(box.values == box.values.sorted())
        #expect(box.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("the scan timestamp is the injected one, so results are deterministic")
    func timestampIsInjected() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(try scanner(lib).scan(now: when).scannedAt == when)
    }
}

// MARK: - Pure aggregation

@Suite("LibraryStats aggregation (016 A)")
struct LibraryStatsAggregationTests {

    private func usage(
        _ hash: String, name: String? = nil, ids: [UUID] = [UUID()],
        kind: AssetKind = .image, platform: Platform = .web
    ) -> BlobUsage {
        BlobUsage(
            blobHash: hash, mimeType: "image/png", kind: kind, platform: platform,
            displayName: name, assetIDs: ids)
    }

    @Test("largest items are ordered biggest-first and truncated to the limit")
    func exactTopNOrdering() {
        let blobs = [usage("aa"), usage("bb"), usage("cc"), usage("dd")]
        let sizes: [String: Int64] = ["aa": 10, "bb": 900, "cc": 50, "dd": 400]

        let top = LibraryStats.largestItems(blobs: blobs, sizes: sizes, limit: 3)

        #expect(top.map(\.blobHash) == ["bb", "dd", "cc"])
        #expect(top.map(\.byteSize) == [900, 400, 50])
    }

    @Test("equal sizes break on hash, so a refresh can't reshuffle the rows")
    func tiesAreDeterministic() {
        let blobs = [usage("cc"), usage("aa"), usage("bb")]
        let sizes: [String: Int64] = ["aa": 100, "bb": 100, "cc": 100]

        let top = LibraryStats.largestItems(blobs: blobs, sizes: sizes, limit: 3)

        #expect(top.map(\.blobHash) == ["aa", "bb", "cc"])
    }

    @Test("a blob with no file on disk is EXCLUDED, not ranked as zero")
    func blobsWithoutFilesAreExcluded() {
        let blobs = [usage("aa"), usage("gone"), usage("bb")]
        let sizes: [String: Int64] = ["aa": 10, "bb": 20]

        let top = LibraryStats.largestItems(blobs: blobs, sizes: sizes, limit: 10)

        #expect(top.map(\.blobHash) == ["bb", "aa"])
    }

    @Test("a non-positive limit yields nothing")
    func zeroLimit() {
        #expect(LibraryStats.largestItems(
            blobs: [usage("aa")], sizes: ["aa": 1], limit: 0).isEmpty)
    }

    @Test("the row carries every asset that shares the file")
    func sharedBlobCarriesAllAssets() {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let top = LibraryStats.largestItems(
            blobs: [usage("aa", ids: ids)], sizes: ["aa": 5], limit: 1)

        #expect(top.first?.assetIDs == ids)
        #expect(top.first?.usage.assetCount == 2)
    }

    @Test("counts come back in declaration order with the empties dropped")
    func orderedCounts() {
        let counts: [AssetKind: Int] = [.color: 2, .image: 7, .video: 0, .link: 1]

        let ordered = LibraryStats.ordered(counts)

        #expect(ordered.map(\.key) == [.image, .link, .color])
        #expect(ordered.map(\.count) == [7, 1, 2])
    }

    @Test("an empty count map orders to nothing")
    func orderedEmpty() {
        #expect(LibraryStats.ordered([Platform: Int]()).isEmpty)
    }
}
