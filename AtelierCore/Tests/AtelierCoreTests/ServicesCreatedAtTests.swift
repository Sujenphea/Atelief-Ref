// AtelierCore — `asset.created_at` comes from the source's `capturedAt` (092 · S3
// review, 18A/17A).
//
// Both insert sites in `AppServices` — the byte path (`ingest`) and the media-less
// content path (`ingestContent`) — used to stamp `Date()`, which made `created_at`
// the moment a ROW was written rather than the moment the user took the thing.
// Those were the same instant for every producer that existed then, so the seam
// only became visible with the iOS inbox: a share drained days after it was sent
// would have sorted to the top of the grid on the day the Mac was next opened.
//
// The assertions here are equality against a fixed, deliberately-old `capturedAt`,
// not a range around `Date()` — a test that allowed "close enough to now" would
// pass just as happily under the old behaviour.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Services: created_at is the capture time (092 · S3)")
struct ServicesCreatedAtTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Long enough ago that no plausible clock skew could confuse it with `Date()`.
    private static let capturedAt = Date(timeIntervalSince1970: 1_600_000_000)

    private func imageDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    // MARK: - The two insert sites

    @Test("ingest: a byte asset's created_at is the source's capturedAt, not now")
    func byteIngestUsesCapturedAt() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let collection = try await services.createCollection(name: "Inbox")

        let result = try await services.ingest(
            imageDraft(hash: String(repeating: "a", count: 64)),
            from: SourceDraft(platform: .web, originalURL: "https://example.com/a",
                              capturedAt: Self.capturedAt),
            into: collection.id)

        #expect(result.wasDeduplicated == false)
        #expect(result.asset.createdAt == Self.capturedAt)
        // And it is what was PERSISTED, not just what the in-memory value carried.
        let stored = try await services.getAsset(id: result.asset.id)
        #expect(stored.asset.createdAt == Self.capturedAt)
        #expect(stored.source.capturedAt == Self.capturedAt)
    }

    @Test("ingestContent: a media-less asset's created_at is the source's capturedAt")
    func contentIngestUsesCapturedAt() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let collection = try await services.createCollection(name: "Palette")

        let result = try await services.ingestContent(
            .color(hex: "#FF0000"),
            from: SourceDraft(platform: .localPaste, capturedAt: Self.capturedAt),
            into: collection.id)

        #expect(result.wasDeduplicated == false)
        #expect(result.asset.createdAt == Self.capturedAt)
        let stored = try await services.getAsset(id: result.asset.id)
        #expect(stored.asset.createdAt == Self.capturedAt)
    }

    @Test("a link's created_at survives the originalURL canonicalization")
    func contentIngestCanonicalizedSourceKeepsCapturedAt() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let collection = try await services.createCollection(name: "Links")

        // `ingestContent` rewrites the draft's `originalURL` to the kind's
        // canonical identity before inserting; the row is built from THAT draft,
        // so this pins that the rewrite carries `capturedAt` across with it.
        let result = try await services.ingestContent(
            .link(url: "https://example.com/post?utm_source=x"),
            from: SourceDraft(platform: .web, originalURL: "https://example.com/post",
                              capturedAt: Self.capturedAt),
            into: collection.id)

        #expect(result.asset.createdAt == Self.capturedAt)
    }

    // MARK: - What it buys

    @Test("a backlog drained out of order still reads in capture order")
    func gridOrderFollowsCaptureTime() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let collection = try await services.createCollection(name: "Unsorted")

        // Three captures, inserted NEWEST first — the shape a drain produces when
        // the records reach the coordinator in an order the user did not choose.
        let times = [3, 1, 2].map { Date(timeIntervalSince1970: 1_600_000_000 + Double($0) * 3600) }
        for (index, when) in times.enumerated() {
            _ = try await services.ingest(
                imageDraft(hash: String(repeating: "\(index)", count: 64)),
                from: SourceDraft(platform: .web,
                                  originalURL: "https://example.com/\(index)",
                                  capturedAt: when),
                into: collection.id)
        }

        // `created_at DESC` is what "Newest" and search order by, so the newest
        // CAPTURE now leads regardless of which row was written first.
        let byCreated = try await services.collectionItems(in: collection.id, includeArchived: false)
            .map(\.asset.createdAt)
            .sorted(by: >)
        #expect(byCreated == times.sorted(by: >))
    }

    @Test("an 18A dedup keeps the FIRST capture's created_at, not the second's")
    func dedupKeepsOriginalCreatedAt() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let collection = try await services.createCollection(name: "Unsorted")
        let hash = String(repeating: "b", count: 64)
        let later = Self.capturedAt.addingTimeInterval(86_400)

        let first = try await services.ingest(
            imageDraft(hash: hash),
            from: SourceDraft(platform: .web, originalURL: "https://example.com/b",
                              capturedAt: Self.capturedAt),
            into: collection.id)
        // The same bytes and the same provenance, re-offered later — exactly what a
        // crash mid-drain replays on the next pass. The dedup must resolve onto the
        // asset that is there rather than re-dating it.
        let second = try await services.ingest(
            imageDraft(hash: hash),
            from: SourceDraft(platform: .web, originalURL: "https://example.com/b",
                              capturedAt: later),
            into: collection.id)

        #expect(second.wasDeduplicated == true)
        #expect(second.asset.id == first.asset.id)
        #expect(second.asset.createdAt == Self.capturedAt)
    }
}
