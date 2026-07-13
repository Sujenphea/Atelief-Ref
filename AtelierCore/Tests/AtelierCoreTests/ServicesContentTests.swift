// AtelierCore — media-less content ingest tests (003 · O1 · C0/C1)
//
// `ingestContent` end-to-end for the color kind: a media-less asset lands with
// nil bytes + a payload, dedups by (kind, canonical hex, source), is findable by
// its search_text through `searchAssets`, appears in the collection feed, and
// deletes cleanly (no phantom orphan blob). Plus the per-kind validation matrix.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Services: media-less content ingest (003 · O1)")
struct ServicesContentTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func pasteSource() -> SourceDraft {
        SourceDraft(platform: .localPaste, capturedAt: Date())
    }

    // MARK: color ingest

    @Test("ingesting a color lands a media-less asset: nil bytes, payload + dedup_key set")
    func colorIngest() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")

        let result = try await services.ingestContent(
            .color(hex: "#FF0000"), from: pasteSource(), into: c.id)
        let asset = result.asset

        #expect(result.wasDeduplicated == false)
        #expect(asset.kind == .color)
        #expect(asset.blobHash == nil)
        #expect(asset.mimeType == nil)
        #expect(asset.width == nil && asset.height == nil && asset.fileSize == nil)
        #expect(asset.dedupKey == "#ff0000")            // canonicalized
        #expect(asset.downloadState == .downloaded)     // nothing to fetch
        #expect(asset.content == .color(hex: "#ff0000"))
        #expect(asset.payloadValue?.color?.hex == "#ff0000")

        // It's a member of the collection feed.
        let items = try await services.collectionItems(in: c.id).map(\.asset.id)
        #expect(items == [asset.id])
    }

    @Test("equal colors written differently dedup to one asset (canonical hex)")
    func colorDedup() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        let source = pasteSource()

        let a = try await services.ingestContent(.color(hex: "#ff0000"), from: source, into: c.id)
        // Shorthand + uppercase → same canonical hex, same source (localPaste).
        let b = try await services.ingestContent(.color(hex: "#F00"), from: source, into: c.id)

        #expect(b.wasDeduplicated == true)
        #expect(a.asset.id == b.asset.id)
        // One membership, one asset.
        let items = try await services.collectionItems(in: c.id)
        #expect(items.count == 1)
    }

    @Test("different hexes are distinct assets")
    func distinctColors() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        let source = pasteSource()
        let a = try await services.ingestContent(.color(hex: "#ff0000"), from: source, into: c.id)
        let b = try await services.ingestContent(.color(hex: "#00ff00"), from: source, into: c.id)
        #expect(a.asset.id != b.asset.id)
        #expect(b.wasDeduplicated == false)
        #expect(try await services.collectionItems(in: c.id).count == 2)
    }

    // MARK: validation

    @Test("a malformed color hex is rejected (.invalidColor)")
    func invalidColorRejected() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        await #expect(throws: AtelierError.invalidColor) {
            try await services.ingestContent(.color(hex: "nope"), from: pasteSource(), into: c.id)
        }
    }

    @Test("a byte-backed kind through the content path is rejected (.invalidContentKind)")
    func byteKindRejected() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        let imageDraft = AssetContentDraft(kind: .image, payload: AssetPayload())
        await #expect(throws: AtelierError.invalidContentKind) {
            try await services.ingestContent(imageDraft, from: pasteSource(), into: c.id)
        }
    }

    @Test("a color draft with no payload is rejected (.missingPayload)")
    func missingPayloadRejected() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        let empty = AssetContentDraft(kind: .color, payload: AssetPayload())
        await #expect(throws: AtelierError.missingPayload) {
            try await services.ingestContent(empty, from: pasteSource(), into: c.id)
        }
    }

    @Test("ingestContent into an unknown collection is .notFound")
    func unknownCollection() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.self) {
            try await services.ingestContent(.color(hex: "#fff"), from: pasteSource(), into: UUID())
        }
    }

    // MARK: content FTS + delete

    @Test("a color is findable through searchAssets via asset_fts (search_text)")
    func contentSearch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        let color = try await services.ingestContent(
            .color(hex: "#ff0000"), from: pasteSource(), into: c.id).asset

        // search_text is the canonical hex → FTS tokenizes off the '#'.
        let hits = try await services.searchAssets(text: "ff0000").map(\.asset.id)
        #expect(hits == [color.id])
    }

    // MARK: link ingest (C2)

    private func webSource(_ url: String) -> SourceDraft {
        SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
    }

    @Test("ingesting a link lands a media-less asset: nil bytes, canonical URL payload + dedup_key")
    func linkIngest() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Reading")

        let result = try await services.ingestContent(
            .link(url: "Example.com/Post/", title: "A Post"),
            from: webSource("Example.com/Post/"), into: c.id)
        let asset = result.asset

        #expect(asset.kind == .link)
        #expect(asset.blobHash == nil)
        #expect(asset.dedupKey == "https://example.com/Post")   // canonicalized
        #expect(asset.content == .link(LinkContent(
            url: "https://example.com/Post", title: "A Post",
            description: nil, imageBlobHash: nil)))

        // Provenance URL was aligned to the canonical form.
        #expect(try await services.getAsset(id: asset.id).source.originalURL
                == "https://example.com/Post")
    }

    @Test("the same page written differently dedups to one link (canonical URL)")
    func linkDedup() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Reading")

        let a = try await services.ingestContent(
            .link(url: "https://example.com/x"), from: webSource("https://example.com/x"), into: c.id)
        // Trailing slash + tracking param → same canonical URL.
        let b = try await services.ingestContent(
            .link(url: "https://example.com/x/?utm_source=tw"),
            from: webSource("https://example.com/x/?utm_source=tw"), into: c.id)

        #expect(b.wasDeduplicated == true)
        #expect(a.asset.id == b.asset.id)
        #expect(try await services.collectionItems(in: c.id).count == 1)
    }

    @Test("a non-http(s) link URL is rejected (.invalidLinkURL)")
    func invalidLinkRejected() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Reading")
        await #expect(throws: AtelierError.invalidLinkURL) {
            try await services.ingestContent(
                .link(url: "ftp://nope"), from: webSource("ftp://nope"), into: c.id)
        }
    }

    @Test("a link is findable through searchAssets by title and host")
    func linkSearch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Reading")
        let link = try await services.ingestContent(
            .link(url: "https://dribbble.com/shots/xyz", title: "Brass lamp study"),
            from: webSource("https://dribbble.com/shots/xyz"), into: c.id).asset

        #expect(try await services.searchAssets(text: "brass").map(\.asset.id) == [link.id])
        #expect(try await services.searchAssets(text: "dribbble").map(\.asset.id) == [link.id])
    }

    @Test("deleting a media-less asset reclaims no blob (nil hash) and is clean")
    func deleteMediaLess() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        let color = try await services.ingestContent(
            .color(hex: "#abcdef"), from: pasteSource(), into: c.id).asset

        // No orphan blob to reclaim — a color has no bytes.
        let orphans = try await services.deleteAssets([color.id])
        #expect(orphans.isEmpty)
        // The asset is gone.
        await #expect(throws: AtelierError.self) { try await services.getAsset(id: color.id) }
    }
}
