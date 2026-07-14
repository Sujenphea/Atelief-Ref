//
//  CanvasKindRenderingTests.swift
//  AtelierRefsTests
//
//  003 · O1 — board rendering of media-less kinds. `ElementRendering.assetTileContent`
//  is the shared seam both canvas surfaces (the collection `CanvasContent` and the
//  spaces `SpaceContent`) use to draw a color / link / tweet that has no blob. Byte-
//  backed assets (incl. a tweet/link WITH a card image) keep the `.image` decode path;
//  media-less kinds become a vector swatch / card. Pure + total, so it's unit-tested
//  exhaustively here, plus one end-to-end check that `CanvasContent` wires it in.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Canvas media-less kind rendering (003 · O1)")
struct CanvasKindRenderingTests {

    private func asset(
        kind: AssetKind, blobHash: String? = nil, payload: String? = nil
    ) -> Asset {
        Asset(
            id: UUID(), kind: kind, blobHash: blobHash, mimeType: nil,
            width: nil, height: nil, fileSize: nil, downloadState: .downloaded,
            createdAt: Date(), sourceId: UUID(), payload: payload)
    }

    /// Pull the `FrameStyle` out of a `.frame` content, or fail the test.
    private func frame(_ content: TileContent, _ comment: Comment = "expected a frame") -> FrameStyle? {
        guard case let .frame(style) = content else {
            Issue.record(comment)
            return nil
        }
        return style
    }

    // MARK: - byte-backed kinds take the image path

    @Test("image / video assets → .image (the existing decode path)")
    func byteBackedAreImages() {
        #expect(ElementRendering.assetTileContent(asset(kind: .image, blobHash: "a")) == .image)
        #expect(ElementRendering.assetTileContent(asset(kind: .video, blobHash: "b")) == .image)
        #expect(ElementRendering.assetTileContent(nil) == .image) // defensive: no asset
    }

    // MARK: - color → a solid swatch frame

