// AtelierCore — snapshot / integrity tests (008 H1)
//
// `snapshot(to:)` produces a self-consistent, openable copy whose rows equal the
// source; `integrityCheck()` passes on a healthy live DB; `isHealthy(fileAt:)`
// validates a snapshot file without the live pool; overwriting a snapshot fails.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: snapshot / integrity")
struct ServicesSnapshotTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one DISTINCT asset into a fresh collection and return both ids.
    private func seed(_ services: AppServices) async throws -> (collection: UUID, asset: UUID) {
        let c = try await services.createCollection(name: "Refs")
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", capturedAt: Date())
        let asset = try await services.ingest(draft, from: source, into: c.id).asset.id
        return (c.id, asset)
    }

    @Test("snapshot(to:) writes an openable copy whose rows equal the source")
    func snapshotRoundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let (collection, asset) = try await seed(services)
        try await services.applyTag("hero", to: asset, source: .user)

        let snapshotURL = temp.directory.appendingPathComponent("snap.sqlite")
        try await services.snapshot(to: snapshotURL)
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

        // Open the snapshot as its own library (migrations re-run idempotently)
        // and assert the seeded state survived verbatim.
        let restored = try AppServices(databasePath: snapshotURL.path)
        let items = try await restored.collectionItems(in: collection, includeArchived: false)
        #expect(items.count == 1)
        #expect(items.first?.asset.id == asset)
        let tags = try await restored.tags(for: asset)
        #expect(tags.map(\.name) == ["hero"])
    }

    @Test("integrityCheck() passes on a healthy live database")
    func integrityHealthy() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await seed(services)
        #expect(try await services.integrityCheck())
    }

    @Test("isHealthy(databaseFileAt:) validates a snapshot file off the live pool")
    func snapshotFileHealthy() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await seed(services)

        let snapshotURL = temp.directory.appendingPathComponent("snap.sqlite")
        try await services.snapshot(to: snapshotURL)
        #expect(try AppServices.isHealthy(databaseFileAt: snapshotURL))
    }

    @Test("snapshot(to:) refuses to overwrite an existing file")
    func snapshotNoOverwrite() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        _ = try await seed(services)

        let snapshotURL = temp.directory.appendingPathComponent("snap.sqlite")
        try await services.snapshot(to: snapshotURL)
        await #expect(throws: (any Error).self) {
            try await services.snapshot(to: snapshotURL)
        }
    }
}
