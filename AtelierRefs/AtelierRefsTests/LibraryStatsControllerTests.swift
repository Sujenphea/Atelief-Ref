//
//  LibraryStatsControllerTests.swift
//  AtelierRefsTests
//
//  016 · A — the app-side orchestrator, driven against a real (temp) library.
//  The services it calls are already tested where they live (`MediaReaperTests`,
//  `ServicesLibraryStatsTests`, `ServicesJobTests`), so these are
//  invoke-the-existing-service assertions plus the part only the app has: which
//  outcome the user is shown, and that pressing Stop is never reported as a
//  failure.
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

@MainActor
@Suite("LibraryStatsController (016 A)")
struct LibraryStatsControllerTests {

    private struct Rig {
        let controller: LibraryStatsController
        let services: AppServices
        let store: MediaStore
        let root: URL

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStatsControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let services = try AppServices(
            databasePath: root.appendingPathComponent("library.sqlite").path)
        return Rig(
            controller: LibraryStatsController(), services: services,
            store: MediaStore(root: root), root: root)
    }

    /// A 64-hex hash from a short marker, so shard math behaves as in production.
    private func hash(_ marker: String) -> String {
        String((marker + String(repeating: "0", count: 64)).prefix(64))
    }

    /// Ingest one asset AND write its blob bytes — a referenced file of a known
    /// size, which is what makes the totals below exact.
    @discardableResult
    private func seed(
        _ rig: Rig, marker: String, bytes: Int, platform: Platform = .web,
        kind: AssetKind = .image, mime: String = "image/png"
    ) async throws -> String {
        let blobHash = hash(marker)
        try rig.store.storeBlob(
            Data(repeating: 0x41, count: bytes), hash: blobHash, fileExtension: "png")
        let collection = try await rig.services.createCollection(name: "C-\(marker)")
        let draft = AssetDraft(
            kind: kind, blobHash: blobHash, mimeType: mime,
            width: 10, height: 10, fileSize: bytes, downloadState: .downloaded)
        let source = SourceDraft(
            platform: platform, originalURL: "https://example.com/\(marker)",
            capturedAt: Date())
        _ = try await rig.services.ingest(draft, from: source, into: collection.id)
        return blobHash
    }

