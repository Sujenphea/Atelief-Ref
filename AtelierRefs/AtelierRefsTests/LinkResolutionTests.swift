//
//  LinkResolutionTests.swift
//  AtelierRefsTests
//
//  001 · C2b — the app-side glue that turns a resolved page into a `.link` ingest
//  input. The resolver + SSRF guard + og-tag parser are exhaustively tested in
//  AtelierIngestion; these pin the pure decision the model layer adds: a resolved
//  page WITH an og:image → a card-image link (contentWithBytes); WITHOUT → a
//  media-less link; a FAILED resolution → a bare link keyed by the URL. Plus the
//  user-input → http(s) URL normalization.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Link resolution → ingest input (001 · C2b)")
struct LinkResolutionTests {

    private let folder = UUID()
    private let pageURL = URL(string: "https://example.com/article")!

    /// The `LinkPayload` behind a link content input, or nil if the input isn't a link.
    private func linkPayload(_ input: IngestInput) -> LinkPayload? {
        switch input.source {
        case let .content(draft): return draft.payload.link
        case let .contentWithBytes(draft, _): return draft.payload.link
        case .bytes: return nil
        }
    }

    @Test("a resolved page WITH an og:image → a card-image link (contentWithBytes)")
    func withImage() {
        let page = ResolvedPage(title: "A Title", description: "A blurb",
                                imageURL: URL(string: "https://cdn/card.png"))
        let input = IngestionModel.linkInput(
            for: pageURL, page: page, imageData: Data([1, 2, 3]), into: folder)

        #expect(input.provenance.platform == .web)
        #expect(input.provenance.originalURL == pageURL.absoluteString)
        #expect(input.provenance.title == "A Title")
        #expect(input.collectionID == folder)
        guard case let .contentWithBytes(draft, image) = input.source else {
            Issue.record("expected a contentWithBytes source"); return
        }
        #expect(draft.kind == .link)
        #expect(draft.payload.link?.title == "A Title")
        #expect(draft.payload.link?.description == "A blurb")
        #expect(draft.payload.link?.url == pageURL.absoluteString)
        guard case let .data(bytes) = image else { Issue.record("expected .data image"); return }
        #expect(bytes == Data([1, 2, 3]))
    }

    @Test("a resolved page with NO image (or the image fetch failed) → a media-less link")
    func withoutImage() {
        let page = ResolvedPage(title: "T", description: "D", imageURL: nil)
        let input = IngestionModel.linkInput(for: pageURL, page: page, imageData: nil, into: folder)
        guard case .content = input.source else { Issue.record("expected a media-less content source"); return }
        #expect(linkPayload(input)?.title == "T")
        #expect(linkPayload(input)?.description == "D")
    }

    @Test("a FAILED resolution (nil page) still yields a bare link keyed by the URL")
    func failedResolutionBareLink() {
        let input = IngestionModel.linkInput(for: pageURL, page: nil, imageData: nil, into: folder)
        guard case .content = input.source else { Issue.record("expected a media-less content source"); return }
        #expect(linkPayload(input)?.url == pageURL.absoluteString)
        #expect(linkPayload(input)?.title == nil)     // nothing resolved
        #expect(input.provenance.title == nil)
    }

    // MARK: - webURL(fromUserInput:)

    @Test("scheme-less input gets https://; http(s) is kept; junk / non-web → nil")
    func webURLNormalization() {
        #expect(IngestionModel.webURL(fromUserInput: "example.com/x")?.absoluteString == "https://example.com/x")
        #expect(IngestionModel.webURL(fromUserInput: "  https://x.io/a  ")?.absoluteString == "https://x.io/a")
        #expect(IngestionModel.webURL(fromUserInput: "http://plain.test")?.absoluteString == "http://plain.test")
        #expect(IngestionModel.webURL(fromUserInput: "") == nil)
        #expect(IngestionModel.webURL(fromUserInput: "ftp://host/x") == nil)   // wrong scheme
        #expect(IngestionModel.webURL(fromUserInput: "not a url") == nil)      // no host / spaces
    }
}
