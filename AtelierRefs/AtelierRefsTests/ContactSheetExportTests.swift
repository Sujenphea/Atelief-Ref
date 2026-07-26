//
//  ContactSheetExportTests.swift
//  AtelierRefsTests
//
//  052 · B4 — the collection contact-sheet bridge is PURE (given an image-URL
//  resolver), so the row→element GENERATION (masonry cell geometry, caption
//  reservation, gap-free skips) and the caption source are unit-tested host-free.
//  The heavy render arithmetic is proven in the package + `MoodboardExportTests`;
//  here we pin B4's own translation of `CollectionItemDetail` into a masonry
//  `MoodboardExport.Mapping`.
//

import AppKit
import AtelierCore
import AtelierExport
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Factories

private enum Fixture {

    static func asset(
        kind: AssetKind = .image, name: String? = nil,
        w: Int? = 10, h: Int? = 10, payload: String? = nil
    ) -> Asset {
        Asset(
            id: UUID(), kind: kind, blobHash: "blob", mimeType: nil,
            width: w, height: h, duration: nil, fileSize: 10,
            downloadState: .downloaded, createdAt: Date(), name: name,
            sourceId: UUID(), payload: payload)
    }

    static func colorPayload(_ hex: String) -> String {
        AssetPayload(color: ColorPayload(hex: hex)).jsonString()!
    }

    static func source(
        title: String? = nil, authorHandle: String? = nil, originalURL: String? = nil
    ) -> Source {
        Source(
            id: UUID(), platform: .web, originalURL: originalURL,
            authorHandle: authorHandle, authorName: nil, title: title, capturedAt: Date())
    }

    static func detail(_ asset: Asset, source: Source = source()) -> CollectionItemDetail {
        CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: UUID(), assetID: asset.id, addedAt: Date()),
            asset: asset, source: source)
    }

    /// A real on-disk decodable PNG (2×2), removed after `body`.
    static func withTempPNG(_ body: (URL) throws -> Void) rethrows {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try! png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    static func always(_ url: URL) -> (Asset) -> URL? { { _ in url } }
    static let never: (Asset) -> URL? = { _ in nil }

    /// Masonry cell math is division-based, so geometry is compared with a small
    /// tolerance rather than exact `==` (float noise: a 252.0 that is really
    /// 251.9999…). 0.01pt is far tighter than any visible difference.
    static func near(_ a: CGFloat, _ b: Double, _ tol: Double = 0.01) -> Bool {
        abs(Double(a) - b) < tol
    }
    static func near(_ a: CGRect, x: Double, y: Double, w: Double, h: Double) -> Bool {
        near(a.minX, x) && near(a.minY, y) && near(a.width, w) && near(a.height, h)
    }

    /// Column geometry the tests assert against (see ``ContactSheetExport.Defaults``).
    static let colWidth = ContactSheetExport.Defaults.columnWidth      // 240
    static let spacing = ContactSheetExport.Defaults.spacing           // 12
    static let capBlock =
        ContactSheetExport.Defaults.captionGap + ContactSheetExport.Defaults.captionHeight // 22
}

// MARK: - Selection-or-collection rows

@Suite("ContactSheetExport: rows")
struct ContactSheetRowsTests {

    @Test("Empty selection considers the whole collection")
    func emptySelectionIsWholeCollection() {
        let a = Fixture.detail(Fixture.asset())
        let b = Fixture.detail(Fixture.asset())
        #expect(ContactSheetExport.rows(items: [a, b], selectedIDs: []).count == 2)
    }

    @Test("A selection filters to the selected membership ids")
    func selectionFilters() {
        let a = Fixture.detail(Fixture.asset())
        let b = Fixture.detail(Fixture.asset())
        let rows = ContactSheetExport.rows(items: [a, b], selectedIDs: [b.item.id])
        #expect(rows.map(\.item.id) == [b.item.id])
    }
}

// MARK: - Captions