    /// Poll until the running job settles. Bounded so a hang fails the test
    /// rather than wedging the suite.
    private func settle(_ controller: LibraryStatsController) async throws {
        for _ in 0 ..< 600 where controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isRunning)
    }

    private func successMessage(_ controller: LibraryStatsController) -> String? {
        guard case .success(let text) = controller.lastReport?.outcome else { return nil }
        return text
    }

    // MARK: - Measure

    @Test("measuring reports exact totals and the exact top-N order")
    func measureIsExact() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, marker: "aa", bytes: 1_000)
        try await seed(rig, marker: "bb", bytes: 9_000)
        try await seed(rig, marker: "cc", bytes: 300)

        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)

        let stats = try #require(rig.controller.stats)
        #expect(stats.usage.blobBytes == 10_300)
        #expect(stats.usage.blobFileCount == 3)
        #expect(stats.usage.databaseBytes > 0)
        #expect(stats.assetCount == 3)
        #expect(stats.countsByKind[.image] == 3)
        #expect(stats.largest.map(\.blobHash) == [hash("bb"), hash("aa"), hash("cc")])
        #expect(stats.largest.map(\.byteSize) == [9_000, 1_000, 300])
        #expect(!rig.controller.isStale)
    }

    @Test("measuring counts by platform over a mixed library")
    func measureCountsPlatforms() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, marker: "aa", bytes: 10, platform: .instagram)
        try await seed(rig, marker: "bb", bytes: 10, platform: .instagram)
        try await seed(rig, marker: "cc", bytes: 10, platform: .pinterest)

        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)

        let stats = try #require(rig.controller.stats)
        #expect(stats.countsByPlatform[.instagram] == 2)
        #expect(stats.countsByPlatform[.pinterest] == 1)
        #expect(stats.countsByPlatform[.twitter] == nil)
    }

    @Test("the top-N list honours its limit")
    func measureHonoursLimit() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 5 {
            try await seed(rig, marker: "a\(index)", bytes: 100 * (index + 1))
        }

        rig.controller.measure(services: rig.services, store: rig.store, limit: 2)
        try await settle(rig.controller)

        let stats = try #require(rig.controller.stats)
        #expect(stats.largest.count == 2)
        #expect(stats.largest.map(\.byteSize) == [500, 400])
    }

    @Test("an empty library measures to zero rather than failing")
    func measureEmptyLibrary() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }

        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)

        let stats = try #require(rig.controller.stats)
        #expect(stats.usage.blobBytes == 0)
        #expect(stats.assetCount == 0)
        #expect(stats.largest.isEmpty)
        #expect(rig.controller.lastReport?.isFailure == false)
    }

    // MARK: - Cleanup: the buttons invoke the existing services

    @Test("the orphan sweep invokes MediaReaper — unreferenced blobs leave, referenced stay")
    func orphanSweepReaps() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        let kept = try await seed(rig, marker: "aa", bytes: 100)
        // A blob with bytes on disk and no asset row — exactly what a delete that
        // was never undone leaves behind.
        let orphan = hash("ff")
        try rig.store.storeBlob(Data("orphan".utf8), hash: orphan, fileExtension: "png")

        rig.controller.runOrphanSweep(services: rig.services, store: rig.store)
        try await settle(rig.controller)

        #expect(!rig.store.hasBlob(hash: orphan, fileExtension: "png"))
        #expect(rig.store.hasBlob(hash: kept, fileExtension: "png"))
        #expect(successMessage(rig.controller)?.contains("1 unreferenced file") == true)
        // The sweep moved bytes, so any earlier measurement is now out of date.
        #expect(rig.controller.lastReport?.job == .orphanSweep)
    }

    @Test("a sweep with nothing to reclaim says so, and doesn't invalidate the stats")
    func orphanSweepNoOp() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, marker: "aa", bytes: 100)
        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)

        rig.controller.runOrphanSweep(services: rig.services, store: rig.store)
        try await settle(rig.controller)

        #expect(successMessage(rig.controller) == "No orphaned media found — nothing to reclaim.")
        #expect(!rig.controller.isStale)
    }

    @Test("regenerating thumbnails invokes the backfill over the referenced blobs")
    func regenerateThumbnails() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        // Real decodable bytes, so a thumbnail can actually be produced.
        let png = try Self.tinyPNG()
        let blobHash = hash("dd")
        try rig.store.storeBlob(png, hash: blobHash, fileExtension: "png")
        let collection = try await rig.services.createCollection(name: "C")
        _ = try await rig.services.ingest(
            AssetDraft(
                kind: .image, blobHash: blobHash, mimeType: "image/png",
                width: 8, height: 8, fileSize: png.count, downloadState: .downloaded),
            from: SourceDraft(
                platform: .web, originalURL: "https://example.com/dd", capturedAt: Date()),
            into: collection.id)
        #expect(!rig.store.hasThumbnail(
            hash: blobHash, size: ThumbnailTier.small.rawValue, fileExtension: "jpg"))

        rig.controller.regenerateThumbnails(services: rig.services, store: rig.store)
        try await settle(rig.controller)

        for tier in ThumbnailTier.allCases {
            #expect(rig.store.hasThumbnail(
                hash: blobHash, size: tier.rawValue, fileExtension: "jpg"))
        }
        #expect(rig.controller.isStale == false) // nothing measured yet to invalidate
        #expect(successMessage(rig.controller)?.contains("Rebuilt") == true)
    }

    @Test("verifying integrity invokes the PRAGMA and reports a healthy database")
    func verifyIntegrity() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, marker: "aa", bytes: 10)

        rig.controller.verifyIntegrity(services: rig.services)
        try await settle(rig.controller)

        #expect(successMessage(rig.controller) == "Database integrity check passed.")
        #expect(rig.controller.lastReport?.isFailure == false)
    }

    @Test("reconciling invokes reconcileOrphanedKnownItems and reports a clean ledger")
    func reconcileKnownItems() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, marker: "aa", bytes: 10)

        rig.controller.reconcileKnownItems(services: rig.services)
        try await settle(rig.controller)

        #expect(successMessage(rig.controller) == "The import ledger is already consistent.")
    }

    // MARK: - Run discipline

    @Test("a second job is refused while one is in flight")
    func oneJobAtATime() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 40 {
            try await seed(rig, marker: "b\(index)", bytes: 64)
        }

        rig.controller.measure(services: rig.services, store: rig.store)
        // Whichever of the two lands first, exactly one job runs and exactly one
        // report is produced.
        rig.controller.verifyIntegrity(services: rig.services)
        try await settle(rig.controller)

        #expect(rig.controller.lastReport?.seq == 1)
    }

    @Test("cancelling is reported as cancelled — never as a failure")
    func cancellationIsNotFailure() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        for index in 0 ..< 60 {
            try await seed(rig, marker: "c\(index)", bytes: 256)
        }

        rig.controller.measure(services: rig.services, store: rig.store)
        rig.controller.cancel()
        try await settle(rig.controller)

        let report = try #require(rig.controller.lastReport)
        #expect(report.outcome == .cancelled)
        #expect(!report.isFailure)
        #expect(report.message.contains("stopped"))
    }

    @Test("a cancelled measurement leaves the previous figures alone")
    func cancelledMeasurementKeepsPreviousStats() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, marker: "aa", bytes: 500)
        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)
        let first = try #require(rig.controller.stats)

        rig.controller.measure(services: rig.services, store: rig.store)
        rig.controller.cancel()
        try await settle(rig.controller)

        #expect(rig.controller.stats == first)
    }

    @Test("the report sequence is monotonic, so two identical outcomes are two events")
    func reportSequenceIsMonotonic() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }

        rig.controller.verifyIntegrity(services: rig.services)
        try await settle(rig.controller)
        let first = try #require(rig.controller.lastReport)
        rig.controller.verifyIntegrity(services: rig.services)
        try await settle(rig.controller)
        let second = try #require(rig.controller.lastReport)

        #expect(first.outcome == second.outcome)
        #expect(second.seq == first.seq + 1)
    }

    @Test("a delete under a measurement marks it stale rather than silently wrong")
    func markStaleOnlyAfterAMeasurement() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }

        // Nothing measured yet: there is nothing to invalidate.
        rig.controller.markStale()
        #expect(!rig.controller.isStale)

        try await seed(rig, marker: "aa", bytes: 10)
        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)
        rig.controller.markStale()
        #expect(rig.controller.isStale)

        // A fresh measurement clears it.
        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)
        #expect(!rig.controller.isStale)
    }

    @Test("forgetting the stats clears both the figures and the staleness")
    func forgetStats() async throws {
        let rig = try makeRig()
        defer { rig.cleanup() }
        try await seed(rig, marker: "aa", bytes: 10)
        rig.controller.measure(services: rig.services, store: rig.store)
        try await settle(rig.controller)
        rig.controller.markStale()

        rig.controller.forgetStats()

        #expect(rig.controller.stats == nil)
        #expect(!rig.controller.isStale)
    }

    // MARK: - Fixtures

    /// An 8×8 PNG, built at runtime (the repo commits no binary fixtures).
    private static func tinyPNG() throws -> Data {
        let size = 8
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
