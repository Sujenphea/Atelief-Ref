//
//  CollectionSiteExportTests.swift
//  AtelierRefsTests
//
//  014 · S3 — the collection→web-page mapping. Pure given the two URL
//  resolvers, so every case below runs host-free: what becomes a cell, what
//  becomes a file, what becomes a reported skip, and how two refs that would
//  land on the same path are pulled apart.
//
//  The page template itself is golden-file tested in the package
//  (`StaticSiteRendererTests`); the filename grammar is in `AssetExportTests`.
//  This file covers only the seam between them.
//

import AtelierCore
import AtelierExport
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Collection → web page: mapping")
struct CollectionSiteExportTests {

    // MARK: - Fixtures

    /// A real on-disk file so `AssetExport.exportItem`'s existence check (5A)
    /// passes; removed by the caller's `defer`.
    private static func makeBlob(_ directory: URL, _ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
        return url
    }

    private func withTempDirectory(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-map-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func detail(
        kind: AssetKind = .image,
        blobHash: String? = "abcdef1234567890",
        width: Int? = 1600,
        height: Int? = 1000,
        name: String? = nil,
        title: String? = nil,
        originalURL: String? = nil,
        payload: String? = nil
    ) -> CollectionItemDetail {
        let assetID = UUID()
        let sourceID = UUID()
        let asset = Asset(
            id: assetID, kind: kind, blobHash: blobHash,
            mimeType: kind == .video ? "video/mp4" : "image/png",
            width: width, height: height, duration: kind == .video ? 12 : nil,
            fileSize: 100, downloadState: .downloaded, createdAt: Date(),
            name: name, sourceId: sourceID, payload: payload)
        return CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date()),
            asset: asset,
            source: Source(
                id: sourceID, platform: .web, originalURL: originalURL,
                title: title, capturedAt: Date()))
    }

    /// A colour asset — media-less, so its content comes from the payload.
    private func colorDetail(hex: String) -> CollectionItemDetail {
        detail(kind: .color, blobHash: nil, width: nil, height: nil,
               payload: AssetPayload(color: ColorPayload(hex: hex)).jsonString())
    }

    private func plan(
        _ details: [CollectionItemDetail],
        config: SiteExportConfig = SiteExportConfig(),
        blobURL: @escaping (Asset) -> URL?,
        posterURL: @escaping (Asset) -> URL? = { _ in nil }
    ) -> CollectionSiteExport.Plan {
        CollectionSiteExport.plan(
            title: "Studio", details: details, config: config,
            blobURL: blobURL, posterURL: posterURL)
    }

    // MARK: - Rows (selection-or-all)

    @Test("With no selection every row is exported; with one, only it")
    func rowsRule() {
        let a = detail()
        let b = detail()
        #expect(ExportScope.rows(items: [a, b], selectedIDs: []).count == 2)
        #expect(ExportScope.rows(items: [a, b], selectedIDs: [b.item.id])
            .map(\.item.id) == [b.item.id])
    }

    // MARK: - Mapping

    @Test("An image becomes one cell and one file, named by AssetExport")
    func imageMapsToCellAndFile() {
        withTempDirectory { temp in
            let blob = Self.makeBlob(temp, "blob.png")
            let row = detail(title: "Sunset study")
            let result = plan([row], blobURL: { _ in blob })

            #expect(result.skipped == 0)
            #expect(result.gallery.items.count == 1)
            #expect(result.assets == [
                SiteAsset(source: blob, filename: "Sunset study-abcdef12.png"),
            ])
            #expect(result.gallery.items[0].media
                == .image(file: "Sunset study-abcdef12.png",
                          pixelWidth: 1600, pixelHeight: 1000))
        }
    }

    @Test("A video maps to its POSTER — the video file is never in the plan")
    func videoUsesPoster() {
        withTempDirectory { temp in
            let movie = Self.makeBlob(temp, "clip.mp4")
            let poster = Self.makeBlob(temp, "poster.jpg")
            let row = detail(kind: .video, width: 1920, height: 1080, title: "Rooftop")

            let result = plan([row], blobURL: { _ in movie }, posterURL: { _ in poster })

            #expect(result.assets.map(\.source) == [poster])
            #expect(result.assets.map(\.filename) == ["Rooftop-abcdef12.jpg"])
            #expect(result.gallery.items[0].media
                == .video(posterFile: "Rooftop-abcdef12.jpg",
                          pixelWidth: 1920, pixelHeight: 1080))
            // The .mp4 appears nowhere.
            #expect(!result.assets.contains { $0.source.pathExtension == "mp4" })
        }
    }

    @Test("A video with no poster on disk is a reported skip, not a broken cell")
    func videoWithoutPosterSkips() {
        withTempDirectory { temp in
            let movie = Self.makeBlob(temp, "clip.mp4")
            let result = plan(
                [detail(kind: .video)],
                blobURL: { _ in movie },
                posterURL: { _ in temp.appendingPathComponent("missing.jpg") })

            #expect(result.skipped == 1)
            #expect(result.gallery.isEmpty)
            #expect(result.assets.isEmpty)
        }
    }

    @Test("A colour ref becomes a cell with no file at all")
    func colourNeedsNoFile() {
        let result = plan([colorDetail(hex: "#C8402F")], blobURL: { _ in nil })
        #expect(result.skipped == 0)
        #expect(result.assets.isEmpty)
        #expect(result.gallery.items[0].media == .color(hex: "#C8402F"))
    }

    @Test("A colour that isn't parseable is skipped rather than emitted raw")
    func badColourSkips() {
        let result = plan([colorDetail(hex: "nothex")], blobURL: { _ in nil })
        #expect(result.skipped == 1)
        #expect(result.gallery.isEmpty)
    }

    @Test("A missing blob is counted and reported, never silently dropped")
    func missingBlobSkips() {
        withTempDirectory { temp in
            let present = Self.makeBlob(temp, "here.png")
            let ghost = temp.appendingPathComponent("gone.png")   // never created
            var first = true
            let result = plan([detail(title: "Here"), detail(title: "Gone")], blobURL: { _ in
                defer { first = false }
                return first ? present : ghost
            })

            #expect(result.skipped == 1)
            #expect(result.gallery.items.count == 1)
            #expect(result.assets.count == 1)
        }
    }

    @Test("A media-less link row has nothing to show and is skipped")
    func mediaLessSkips() {
        let result = plan([detail(kind: .link, blobHash: nil)], blobURL: { _ in nil })
        #expect(result.skipped == 1)
        #expect(result.gallery.isEmpty)
    }

    @Test("An empty collection plans to nothing — the action is disabled, not empty-written")
    func emptyCollection() {
        let result = plan([], blobURL: { _ in nil })
        #expect(result.isEmpty)
        #expect(result.assets.isEmpty)
        #expect(result.skipped == 0)
    }

    // MARK: - Captions + provenance

    @Test("The caption is the contact sheet's, so a ref reads the same in both")
    func captionsShared() {
        withTempDirectory { temp in
            let blob = Self.makeBlob(temp, "b.png")
            let row = detail(name: "Named", title: "Titled")
            let result = plan([row], blobURL: { _ in blob })
            #expect(result.gallery.items[0].caption == ContactSheetExport.caption(for: row))
            #expect(result.gallery.items[0].caption == "Named")
        }
    }

    @Test("Both switches ride on the gallery, so the renderer decides once")
    func switchesRideOnGallery() {
        withTempDirectory { temp in
            let blob = Self.makeBlob(temp, "b.png")
            let row = detail(title: "T", originalURL: "https://example.com/a")

            let on = plan([row], config: SiteExportConfig(captions: true, sourceLinks: true),
                          blobURL: { _ in blob })
            #expect(on.gallery.includeCaptions)
            #expect(on.gallery.includeSources)
            #expect(on.gallery.items[0].sourceURL == "https://example.com/a")

            let off = plan([row], config: SiteExportConfig(captions: false, sourceLinks: false),
                           blobURL: { _ in blob })
            #expect(!off.gallery.includeCaptions)
            #expect(!off.gallery.includeSources)
            // Provenance off must not reach the page.
            let html = StaticSiteRenderer.indexHTML(off.gallery)
            #expect(!html.contains("example.com"))
            #expect(!html.contains(">T<"))
        }
    }

    @Test("Source links default to ON — stripping provenance is the deliberate act")
    func provenanceDefaultsOn() {
        #expect(SiteExportConfig().sourceLinks)
        #expect(SiteExportConfig().captions)
    }

    // MARK: - Collisions

    @Test("Two refs that would share a path get pulled apart, case-insensitively")
    func caseInsensitiveCollision() {
        withTempDirectory { temp in
            // The SAME 8-char short hash and the same base but for casing:
            // `Hero-ab12cd34.png` and `hero-ab12cd34.png` are one path on macOS.
            let a = Self.makeBlob(temp, "a.png")
            let b = Self.makeBlob(temp, "b.png")
            var first = true
            let result = plan(
                [detail(blobHash: "ab12cd34ffff", title: "Hero"),
                 detail(blobHash: "ab12cd34eeee", title: "hero")],
                blobURL: { _ in defer { first = false }; return first ? a : b })

            #expect(result.assets.map(\.filename) == ["Hero-ab12cd34.png", "hero-ab12cd34-2.png"])
            // Distinct files, distinct sources — nothing overwrote anything.
            #expect(Set(result.assets.map(\.source)) == Set([a, b]))
            let lowered = Set(result.assets.map { $0.filename.lowercased() })
            #expect(lowered.count == result.assets.count)
        }
    }

    @Test("The cells point at the disambiguated names, not the original ones")
    func collisionFlowsIntoCells() {
        withTempDirectory { temp in
            let a = Self.makeBlob(temp, "a.png")
            let b = Self.makeBlob(temp, "b.png")
            var first = true
            let result = plan(
                [detail(blobHash: "ab12cd34ffff", title: "Hero"),
                 detail(blobHash: "ab12cd34eeee", title: "HERO")],
                blobURL: { _ in defer { first = false }; return first ? a : b })

            #expect(result.gallery.items.map(\.media.assetFilename)
                == ["Hero-ab12cd34.png", "HERO-ab12cd34-2.png"])
        }
    }

    @Test("The same blob backing two rows keeps one name and one copy")
    func sameBlobOneFile() {
        withTempDirectory { temp in
            let shared = Self.makeBlob(temp, "shared.png")
            let result = plan(
                [detail(blobHash: "aaaa1111", title: "Twin"),
                 detail(blobHash: "aaaa1111", title: "Twin")],
                blobURL: { _ in shared })

            #expect(result.assets.count == 1)
            #expect(result.gallery.items.count == 2)
            #expect(result.gallery.items.map(\.media.assetFilename)
                == ["Twin-aaaa1111.png", "Twin-aaaa1111.png"])
        }
    }

    // MARK: - Layout agreement with the live grid

    @Test("Column grouping matches MasonryLayout's round-robin assignment")
    func groupingMatchesTheGrid() {
        // The exported page must read like the grid it came from. `SiteLayout`
        // reproduces `MasonryLayout`'s `i % C` rule; this pins the two together
        // rather than trusting the comment.
        for count in 1...12 {
            for columns in 1...5 {
                let frames = MasonryLayout.layout(
                    aspects: Array(repeating: 1.0, count: count),
                    availableWidth: 1000, columns: columns, spacing: 10).frames
                let groups = SiteLayout.columnGroups(itemCount: count, columns: columns)

                // Every index in a group shares one x — i.e. one column.
                for group in groups {
                    let xs = Set(group.map { frames[$0].minX })
                    #expect(xs.count == 1)
                }
                // …and different groups are different columns.
                let columnXs = groups.map { frames[$0[0]].minX }
                #expect(Set(columnXs).count == groups.count)
                #expect(columnXs == columnXs.sorted())
            }
        }
    }

    // MARK: - Folder name

    @Test("The suggested folder name goes through the shared sanitizer")
    func folderNameSanitized() {
        #expect(ExportScope.folderName(for: "Refs / Q3: 2026") == "Refs Q3 2026")
        #expect(ExportScope.folderName(for: "  ") == "Refs")
        #expect(ExportScope.folderName(for: "Interiors") == "Interiors")
    }

    // MARK: - End to end

    @Test("A planned collection writes a folder that renders offline")
    func endToEnd() throws {
        try withTempDirectory { temp in
            let blob = Self.makeBlob(temp, "hero.png")
            let poster = Self.makeBlob(temp, "poster.jpg")
            let movie = Self.makeBlob(temp, "clip.mp4")
            let rows = [
                detail(title: "Hero", originalURL: "https://www.example.com/a"),
                detail(kind: .video, blobHash: "999888777", title: "Clip"),
                colorDetail(hex: "#101010"),
            ]
            let result = CollectionSiteExport.plan(
                title: "Interiors", details: rows, config: SiteExportConfig(),
                blobURL: { $0.kind == .video ? movie : blob },
                posterURL: { _ in poster })

            let out = temp.appendingPathComponent("out", isDirectory: true)
            let written = try SiteExportWriter.write(
                gallery: result.gallery, assets: result.assets, to: out)

            #expect(written.copied == 2)          // image + poster, no movie
            #expect(written.skipped.isEmpty)
            let assets = try FileManager.default.contentsOfDirectory(
                atPath: out.appendingPathComponent("assets").path).sorted()
            #expect(assets == ["Clip-99988877.jpg", "Hero-abcdef12.png"])

            let html = try String(contentsOf: written.indexURL, encoding: .utf8)
            #expect(html.contains("<title>Interiors</title>"))
            #expect(html.contains("src=\"assets/Hero-abcdef12.png\""))
            #expect(html.contains("<svg class=\"play\""))
            #expect(html.contains("background:#101010"))
            #expect(html.contains("href=\"https://www.example.com/a\""))
            // Self-contained: nothing to fetch, nothing to run.
            #expect(!html.contains("<script"))
            #expect(!html.contains("src=\"http"))
        }
    }
}