@Suite("ContactSheetExport: caption")
struct ContactSheetCaptionTests {

    @Test("Asset name wins over every source field")
    func namePreferred() {
        let d = Fixture.detail(
            Fixture.asset(name: "  Sunset  "),
            source: Fixture.source(title: "T", authorHandle: "@h", originalURL: "https://x.com/p"))
        #expect(ContactSheetExport.caption(for: d) == "Sunset")  // trimmed
    }

    @Test("Falls back title → handle → host, else empty")
    func fallbackChain() {
        let title = Fixture.detail(Fixture.asset(name: nil), source: Fixture.source(title: "Board"))
        #expect(ContactSheetExport.caption(for: title) == "Board")

        let handle = Fixture.detail(Fixture.asset(name: nil), source: Fixture.source(authorHandle: "@ana"))
        #expect(ContactSheetExport.caption(for: handle) == "@ana")

        let host = Fixture.detail(
            Fixture.asset(name: nil), source: Fixture.source(originalURL: "https://images.example.com/a.jpg"))
        #expect(ContactSheetExport.caption(for: host) == "images.example.com")

        let none = Fixture.detail(Fixture.asset(name: nil), source: Fixture.source())
        #expect(ContactSheetExport.caption(for: none) == "")
    }
}

// MARK: - Mapping / masonry geometry

@Suite("ContactSheetExport: map")
struct ContactSheetMapTests {

    private func config(columns: Int, captions: Bool) -> ContactSheetConfig {
        ContactSheetConfig(columns: columns, captions: captions)
    }

