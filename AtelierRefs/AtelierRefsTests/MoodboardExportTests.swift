//
//  MoodboardExportTests.swift
//  AtelierRefsTests
//
//  052 · B3 — the app↔`AtelierExport` bridge is PURE (given an image-URL
//  resolver), so the row→element mapping, the selection-or-board rule, the
//  config→page plan, and the URL image provider are all unit-tested host-free.
//  The heavy render arithmetic is covered in the package's own suite; here we
//  assert the app's translation of `SpaceItemDetail` / `AssetContent` /
//  `ElementStyle` into the package model.
//

import AppKit
import AtelierCore
import AtelierExport
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

// MARK: - Factories

private enum Fixture {

    static func asset(kind: AssetKind, blobHash: String? = nil, payload: String? = nil) -> Asset {
        Asset(
            id: UUID(), kind: kind, blobHash: blobHash, mimeType: nil,
            width: 10, height: 10, duration: nil, fileSize: 10,
            downloadState: .downloaded, createdAt: Date(), sourceId: UUID(), payload: payload)
    }

    static func colorPayload(_ hex: String) -> String {
        AssetPayload(color: ColorPayload(hex: hex)).jsonString()!
    }

    static func item(
        kind: SpaceItemKind,
        assetID: UUID? = nil,
        x: Double = 0, y: Double = 0, w: Double = 10, h: Double = 10, z: Int = 0,
        style: ElementStyle? = nil
    ) -> SpaceItem {
        SpaceItem(
            id: UUID(), spaceID: UUID(), kind: kind, assetID: assetID,
            x: x, y: y, w: w, h: h, z: z, style: style?.jsonString(),
            createdAt: Date(), updatedAt: Date())
    }

    static func detail(_ item: SpaceItem, asset: Asset? = nil) -> SpaceItemDetail {
        SpaceItemDetail(item: item, asset: asset, source: nil)
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

    /// An image-URL resolver that hands the same URL to every asset.
    static func always(_ url: URL) -> (Asset) -> URL? { { _ in url } }
    static let never: (Asset) -> URL? = { _ in nil }
}

// MARK: - Selection-or-board rows (B3 scope)

@Suite("MoodboardExport: rows")
struct MoodboardRowsTests {

    @Test("Empty selection considers the whole board")
    func emptySelectionIsWholeBoard() {
        let a = Fixture.detail(Fixture.item(kind: .frame))
        let b = Fixture.detail(Fixture.item(kind: .text))
        let rows = MoodboardExport.rows(items: [a, b], selected: [])
        #expect(rows.count == 2)
    }

    @Test("A selection filters to the selected item ids")
    func selectionFilters() {
        let a = Fixture.item(kind: .frame)
        let b = Fixture.item(kind: .text)
        let rows = MoodboardExport.rows(
            items: [Fixture.detail(a), Fixture.detail(b)], selected: [b.id])
        #expect(rows.count == 1)
        #expect(rows.first?.item.id == b.id)
    }
}

// MARK: - Mapping

@Suite("MoodboardExport: map")
struct MoodboardMapTests {

    @Test("A colour asset maps to a swatch")
    func colorSwatch() throws {
        let asset = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#ff8800"))
        let detail = Fixture.detail(Fixture.item(kind: .asset, assetID: asset.id), asset: asset)
        let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.never)
        #expect(mapping.skipped == 0)
        guard case .color(let rgba) = try #require(mapping.elements.first).content else {
            Issue.record("expected .color"); return
        }
        #expect(rgba == RGBA(hex: "#ff8800"))
    }

    @Test("A board renders on the board's own dark ground")
    func boardKeepsItsGround() {
        let asset = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#ff8800"))
        let detail = Fixture.detail(Fixture.item(kind: .asset, assetID: asset.id), asset: asset)
        // A text element created on a board persists WHITE, so a white page made every
        // caption the user typed invisible. The export carries the ground it was
        // composed against.
        #expect(MoodboardExport.map(details: [detail], imageURL: Fixture.never).background
            == .boardGround)
    }

    @Test("Text with no stored colour matches the board's default, not black")
    func colourlessTextIsWhite() throws {
        var style = ElementStyle()
        style.text = "hi"
        style.fontSize = 17
        let item = Fixture.item(kind: .text, style: style)
        let mapping = MoodboardExport.map(details: [Fixture.detail(item)], imageURL: Fixture.never)
        guard case .text(let style) = try #require(mapping.elements.first).content else {
            Issue.record("expected .text"); return
        }
        // Was `.black`: the same element drew white on the board and black in the
        // export. One default, named once in `ElementRendering`.
        #expect(style.color == .white)
    }

    @Test("A colour with an unparseable hex is skipped")
    func badColorSkipped() {
        let asset = Fixture.asset(kind: .color, payload: Fixture.colorPayload("nothex"))
        let detail = Fixture.detail(Fixture.item(kind: .asset, assetID: asset.id), asset: asset)
        let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.never)
        #expect(mapping.elements.isEmpty)
        #expect(mapping.skipped == 1)
    }

    @Test("An image asset maps to an image and registers its URL")
    func imageAsset() throws {
        try Fixture.withTempPNG { url in
            let asset = Fixture.asset(kind: .image, blobHash: "abc123")
            let detail = Fixture.detail(
                Fixture.item(kind: .asset, assetID: asset.id, x: 5, y: 6, w: 20, h: 30, z: 4),
                asset: asset)
            let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.always(url))
            let element = try #require(mapping.elements.first)
            #expect(element.rect == CGRect(x: 5, y: 6, width: 20, height: 30))
            #expect(element.z == 4)
            guard case .image(let id) = element.content else { Issue.record("expected .image"); return }
            #expect(mapping.imageURLs[id] == url)
        }
    }

    @Test("An image asset with no resolvable URL is skipped")
    func imageWithoutURLSkipped() {
        let asset = Fixture.asset(kind: .image, blobHash: "abc123")
        let detail = Fixture.detail(Fixture.item(kind: .asset, assetID: asset.id), asset: asset)
        let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.never)
        #expect(mapping.elements.isEmpty)
        #expect(mapping.skipped == 1)
    }

    @Test("A text element maps from its style")
    func textElement() throws {
        let style = ElementStyle(text: "Hello", fontSize: 20, textColor: "#ff0000")
        let detail = Fixture.detail(Fixture.item(kind: .text, style: style))
        let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.never)
        guard case .text(let text) = try #require(mapping.elements.first).content else {
            Issue.record("expected .text"); return
        }
        #expect(text.string == "Hello")
        #expect(text.fontSize == 20)
        #expect(text.color == RGBA(hex: "#ff0000"))
    }

    @Test("A frame element maps fill / stroke / label")
    func frameElement() throws {
        let style = ElementStyle(
            text: "Group", fillColor: "#112233", strokeColor: "#445566", strokeWidth: 3)
        let detail = Fixture.detail(Fixture.item(kind: .frame, style: style))
        let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.never)
        guard case .frame(let frame) = try #require(mapping.elements.first).content else {
            Issue.record("expected .frame"); return
        }
        #expect(frame.fill == RGBA(hex: "#112233"))
        #expect(frame.stroke == RGBA(hex: "#445566"))
        #expect(frame.strokeWidth == 3)
        #expect(frame.label?.string == "Group")
    }

    @Test("An asset-kind row whose asset was reaped is skipped")
    func reapedAssetRowSkipped() {
        let detail = Fixture.detail(Fixture.item(kind: .asset, assetID: UUID()), asset: nil)
        let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.never)
        #expect(mapping.elements.isEmpty)
        #expect(mapping.skipped == 1)
    }

    @Test("Mapping preserves order and counts a mix")
    func mixedCounts() {
        let color = Fixture.asset(kind: .color, payload: Fixture.colorPayload("#00ff00"))
        let details = [
            Fixture.detail(Fixture.item(kind: .asset, assetID: color.id, z: 0), asset: color),
            Fixture.detail(Fixture.item(kind: .text, z: 1, style: ElementStyle(text: "x"))),
            Fixture.detail(Fixture.item(kind: .asset, assetID: UUID()), asset: nil),  // skip
        ]
        let mapping = MoodboardExport.map(details: details, imageURL: Fixture.never)
        #expect(mapping.elements.count == 2)
        #expect(mapping.skipped == 1)
    }
}