    @Test("a color asset → a frame filled with its hex + a hairline border")
    func colorSwatch() {
        let payload = AssetPayload(color: ColorPayload(hex: "#ff0000")).jsonString()
        let content = ElementRendering.assetTileContent(asset(kind: .color, payload: payload))
        #expect(content == .frame(FrameStyle(
            fill: RGBAColor(red: 1, green: 0, blue: 0),
            stroke: ElementRendering.swatchHairline,
            strokeWidth: 1,
            cornerRadius: ElementRendering.frameCornerRadius)))
    }

    // MARK: - bare link / text tweet → a labelled card

    @Test("a bare link (no og:image) → a card labelled with its heading")
    func bareLinkCard() {
        let payload = AssetPayload(link: LinkPayload(
            url: "https://example.com/x", title: "A Title", description: nil)).jsonString()
        let style = frame(ElementRendering.assetTileContent(asset(kind: .link, payload: payload)))
        #expect(style?.fill == ElementRendering.mediaLessCardFill)
        #expect(style?.label?.string == "A Title")           // title wins
    }

    @Test("a link with no title falls back to its host on the card")
    func linkHostFallback() {
        let payload = AssetPayload(link: LinkPayload(
            url: "https://example.com/deep/path", title: nil, description: nil)).jsonString()
        let style = frame(ElementRendering.assetTileContent(asset(kind: .link, payload: payload)))
        #expect(style?.label?.string == "example.com")
    }

    @Test("a resolved link (og:image blob) takes the image path, not a card")
    func resolvedLinkIsImage() {
        let payload = AssetPayload(link: LinkPayload(url: "https://example.com/x")).jsonString()
        #expect(ElementRendering.assetTileContent(
            asset(kind: .link, blobHash: "ogimg", payload: payload)) == .image)
    }

    @Test("a text-only tweet (no card image) → a card labelled with its @handle")
    func textTweetCard() {
        let payload = AssetPayload(tweet: TweetPayload(
            tweetID: "1", text: "hi", authorHandle: "ava", authorName: "Ava", media: [])).jsonString()
        let style = frame(ElementRendering.assetTileContent(asset(kind: .tweet, payload: payload)))
        #expect(style?.fill == ElementRendering.mediaLessCardFill)
        #expect(style?.label?.string == "@ava")
    }

    @Test("a tweet WITH a card image takes the image path, not a card")
    func tweetWithCardIsImage() {
        let payload = AssetPayload(tweet: TweetPayload(
            tweetID: "1", text: "hi", authorHandle: "ava", authorName: nil, media: [])).jsonString()
        #expect(ElementRendering.assetTileContent(
            asset(kind: .tweet, blobHash: "card", payload: payload)) == .image)
    }

    @Test("an unknown media-less asset (payload contradicts kind) → a neutral, unlabelled card")
    func unknownNeutralCard() {
        // A color kind with no payload → `.unknown` → a neutral card with no label.
        let style = frame(ElementRendering.assetTileContent(asset(kind: .color, payload: nil)))
        #expect(style?.fill == ElementRendering.mediaLessCardFill)
        #expect(style?.label == nil)
    }

    // MARK: - the shared display helpers (grid + board use these)

    @Test("LinkContent.displayHeading: title → host → url")
    func linkHeading() {
        #expect(LinkContent(url: "https://h.com/p", title: "T", description: nil, imageBlobHash: nil)
            .displayHeading == "T")
        #expect(LinkContent(url: "https://h.com/p", title: "", description: nil, imageBlobHash: nil)
            .displayHeading == "h.com")                       // empty title skipped → host
        #expect(LinkContent(url: "not a url", title: nil, description: nil, imageBlobHash: nil)
            .displayHeading == "not a url")                   // unparseable → raw url
    }

    @Test("TweetContent.displayByline: @handle → name → \"Tweet\"")
    func tweetByline() {
        func tweet(handle: String?, name: String?) -> TweetContent {
            TweetContent(tweetID: "1", text: nil, authorHandle: handle, authorName: name,
                         media: [], cardImageBlobHash: nil)
        }
        #expect(tweet(handle: "ava", name: "Ava").displayByline == "@ava")   // bare → prefixed
        #expect(tweet(handle: "@ava", name: nil).displayByline == "@ava")    // already @ → NOT doubled
        #expect(tweet(handle: nil, name: "Ava").displayByline == "Ava")
        #expect(tweet(handle: "", name: nil).displayByline == "Tweet")
    }

    // MARK: - end-to-end: CanvasContent wires the mapping in

    @Test("CanvasContent.content(for:) draws a color item as a swatch, an image as .image")
    func canvasContentWiresMediaLess() {
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let sourceID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        func detail(_ a: Asset) -> CollectionItemDetail {
            CollectionItemDetail(
                item: CollectionItem(id: UUID(), collectionID: UUID(), assetID: a.id, addedAt: Date()),
                asset: a, source: source)
        }
        let colorPayload = AssetPayload(color: ColorPayload(hex: "#00ff00")).jsonString()
        let colorAsset = Asset(
            id: UUID(), kind: .color, blobHash: nil, mimeType: nil, width: nil, height: nil,
            fileSize: nil, downloadState: .downloaded, createdAt: Date(), sourceId: sourceID,
            payload: colorPayload)
        let imageAsset = Asset(
            id: UUID(), kind: .image, blobHash: "img", mimeType: "image/png", width: 10, height: 10,
            fileSize: 10, downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)

        let content = CanvasContent(items: [detail(colorAsset), detail(imageAsset)], store: store)
        #expect(content.content(for: content.tiles[0]) == .frame(FrameStyle(
            fill: RGBAColor(red: 0, green: 1, blue: 0),
            stroke: ElementRendering.swatchHairline,
            strokeWidth: 1,
            cornerRadius: ElementRendering.frameCornerRadius)))
        #expect(content.content(for: content.tiles[1]) == .image)
    }
}
