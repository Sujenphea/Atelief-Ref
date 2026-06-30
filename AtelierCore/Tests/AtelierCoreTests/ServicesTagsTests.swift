// AtelierCore — App Services tag tests (chunk 6, schema-reserved minimal tags)
//
// applyTag find-or-create + idempotent link, user vs agent distinctness,
// idempotent removeTag, tags(for:) ordering, `.notFound` for a missing asset,
// and the empty-name rejection.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: tags")
struct ServicesTagsTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func tagCount(_ temp: TempDatabase) throws -> Int {
        try temp.database.read { try Tag.fetchCount($0) }
    }
    private func joinCount(_ temp: TempDatabase) throws -> Int {
        try temp.database.read { try AssetTag.fetchCount($0) }
    }

    /// Ingest one DISTINCT asset (unique hash + url so 18A dedup never collapses
    /// two calls into one asset) and return its id.
    private func seedAsset(_ services: AppServices) async throws -> UUID {
        let c = try await services.createCollection(name: "Refs")
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c.id).asset.id
    }

    // MARK: applyTag

    @Test("applyTag creates the tag and links it")
    func applyCreatesAndLinks() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        let tag = try await services.applyTag("inspiration", to: asset, source: .user)
        #expect(tag.name == "inspiration")
        #expect(tag.source == .user)
        #expect(try tagCount(temp) == 1)
        #expect(try joinCount(temp) == 1)
        #expect(try await services.tags(for: asset).map(\.name) == ["inspiration"])
    }

    @Test("applyTag trims the name")
    func applyTrims() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        let tag = try await services.applyTag("  mood board  ", to: asset, source: .user)
        #expect(tag.name == "mood board")
    }

    @Test("applyTag is idempotent: twice → one tag, one join row")
    func applyIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        let first = try await services.applyTag("warm", to: asset, source: .user)
        let second = try await services.applyTag("warm", to: asset, source: .user)
        #expect(first.id == second.id)          // same tag reused
        #expect(try tagCount(temp) == 1)
        #expect(try joinCount(temp) == 1)       // no duplicate link
    }

    @Test("user vs agent tags with the same name are distinct")
    func userVsAgentDistinct() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        let userTag = try await services.applyTag("auto", to: asset, source: .user)
        let agentTag = try await services.applyTag("auto", to: asset, source: .agent)
        #expect(userTag.id != agentTag.id)
        #expect(try tagCount(temp) == 2)        // two distinct tags
        #expect(try joinCount(temp) == 2)
        let sources = Set(try await services.tags(for: asset).map(\.source))
        #expect(sources == [.user, .agent])
    }

    @Test("the same tag can be shared across assets (find-or-create reuses it)")
    func tagSharedAcrossAssets() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a1 = try await seedAsset(services)
        let a2 = try await seedAsset(services)
        let t1 = try await services.applyTag("shared", to: a1, source: .user)
        let t2 = try await services.applyTag("shared", to: a2, source: .user)
        #expect(t1.id == t2.id)
        #expect(try tagCount(temp) == 1)        // one tag row
        #expect(try joinCount(temp) == 2)       // two links
    }

    @Test("applyTag to a missing asset throws notFound")
    func applyMissingAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "asset", id: ghost)) {
            try await services.applyTag("x", to: ghost, source: .user)
        }
    }

    @Test("applyTag rejects an empty / whitespace-only name")
    func applyEmptyName() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        await #expect(throws: AtelierError.invalidName) {
            try await services.applyTag("   ", to: asset, source: .user)
        }
    }

    // MARK: removeTag

    @Test("removeTag unlinks the tag (leaving the tag row for other assets)")
    func removeUnlinks() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a1 = try await seedAsset(services)
        let a2 = try await seedAsset(services)
        _ = try await services.applyTag("warm", to: a1, source: .user)
        _ = try await services.applyTag("warm", to: a2, source: .user)
        try await services.removeTag("warm", from: a1, source: .user)
        #expect(try await services.tags(for: a1).isEmpty)
        #expect(try await services.tags(for: a2).map(\.name) == ["warm"]) // other asset intact
        #expect(try tagCount(temp) == 1)        // tag row survives
        #expect(try joinCount(temp) == 1)
    }

    @Test("removeTag is idempotent (no-op when the link or tag is absent)")
    func removeIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        // Never applied → no-op, no throw.
        try await services.removeTag("ghost", from: asset, source: .user)
        _ = try await services.applyTag("warm", to: asset, source: .user)
        try await services.removeTag("warm", from: asset, source: .user)
        try await services.removeTag("warm", from: asset, source: .user) // again → no-op
        #expect(try await services.tags(for: asset).isEmpty)
        #expect(try joinCount(temp) == 0)
    }

    @Test("removeTag respects the tag source (user remove leaves the agent tag)")
    func removeRespectsSource() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        _ = try await services.applyTag("auto", to: asset, source: .user)
        _ = try await services.applyTag("auto", to: asset, source: .agent)
        try await services.removeTag("auto", from: asset, source: .user)
        let remaining = try await services.tags(for: asset)
        #expect(remaining.map(\.source) == [.agent])
    }

    // MARK: tags(for:)

    @Test("tags(for:) is ordered by name")
    func tagsOrdered() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        _ = try await services.applyTag("zen", to: asset, source: .user)
        _ = try await services.applyTag("amber", to: asset, source: .user)
        _ = try await services.applyTag("mint", to: asset, source: .user)
        #expect(try await services.tags(for: asset).map(\.name) == ["amber", "mint", "zen"])
    }

    @Test("tags(for:) is empty for an untagged asset")
    func tagsEmpty() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let asset = try await seedAsset(services)
        #expect(try await services.tags(for: asset).isEmpty)
    }
}