// MARK: - Page plan

@Suite("MoodboardExport: pages")
struct MoodboardPagesTests {

    private func imageEls(_ rects: [CGRect]) -> [MoodboardElement] {
        rects.enumerated().map {
            MoodboardElement(rect: $0.element, z: $0.offset, content: .image(id: "\($0.offset)"))
        }
    }

    @Test("PNG is always one page")
    func png() {
        let pages = MoodboardExport.pages(
            for: imageEls([CGRect(x: 0, y: 0, width: 100, height: 1000)]),
            config: ExportConfig(format: .png, pngScale: 2))
        #expect(pages.count == 1)
    }

    @Test("PDF single-page is one page")
    func pdfSingle() {
        let pages = MoodboardExport.pages(
            for: imageEls([CGRect(x: 0, y: 0, width: 100, height: 1000)]),
            config: ExportConfig(format: .pdf, pdfLayout: .singlePage))
        #expect(pages.count == 1)
    }

    @Test("PDF letter-pages tiles a tall board across pages")
    func pdfLetter() {
        let pages = MoodboardExport.pages(
            for: imageEls([CGRect(x: 0, y: 0, width: 100, height: 1000)]),
            config: ExportConfig(format: .pdf, pdfLayout: .letterPages))
        #expect(pages.count > 1)
    }

    @Test("An empty board plans no pages")
    func empty() {
        #expect(MoodboardExport.pages(for: [], config: ExportConfig()).isEmpty)
    }
}

// MARK: - Provider + config

@Suite("MoodboardExport: provider + config")
struct MoodboardProviderConfigTests {

    @Test("Provider decodes a known id and misses an unknown one")
    func provider() throws {
        Fixture.withTempPNG { url in
            let provider = MoodboardURLImageProvider(urls: ["k": url])
            #expect(provider.cgImage(forID: "k", maxPixelSize: 64) != nil)
            #expect(provider.cgImage(forID: "missing", maxPixelSize: 64) == nil)
        }
    }

    @Test("File extension follows the format")
    func fileExtension() {
        #expect(ExportConfig(format: .pdf).fileExtension == "pdf")
        #expect(ExportConfig(format: .png).fileExtension == "png")
    }

    @Test("End-to-end: map → pages → render yields non-empty PDF")
    func endToEnd() throws {
        try Fixture.withTempPNG { url in
            let asset = Fixture.asset(kind: .image, blobHash: "abc")
            let detail = Fixture.detail(
                Fixture.item(kind: .asset, assetID: asset.id, w: 100, h: 100), asset: asset)
            let mapping = MoodboardExport.map(details: [detail], imageURL: Fixture.always(url))
            let config = ExportConfig(format: .pdf, pdfLayout: .singlePage)
            let pages = MoodboardExport.pages(for: mapping.elements, config: config)
            let result = try MoodboardExport.render(
                pages: pages,
                provider: MoodboardURLImageProvider(urls: mapping.imageURLs),
                config: config, background: mapping.background,
                isCancelled: { false }, onProgress: { _ in })
            #expect(!result.data.isEmpty)
            #expect(result.skipped.isEmpty)
        }
    }
}
