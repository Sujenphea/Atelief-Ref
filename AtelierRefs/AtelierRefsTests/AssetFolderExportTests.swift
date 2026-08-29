//
//  AssetFolderExportTests.swift
//  AtelierRefsTests
//
//  011 · A2 — the selection→folder-of-originals mapping. Pure given the blob-URL
//  resolver, so every case below runs host-free: what becomes a file, what
//  becomes a reported skip, what the two divergences from the web-page export
//  actually do, and how two refs that would land on the same path are pulled
//  apart.
//
//  The copy loop is tested in the package (`AssetFolderWriterTests`); the
//  filename grammar is in `AssetExportTests`. This file covers only the seam.
//

import AtelierArchive
import AtelierCore
import AtelierExport
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Selection → originals folder: mapping")
struct AssetFolderExportTests {

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
            .appendingPathComponent("asset-map-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func detail(
        kind: AssetKind = .image,
        blobHash: String? = "abcdef1234567890",
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
            width: 1600, height: 1000, duration: kind == .video ? 12 : nil,
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
        detail(kind: .color, blobHash: nil,
               payload: AssetPayload(color: ColorPayload(hex: hex)).jsonString())
    }

    private func plan(
        _ details: [CollectionItemDetail], blobURL: @escaping (Asset) -> URL?
    ) -> AssetFolderExport.Plan {
        AssetFolderExport.plan(details: details, blobURL: blobURL)
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

    // The old `rowsMatchSiblingExports` / `folderNameMatchesSibling` cases are gone
    // on purpose: they asserted that three copies of one rule still agreed, and the
    // three copies are now one `ExportScope`. `ExportScopeTests` owns the rule.

    // MARK: - Mapping

    @Test("An image becomes one file, named by AssetExport")
    func imageMapsToFile() {
        withTempDirectory { temp in
            let blob = Self.makeBlob(temp, "blob.png")
            let result = plan([detail(title: "Sunset study")], blobURL: { _ in blob })

            #expect(result.skipped == 0)
            #expect(result.files == [
                ExportFile(source: blob, filename: "Sunset study-abcdef12.png"),
            ])
        }
    }

    @Test("Feed order is preserved")
    func preservesOrder() {
        withTempDirectory { temp in
            let first = Self.makeBlob(temp, "one.png")
            let second = Self.makeBlob(temp, "two.png")
            let a = detail(title: "Alpha")
            let b = detail(title: "Beta")
            let result = plan([a, b], blobURL: { $0.id == a.asset.id ? first : second })

            #expect(result.files.map(\.filename)
                == ["Alpha-abcdef12.png", "Beta-abcdef12.png"])
        }
    }

    // MARK: - The video divergence (011 · A2 vs 014 · S3)

    @Test("A video exports its own bytes — never a poster frame")
    func videoExportsTheVideo() {
        withTempDirectory { temp in
            let movie = Self.makeBlob(temp, "clip.mp4")
            let poster = Self.makeBlob(temp, "poster.jpg")
            let row = detail(kind: .video, title: "Title sequence")

            let result = AssetFolderExport.plan(
                details: [row], blobURL: { _ in movie })

            // The ONE file is the movie, and the extension came from the blob.
            #expect(result.files.count == 1)
            #expect(result.files[0].source == movie)
            #expect(result.files[0].filename == "Title sequence-abcdef12.mp4")
            #expect(result.files[0].source != poster)
        }
    }

    @Test("The web page still takes the poster for the same row — the split is real")
    func webPageStillTakesPoster() {
        withTempDirectory { temp in
            let movie = Self.makeBlob(temp, "clip.mp4")
            let poster = Self.makeBlob(temp, "poster.jpg")
            let row = detail(kind: .video, title: "Title sequence")

            let originals = AssetFolderExport.plan(details: [row], blobURL: { _ in movie })
            let page = CollectionSiteExport.plan(
                title: "Studio", details: [row], config: SiteExportConfig(),
                blobURL: { _ in movie }, posterURL: { _ in poster })

            #expect(originals.files.map(\.source) == [movie])
            #expect(page.assets.map(\.source) == [poster])
        }
    }

    // MARK: - Skips (nothing invented for a byte-less ref)

    @Test("A colour ref is a reported skip, not an invented sidecar")
    func colourIsSkipped() {
        let result = plan([colorDetail(hex: "#112233")], blobURL: { _ in nil })
        #expect(result.files.isEmpty)
        #expect(result.skipped == 1)
        #expect(result.isEmpty)
    }

    @Test("A blob reaped before the export is a skip; its neighbours still export")
    func missingBlobIsSkipped() {
        withTempDirectory { temp in
            let present = Self.makeBlob(temp, "here.png")
            let gone = temp.appendingPathComponent("reaped.png")     // never created
            let alive = detail(title: "Alive")
            let dead = detail(title: "Dead")

            let result = plan([dead, alive], blobURL: {
                $0.id == alive.asset.id ? present : gone
            })

            #expect(result.skipped == 1)
            #expect(result.files.map(\.filename) == ["Alive-abcdef12.png"])
        }
    }

    @Test("An asset with no blob hash at all is a skip")
    func noHashIsSkipped() {
        withTempDirectory { temp in
            let blob = Self.makeBlob(temp, "blob.png")
            let result = plan([detail(blobHash: nil)], blobURL: { _ in blob })
            #expect(result.files.isEmpty)
            #expect(result.skipped == 1)
        }
    }

    @Test("An all-skips selection is empty rather than a folder of nothing")
    func allSkipsIsEmpty() {
        let result = plan([colorDetail(hex: "#000000"), colorDetail(hex: "#ffffff")],
                          blobURL: { _ in nil })
        #expect(result.isEmpty)
        #expect(result.skipped == 2)
    }

    // MARK: - Collisions and duplicates

    @Test("Two different blobs that name the same file are pulled apart")
    func collidingNamesDisambiguated() {
        withTempDirectory { temp in
            let first = Self.makeBlob(temp, "one.png")
            let second = Self.makeBlob(temp, "two.png")
            let a = detail(title: "Hero")
            let b = detail(title: "Hero")   // same title, same short hash

            let result = plan([a, b], blobURL: { $0.id == a.asset.id ? first : second })

            #expect(result.files.map(\.filename) == ["Hero-abcdef12.png", "Hero-abcdef12-2.png"])
            #expect(result.skipped == 0)
        }
    }

    @Test("Case-insensitive collision is caught — macOS volumes fold case")
    func caseInsensitiveCollision() {
        withTempDirectory { temp in
            let first = Self.makeBlob(temp, "one.png")
            let second = Self.makeBlob(temp, "two.png")
            let a = detail(title: "Hero")
            let b = detail(title: "hero")

            let result = plan([a, b], blobURL: { $0.id == a.asset.id ? first : second })

            // Two distinct paths on a case-insensitive volume, and each keeps the
            // casing its own title gave it.
            #expect(result.files.map(\.filename) == ["Hero-abcdef12.png", "hero-abcdef12-2.png"])
        }
    }

    @Test("One blob backing two rows yields ONE file and is not counted as a skip")
    func sharedBlobExportsOnce() {
        withTempDirectory { temp in
            let blob = Self.makeBlob(temp, "shared.png")
            let result = plan([detail(title: "Hero"), detail(title: "Hero")],
                              blobURL: { _ in blob })

            #expect(result.files == [
                ExportFile(source: blob, filename: "Hero-abcdef12.png"),
            ])
            #expect(result.skipped == 0)
        }
    }

    // Folder naming moved with the rule — see `ExportScopeTests`.
}
