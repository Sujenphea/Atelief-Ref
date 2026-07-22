// AtelierCore — App Services detail-field tests (041 · item-detail redesign)
//
// setName / setNote round-trip + trim + clear-to-nil, `.notFound` for a missing
// asset, and collections(for:) reverse membership (name-ordered, empty default).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: detail fields")
struct ServicesDetailFieldsTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one DISTINCT asset into a collection and return both ids.
    private func seedAsset(
        _ services: AppServices, into collectionID: UUID
    ) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", capturedAt: Date())
        return try await services.ingest(draft, from: source, into: collectionID).asset.id
    }

    private func fetchAsset(_ temp: TempDatabase, _ id: UUID) throws -> Asset? {
        try temp.database.read { try Asset.fetchOne($0, key: id.uuidString.lowercased()) }
    }

    // MARK: setName / setNote

    @Test("setName stores, trims, and clears to nil")
    func setNameRoundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let asset = try await seedAsset(services, into: c.id)

        try await services.setName("  Hero shot  ", for: asset)
        #expect(try fetchAsset(temp, asset)?.name == "Hero shot")

        try await services.setNote("look at the lighting", for: asset)
        #expect(try fetchAsset(temp, asset)?.note == "look at the lighting")

        // Empty / whitespace clears back to nil (the "unnamed" state).
        try await services.setName("   ", for: asset)
        #expect(try fetchAsset(temp, asset)?.name == nil)
        try await services.setNote(nil, for: asset)
        #expect(try fetchAsset(temp, asset)?.note == nil)
    }

    @Test("setName / setNote throw .notFound for a missing asset")
    func setMissingAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.self) {
            try await services.setName("x", for: UUID())
        }
        await #expect(throws: AtelierError.self) {
            try await services.setNote("x", for: UUID())
        }
    }

    // MARK: collections(for:)

    @Test("collections(for:) returns memberships name-ordered; empty by default")
    func collectionsReverseLookup() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let zed = try await services.createCollection(name: "Zed")
        let asset = try await seedAsset(services, into: zed.id)

        // Fresh membership in "Zed" only.
        #expect(try await services.collections(for: asset).map(\.name) == ["Zed"])

        // Add to two more; result is name-ordered (Alpha, Mid, Zed).
        let alpha = try await services.createCollection(name: "Alpha")
        let mid = try await services.createCollection(name: "Mid")
        try await services.addAssets([asset], to: alpha.id)
        try await services.addAssets([asset], to: mid.id)
        #expect(try await services.collections(for: asset).map(\.name) == ["Alpha", "Mid", "Zed"])

        // Removing a membership drops it from the reverse lookup.
        try await services.removeAssets([asset], from: mid.id)
        #expect(try await services.collections(for: asset).map(\.name) == ["Alpha", "Zed"])

        // An asset with no memberships reads empty.
        #expect(try await services.collections(for: UUID()).isEmpty)
    }
}