    @Test("Square images pack round-robin into columns; no captions ⇒ one element each")
    func roundRobinNoCaptions() throws {
        try Fixture.withTempPNG { url in
            let details = (0..<2).map { _ in Fixture.detail(Fixture.asset()) } // 10×10 ⇒ aspect 1
            let map = ContactSheetExport.map(
                details: details, config: config(columns: 2, captions: false),
                imageURL: Fixture.always(url))

            #expect(map.elements.count == 2)
            #expect(map.skipped == 0)
            // col0 at x0, col1 at x = colWidth + spacing; both 240×240 at y0.
            #expect(Fixture.near(map.elements[0].rect, x: 0, y: 0, w: Fixture.colWidth, h: Fixture.colWidth))
            #expect(Fixture.near(map.elements[1].rect,
                x: Fixture.colWidth + Fixture.spacing, y: 0, w: Fixture.colWidth, h: Fixture.colWidth))
            for e in map.elements { if case .image = e.content {} else { Issue.record("expected image") } }
        }
    }

    @Test("Captions add a text element below each image, in reserved space")
    func captionsBelowImage() throws {
        try Fixture.withTempPNG { url in
            let d = Fixture.detail(Fixture.asset(name: "Ref"))
            let map = ContactSheetExport.map(
                details: [d], config: config(columns: 1, captions: true),
                imageURL: Fixture.always(url))

            #expect(map.elements.count == 2)
            let image = map.elements[0], caption = map.elements[1]
            #expect(Fixture.near(image.rect, x: 0, y: 0, w: Fixture.colWidth, h: Fixture.colWidth))
            #expect(image.z == 0)
            // Caption sits gap below the image, height = captionHeight.
            #expect(Fixture.near(caption.rect,
                x: 0, y: Fixture.colWidth + ContactSheetExport.Defaults.captionGap,
                w: Fixture.colWidth, h: ContactSheetExport.Defaults.captionHeight))
            #expect(caption.z == 1)
            guard case .text(let style) = caption.content else { Issue.record("expected text"); return }
            #expect(style.string == "Ref")
        }
    }

    @Test("Caption height is reserved so the next cell in a column doesn't overlap")
    func captionReservationStacks() throws {
        try Fixture.withTempPNG { url in
            // Two squares in ONE column, captions on: cell height = image(240)+block(22)=262,
            // so the 2nd image starts at 262 + spacing(12) = 274 (not 252 — which would
            // overlap the first caption).
            let details = (0..<2).map { _ in Fixture.detail(Fixture.asset(name: "n")) }
            let map = ContactSheetExport.map(
                details: details, config: config(columns: 1, captions: true),
                imageURL: Fixture.always(url))
            let images = map.elements.filter { if case .image = $0.content { return true }; return false }
            #expect(images.count == 2)
            #expect(Fixture.near(images[0].rect.minY, 0))
            #expect(Fixture.near(images[1].rect.minY, Fixture.colWidth + Fixture.capBlock + Fixture.spacing)) // 274
        }
    }

    @Test("An un-resolvable row is skipped AND takes no cell (grid stays gap-free)")
    func skipTakesNoCell() throws {
        try Fixture.withTempPNG { url in
            // [image, link-with-no-url, image] in one column, captions off.
            let details = [
                Fixture.detail(Fixture.asset()),
                Fixture.detail(Fixture.asset(kind: .link)),   // never resolver ⇒ no url ⇒ skip
                Fixture.detail(Fixture.asset()),
            ]
            let resolver: (Asset) -> URL? = { $0.kind == .link ? nil : url }
            let map = ContactSheetExport.map(
                details: details, config: config(columns: 1, captions: false), imageURL: resolver)

            #expect(map.skipped == 1)
            #expect(map.elements.count == 2)
            // 2nd kept image sits directly under the 1st (240 + spacing), NOT at slot 3.
            #expect(Fixture.near(map.elements[1].rect.minY, Fixture.colWidth + Fixture.spacing)) // 252
        }
    }

    @Test("A colour asset maps to a swatch and registers no URL")
    func colorSwatch() throws {
        let asset = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#00ff88"))
        let map = ContactSheetExport.map(
            details: [Fixture.detail(asset)], config: config(columns: 1, captions: false),
            imageURL: Fixture.never)
        #expect(map.skipped == 0)
        #expect(map.imageURLs.isEmpty)
        guard case .color(let rgba) = try #require(map.elements.first).content else {
            Issue.record("expected color"); return
        }
        #expect(rgba == RGBA(hex: "#00ff88"))
    }

    @Test("Image ids resolve to their registered URLs")
    func registersURLs() throws {
        try Fixture.withTempPNG { url in
            let asset = Fixture.asset()
            let map = ContactSheetExport.map(
                details: [Fixture.detail(asset)], config: config(columns: 3, captions: false),
                imageURL: Fixture.always(url))
            #expect(map.imageURLs[asset.id.uuidString] == url)
        }
    }

    @Test("Empty / all-skipped input yields an empty mapping")
    func emptyMapping() {
        let map = ContactSheetExport.map(
            details: [Fixture.detail(Fixture.asset(kind: .link))],
            config: config(columns: 4, captions: true), imageURL: Fixture.never)
        #expect(map.elements.isEmpty)
        #expect(map.skipped == 1)
    }
}

// MARK: - End-to-end (generation → pages → render)

@Suite("ContactSheetExport: render smoke")
struct ContactSheetRenderTests {

    @Test("A generated sheet lays out onto pages and renders a non-empty PDF")
    func rendersPDF() throws {
        try Fixture.withTempPNG { url in
            let details = (0..<5).map { Fixture.detail(Fixture.asset(name: "img\($0)")) }
            let map = ContactSheetExport.map(
                details: details, config: ContactSheetConfig(columns: 3, captions: true),
                imageURL: Fixture.always(url))
            let config = ExportConfig(format: .pdf, pdfLayout: .singlePage)
            let pages = MoodboardExport.pages(for: map.elements, config: config)
            #expect(!pages.isEmpty)

            let result = try MoodboardExport.render(
                pages: pages, provider: MoodboardURLImageProvider(urls: map.imageURLs),
                config: config, isCancelled: { false }, onProgress: { _ in })
            #expect(!result.data.isEmpty)
        }
    }
}
