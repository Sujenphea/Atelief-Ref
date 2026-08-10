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
        let items = try await services.collectionItems(in: c.id, includeArchived: false).map(\.asset.id)
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
        let items = try await services.collectionItems(in: c.id, includeArchived: false)
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
        #expect(try await services.collectionItems(in: c.id, includeArchived: false).count == 2)
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
        #expect(try await services.collectionItems(in: c.id, includeArchived: false).count == 1)
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

    // MARK: tweet ingest (C3)

    private func twitterSource(_ url: String, handle: String? = nil) -> SourceDraft {
        SourceDraft(platform: .twitter, originalURL: url, authorHandle: handle, capturedAt: Date())
    }

    @Test("ingesting a tweet lands a media-less asset: nil bytes, tweet-id payload + dedup_key")
    func tweetIngest() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")

        let result = try await services.ingestContent(
            .tweet(
                tweetID: "https://x.com/ava/status/123", text: "a brass lamp",
                authorHandle: "ava", authorName: "Ava",
                media: [TweetMedia(url: "https://pbs.example/a.jpg", width: 4, height: 3)]),
            from: twitterSource("https://x.com/ava/status/123", handle: "ava"), into: c.id)
        let asset = result.asset

        #expect(result.wasDeduplicated == false)
        #expect(asset.kind == .tweet)
        #expect(asset.blobHash == nil)
        #expect(asset.dedupKey == "123")                // numeric id extracted
        #expect(asset.content == .tweet(TweetContent(
            tweetID: "123", text: "a brass lamp", authorHandle: "ava", authorName: "Ava",
            media: [TweetMedia(url: "https://pbs.example/a.jpg", width: 4, height: 3)],
            cardImageBlobHash: nil)))

        // Provenance URL was aligned to the deterministic permalink.
        #expect(try await services.getAsset(id: asset.id).source.originalURL
                == "https://x.com/i/status/123")
    }

    @Test("the same tweet captured via x.com / twitter.com dedups to one asset")
    func tweetDedup() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")

        let a = try await services.ingestContent(
            .tweet(tweetID: "555", text: "one"),
            from: twitterSource("https://x.com/ava/status/555"), into: c.id)
        // Different URL host + tracking param, same tweet id → dedup.
        let b = try await services.ingestContent(
            .tweet(tweetID: "https://twitter.com/ava/statuses/555?s=20", text: "one"),
            from: twitterSource("https://twitter.com/ava/statuses/555?s=20"), into: c.id)

        #expect(b.wasDeduplicated == true)
        #expect(a.asset.id == b.asset.id)
        #expect(try await services.collectionItems(in: c.id, includeArchived: false).count == 1)
    }

    @Test("a tweet with no usable id is rejected (.emptyTweet)")
    func invalidTweetIDRejected() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")
        await #expect(throws: AtelierError.emptyTweet) {
            try await services.ingestContent(
                .tweet(tweetID: "https://x.com/ava", text: "no id here"),
                from: twitterSource("https://x.com/ava"), into: c.id)
        }
    }

    @Test("a tweet with an id but no substance (no text, no media) is rejected (.emptyTweet)")
    func emptyTweetRejected() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")
        await #expect(throws: AtelierError.emptyTweet) {
            try await services.ingestContent(
                .tweet(tweetID: "777", text: "   "),
                from: twitterSource("https://x.com/ava/status/777"), into: c.id)
        }
    }

    @Test("a media-only tweet (no text) is accepted")
    func mediaOnlyTweetAccepted() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")
        let result = try await services.ingestContent(
            .tweet(tweetID: "888", media: [TweetMedia(url: "https://pbs.example/x.jpg")]),
            from: twitterSource("https://x.com/ava/status/888"), into: c.id)
        #expect(result.asset.kind == .tweet)
        #expect(result.asset.payloadValue?.tweet?.text == nil)
        #expect(result.asset.payloadValue?.tweet?.media.count == 1)
    }

    @Test("a tweet is findable through searchAssets by text and by author")
    func tweetSearch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")
        let tweet = try await services.ingestContent(
            .tweet(tweetID: "321", text: "an ornate brass lamp", authorHandle: "lampist"),
            from: twitterSource("https://x.com/lampist/status/321"), into: c.id).asset

        #expect(try await services.searchAssets(text: "ornate").map(\.asset.id) == [tweet.id])
        #expect(try await services.searchAssets(text: "lampist").map(\.asset.id) == [tweet.id])
    }

    // MARK: tweet + card image (003 · C3, Option 3 — hybrid)

    @Test("a tweet ingested WITH a card image lands a blob-backed tweet asset")
    func tweetWithCardImage() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")

        let result = try await services.ingestContent(
            .tweet(tweetID: "https://x.com/ava/status/900", text: "a brass lamp",
                   authorHandle: "ava", authorName: "Ava",
                   media: [TweetMedia(url: "https://pbs.example/a.jpg")]),
            blob: ContentBlobFacts(
                blobHash: "ABCDEF", mimeType: "image/jpeg",
                width: 1200, height: 675, fileSize: 40_000),
            from: twitterSource("https://x.com/ava/status/900", handle: "ava"), into: c.id)
        let asset = result.asset

        // Content identity is intact AND the asset now carries a real blob.
        #expect(asset.kind == .tweet)
        #expect(asset.dedupKey == "900")
        #expect(asset.blobHash == "abcdef")               // canonicalized (lowercased)
        #expect(asset.mimeType == "image/jpeg")
        #expect(asset.width == 1200 && asset.height == 675 && asset.fileSize == 40_000)
        // The exhaustive projection surfaces the blob as the tweet's card image.
        if case .tweet(let t) = asset.content {
            #expect(t.cardImageBlobHash == "abcdef")
            #expect(t.text == "a brass lamp")
        } else {
            Issue.record("expected .tweet content")
        }
    }

    @Test("the same tweet with a DIFFERENT card image still dedups by tweet-id (first wins)")
    func tweetCardImageDedup() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")

        let a = try await services.ingestContent(
            .tweet(tweetID: "901", text: "one"),
            blob: ContentBlobFacts(
                blobHash: "aaa1", mimeType: "image/jpeg", width: 4, height: 3, fileSize: 10),
            from: twitterSource("https://x.com/ava/status/901"), into: c.id)
        // Recapture: same tweet id, different card-image bytes → dedup, no new asset,
        // and the FIRST card image is retained (dedup reuses, never overwrites).
        let b = try await services.ingestContent(
            .tweet(tweetID: "901", text: "one"),
            blob: ContentBlobFacts(
                blobHash: "bbb2", mimeType: "image/jpeg", width: 8, height: 6, fileSize: 20),
            from: twitterSource("https://x.com/ava/status/901"), into: c.id)

        #expect(b.wasDeduplicated == true)
        #expect(a.asset.id == b.asset.id)
        #expect(b.asset.blobHash == "aaa1")               // first card image kept
        #expect(try await services.collectionItems(in: c.id, includeArchived: false).count == 1)
    }

    @Test("invalid card-image blob facts (non-positive dims) are rejected")
    func tweetCardImageInvalidBlob() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Threads")
        await #expect(throws: AtelierError.invalidDimensions) {
            try await services.ingestContent(
                .tweet(tweetID: "902", text: "one"),
                blob: ContentBlobFacts(
                    blobHash: "cafe", mimeType: "image/jpeg", width: 0, height: 3, fileSize: 10),
                from: twitterSource("https://x.com/ava/status/902"), into: c.id)
        }
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
