// AtelierCore — suggested-tag service tests (012 · I3)
//
// The suggest-and-confirm funnel: which suggestions get written, what accepting
// one does to the tag graph, and — the test this feature exists for — that a
// dismissal survives a suggester-version bump.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Services: suggested tags (012 · I3)")
struct ServicesSuggestionsTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one DISTINCT asset into `c` and return its id.
    @discardableResult
    private func seed(_ services: AppServices, into c: UUID) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c).asset.id
    }

    /// An asset plus its analysis row — `assetsNeedingSuggestions` requires one,
    /// and `recordSuggestions` writes its marker onto it.
    private func seedAnalyzed(_ services: AppServices, into c: UUID) async throws -> UUID {
        let id = try await seed(services, into: c)
        _ = try await services.upsertAnalysis(assetID: id, analyzerVersion: 1)
        return id
    }

    private func names(_ services: AppServices, on asset: UUID, _ source: TagSource) async throws -> [String] {
        try await services.tags(for: asset).filter { $0.source == source }.map(\.name)
    }

    // MARK: - recordSuggestions

    @Test("suggestions land as agent tags and mark the asset done")
    func recordsAndMarks() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)

        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 10) == [a])

        let written = try await services.recordSuggestions(["poster", "type"], for: a, suggestVersion: 1)
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.source == .agent })
        #expect(try await names(services, on: a, .agent).sorted() == ["poster", "type"])

        // Marked, so the resumable query drops it.
        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 10).isEmpty)
        #expect(try await services.analysis(for: a)?.suggestVersion == 1)
    }

    @Test("an asset with nothing to suggest is still marked done")
    func marksEvenWhenEmpty() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)

        let written = try await services.recordSuggestions([], for: a, suggestVersion: 1)
        #expect(written.isEmpty)
        // The whole point: "looked here, had nothing to say" is a finished asset.
        // Without the marker it would be re-classified on every idle pass forever.
        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 10).isEmpty)
    }

    @Test("blank names are dropped, not thrown on, and repeats collapse")
    func dropsJunkNames() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)

        let written = try await services.recordSuggestions(
            ["poster", "   ", "", "#poster", "poster"], for: a, suggestVersion: 1)
        // "#poster" normalizes onto "poster"; the blanks are silently skipped.
        #expect(written.map(\.name) == ["poster"])
    }

    @Test("a name the user already confirmed is not suggested back to them")
    func skipsConfirmedNames() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.applyTag("poster", to: a, source: .user)

        let written = try await services.recordSuggestions(["poster", "type"], for: a, suggestVersion: 1)
        #expect(written.map(\.name) == ["type"])
        #expect(try await names(services, on: a, .agent) == ["type"])
    }

    @Test("suggestions are skipped only for the asset that refused them")
    func suppressionIsPerAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        let b = try await seedAnalyzed(services, into: c.id)

        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)
        try await services.dismissSuggestion("poster", on: a)

        _ = try await services.recordSuggestions(["poster"], for: b, suggestVersion: 1)
        #expect(try await names(services, on: b, .agent) == ["poster"])
        #expect(try await names(services, on: a, .agent).isEmpty)
    }

    // MARK: - Accept

    @Test("accepting trades the agent tag for a user tag")
    func acceptSwapsSource() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)

        let accepted = try await services.acceptSuggestion("poster", on: a)
        #expect(accepted.source == .user)
        #expect(try await names(services, on: a, .agent).isEmpty)
        #expect(try await names(services, on: a, .user) == ["poster"])
    }

    /// The reason accept is an unlink-and-re-apply rather than a `tag.source`
    /// flip. The tag ROW is shared by every asset carrying it, so an in-place
    /// edit would confirm the suggestion on assets the user has never opened.
    @Test("accepting on one asset leaves the same suggestion pending on another")
    func acceptDoesNotPromoteSiblings() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        let b = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)
        _ = try await services.recordSuggestions(["poster"], for: b, suggestVersion: 1)

        _ = try await services.acceptSuggestion("poster", on: a)

        #expect(try await names(services, on: a, .user) == ["poster"])
        #expect(try await names(services, on: b, .user).isEmpty)
        #expect(try await names(services, on: b, .agent) == ["poster"])
    }

    @Test("accepting twice leaves exactly one user tag")
    func acceptIsIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)

        _ = try await services.acceptSuggestion("poster", on: a)
        _ = try await services.acceptSuggestion("poster", on: a)
        #expect(try await names(services, on: a, .user) == ["poster"])
    }

    @Test("accepting on a missing asset is notFound")
    func acceptRejectsMissingAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.self) {
            _ = try await services.acceptSuggestion("poster", on: UUID())
        }
    }

    // MARK: - Dismiss + suppression memory

    @Test("dismissing unlinks the tag and records the refusal")
    func dismissRemembers() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)

        try await services.dismissSuggestion("poster", on: a)
        #expect(try await names(services, on: a, .agent).isEmpty)
        #expect(try await services.suppressedTagNames(for: a) == ["poster"])
    }

    /// The regression this whole table exists to prevent (012's named risk): the
    /// model changes its mind, the user's refusal does not expire.
    @Test("a dismissal survives a suggester-version bump")
    func suppressionSurvivesVersionBump() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster", "type"], for: a, suggestVersion: 1)
        try await services.dismissSuggestion("poster", on: a)

        // Version 2 pulls the asset back into the queue and proposes the same
        // labels again.
        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 2, limit: 10) == [a])
        let written = try await services.recordSuggestions(
            ["poster", "type"], for: a, suggestVersion: 2)

        #expect(written.map(\.name) == ["type"])
        #expect(try await names(services, on: a, .agent) == ["type"])
        #expect(try await services.suppressedTagNames(for: a) == ["poster"])
    }

    @Test("a re-analysis does not silently re-open the suggestion queue")
    func analyzerBumpKeepsSuggestMarker() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)

        // A new analyzer version rewrites OCR / colors / phash for this asset.
        _ = try await services.upsertAnalysis(assetID: a, ocrText: "hello", analyzerVersion: 2)

        // The suggester marker survives — the two versions are independent, which
        // is the entire reason `suggest_version` is its own column.
        #expect(try await services.analysis(for: a)?.suggestVersion == 1)
        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 10).isEmpty)
    }

    @Test("dismissing is idempotent and refreshes the refusal")
    func dismissIsIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)

        try await services.dismissSuggestion("poster", on: a)
        try await services.dismissSuggestion("poster", on: a)
        #expect(try await services.suppressedTagNames(for: a) == ["poster"])
    }

    @Test("dismissing normalizes the name, so #poster refuses poster")
    func dismissNormalizes() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)

        try await services.dismissSuggestion("  #poster ", on: a)
        #expect(try await names(services, on: a, .agent).isEmpty)
        #expect(try await services.suppressedTagNames(for: a) == ["poster"])
    }

    @Test("unsuppressing lets the name be suggested again, without re-applying it")
    func unsuppressReopens() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)
        try await services.dismissSuggestion("poster", on: a)

        try await services.unsuppressTag("poster", on: a)
        #expect(try await services.suppressedTagNames(for: a).isEmpty)
        // Forgetting the refusal does NOT put the chip back; the next pass decides.
        #expect(try await names(services, on: a, .agent).isEmpty)

        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 2)
        #expect(try await names(services, on: a, .agent) == ["poster"])
    }

    @Test("deleting the asset takes its refusals with it")
    func suppressionCascades() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seedAnalyzed(services, into: c.id)
        _ = try await services.recordSuggestions(["poster"], for: a, suggestVersion: 1)
        try await services.dismissSuggestion("poster", on: a)

        try await services.deleteAssets([a])
        #expect(try await services.suppressedTagNames(for: a).isEmpty)
    }

    // MARK: - The candidate query

    @Test("an asset with no analysis row is not a suggestion candidate")
    func requiresAnalysisRow() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let unanalyzed = try await seed(services, into: c.id)
        let analyzed = try await seedAnalyzed(services, into: c.id)

        // An INNER join, deliberately: the marker lives on the analysis row, so an
        // asset without one could be classified but never marked — and would come
        // back on every pass forever.
        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 10) == [analyzed])
        #expect(!(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 10)).contains(unanalyzed))
    }

    /// Video reaches the ✦ chips too, on the same poster-frame footing as the
    /// analysis queue. It did not when I3 shipped: this query was written by
    /// mirroring the analysis one and inherited its video exclusion.
    @Test("a video with an analysis row is a suggestion candidate")
    func videoIsCandidate() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")

        let draft = AssetDraft(
            kind: .video,
            blobHash: "f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5",
            mimeType: "video/mp4", width: 1920, height: 1080, duration: 8,
            fileSize: 4096, downloadState: .downloaded)
        let video = try await services.ingest(
            draft, from: SourceDraft(platform: .localPaste, capturedAt: Date()),
            into: c.id).asset.id
        _ = try await services.upsertAnalysis(assetID: video, analyzerVersion: 1)

        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 10) == [video])

        let written = try await services.recordSuggestions(
            ["title sequence"], for: video, suggestVersion: 1)
        #expect(written.map(\.name) == ["title sequence"])
    }

    @Test("the candidate limit is clamped and honored")
    func candidateLimit() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        for _ in 0..<3 { _ = try await seedAnalyzed(services, into: c.id) }

        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 2).count == 2)
        // Clamped to at least 1 rather than returning nothing.
        #expect(try await services.assetsNeedingSuggestions(suggestVersion: 1, limit: 0).count == 1)
    }

    @Test("recordSuggestions on a missing asset is notFound")
    func recordRejectsMissingAsset() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.self) {
            _ = try await services.recordSuggestions(["poster"], for: UUID(), suggestVersion: 1)
        }
    }
}
