// AtelierExport — static-site folder writer tests (014 · S3)
//
// Real temp directories and real files: the whole point of this layer is what
// ends up ON DISK, so a mocked FileManager would test the mock. The fixtures
// are a few bytes each, which is also the shape a large-collection run takes —
// the writer never accumulates, so 4 files and 4000 exercise the same code.

import Foundation
import Testing
@testable import AtelierExport

@Suite("Static site: folder writer")
struct SiteExportWriterTests {

    // MARK: - Harness

    /// A scratch directory removed after `body`.
    private func withTempDirectory(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A real file with `bytes` of content.
    private func makeFile(_ url: URL, bytes: Int = 8) {
        FileManager.default.createFile(
            atPath: url.path, contents: Data(repeating: 0x41, count: bytes))
    }

    private func gallery(_ items: [SiteItem], columns: Int = 2) -> SiteGallery {
        SiteGallery(title: "Refs", items: items, columns: columns)
    }

    // MARK: - The happy path

    @Test("Writes index.html plus one file per ref into assets/")
    func writesFolder() throws {
        try withTempDirectory { temp in
            let sourceA = temp.appendingPathComponent("a.png")
            let sourceB = temp.appendingPathComponent("b.jpg")
            makeFile(sourceA)
            makeFile(sourceB)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try SiteExportWriter.write(
                gallery: gallery([
                    SiteItem(media: .image(file: "a-1.png", pixelWidth: 2, pixelHeight: 1)),
                    SiteItem(media: .image(file: "b-2.jpg", pixelWidth: 1, pixelHeight: 1)),
                ]),
                assets: [
                    SiteAsset(source: sourceA, filename: "a-1.png"),
                    SiteAsset(source: sourceB, filename: "b-2.jpg"),
                ],
                to: out)

            #expect(result.copied == 2)
            #expect(result.skipped.isEmpty)
            #expect(result.indexURL == out.appendingPathComponent("index.html"))
            #expect(FileManager.default.fileExists(atPath: result.indexURL.path))
            #expect(FileManager.default.fileExists(
                atPath: out.appendingPathComponent("assets/a-1.png").path))
            #expect(FileManager.default.fileExists(
                atPath: out.appendingPathComponent("assets/b-2.jpg").path))

            let html = try String(contentsOf: result.indexURL, encoding: .utf8)
            #expect(html.contains("src=\"assets/a-1.png\""))
            #expect(html.contains("src=\"assets/b-2.jpg\""))
        }
    }

    @Test("A colour ref needs no file and still gets a cell")
    func colourNeedsNoFile() throws {
        try withTempDirectory { temp in
            let out = temp.appendingPathComponent("out", isDirectory: true)
            let result = try SiteExportWriter.write(
                gallery: gallery([SiteItem(media: .color(hex: "#112233"))]),
                assets: [], to: out)

            #expect(result.copied == 0)
            #expect(result.skipped.isEmpty)
            let html = try String(contentsOf: result.indexURL, encoding: .utf8)
            #expect(html.contains("background:#112233"))
        }
    }

    @Test("A video contributes its poster only — no video file is ever copied")
    func videoPosterOnly() throws {
        try withTempDirectory { temp in
            let poster = temp.appendingPathComponent("poster.jpg")
            let movie = temp.appendingPathComponent("clip.mp4")
            makeFile(poster)
            makeFile(movie, bytes: 4096)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try SiteExportWriter.write(
                gallery: gallery([
                    SiteItem(media: .video(posterFile: "clip-1.jpg",
                                           pixelWidth: 16, pixelHeight: 9)),
                ]),
                assets: [SiteAsset(source: poster, filename: "clip-1.jpg")],
                to: out)

            #expect(result.copied == 1)
            let assets = try FileManager.default.contentsOfDirectory(
                atPath: out.appendingPathComponent("assets").path)
            #expect(assets == ["clip-1.jpg"])
            #expect(!assets.contains { $0.hasSuffix(".mp4") })

            let html = try String(contentsOf: result.indexURL, encoding: .utf8)
            #expect(html.contains("<svg class=\"play\""))
        }
    }

    // MARK: - Honest outcomes

    @Test("A blob that vanished is reported, not silently dropped or half-linked")
    func missingBlobIsReported() throws {
        try withTempDirectory { temp in
            let present = temp.appendingPathComponent("here.png")
            makeFile(present)
            let ghost = temp.appendingPathComponent("gone.png")   // never created
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try SiteExportWriter.write(
                gallery: gallery([
                    SiteItem(media: .image(file: "here-1.png", pixelWidth: 1, pixelHeight: 1),
                             caption: "Here"),
                    SiteItem(media: .image(file: "gone-2.png", pixelWidth: 1, pixelHeight: 1),
                             caption: "Gone"),
                ]),
                assets: [
                    SiteAsset(source: present, filename: "here-1.png"),
                    SiteAsset(source: ghost, filename: "gone-2.png"),
                ],
                to: out)

            #expect(result.copied == 1)
            #expect(result.skipped == [
                SiteSkip(filename: "gone-2.png", reason: .missingSource),
            ])

            // The page must not promise a file that isn't there.
            let html = try String(contentsOf: result.indexURL, encoding: .utf8)
            #expect(html.contains("src=\"assets/here-1.png\""))
            #expect(!html.contains("gone-2.png"))
            #expect(!html.contains("Gone"))
            #expect(html.contains("1 ref"))
        }
    }

    @Test("Every blob missing still writes a page, and reports every skip")
    func allMissing() throws {
        try withTempDirectory { temp in
            let out = temp.appendingPathComponent("out", isDirectory: true)
            let result = try SiteExportWriter.write(
                gallery: gallery([
                    SiteItem(media: .image(file: "a-1.png", pixelWidth: 1, pixelHeight: 1)),
                ]),
                assets: [
                    SiteAsset(source: temp.appendingPathComponent("nope.png"), filename: "a-1.png"),
                ],
                to: out)

            #expect(result.copied == 0)
            #expect(result.skipped.count == 1)
            let html = try String(contentsOf: result.indexURL, encoding: .utf8)
            #expect(html.contains("<p>No refs.</p>"))
        }
    }

    @Test("An empty gallery is refused rather than written as an empty folder")
    func emptyGalleryThrows() {
        withTempDirectory { temp in
            let out = temp.appendingPathComponent("out", isDirectory: true)
            #expect(throws: ExportError.noPages) {
                try SiteExportWriter.write(gallery: gallery([]), assets: [], to: out)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test("The same blob backing two rows is copied once")
    func duplicateNameCopiedOnce() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("shared.png")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try SiteExportWriter.write(
                gallery: gallery([
                    SiteItem(media: .image(file: "s-1.png", pixelWidth: 1, pixelHeight: 1)),
                    SiteItem(media: .image(file: "s-1.png", pixelWidth: 1, pixelHeight: 1)),
                ]),
                assets: [
                    SiteAsset(source: source, filename: "s-1.png"),
                    SiteAsset(source: source, filename: "s-1.png"),
                ],
                to: out)

            #expect(result.copied == 1)
            #expect(result.skipped.isEmpty)
            let assets = try FileManager.default.contentsOfDirectory(
                atPath: out.appendingPathComponent("assets").path)
            #expect(assets.count == 1)
            // Both cells survive — they point at the one file.
            let html = try String(contentsOf: result.indexURL, encoding: .utf8)
            #expect(html.components(separatedBy: "<figure>").count - 1 == 2)
        }
    }

    @Test("Re-exporting into the same folder refreshes rather than failing")
    func rerunOverwrites() throws {
        try withTempDirectory { temp in
            let first = temp.appendingPathComponent("first.png")
            makeFile(first, bytes: 4)
            let out = temp.appendingPathComponent("out", isDirectory: true)
            let item = SiteItem(media: .image(file: "x-1.png", pixelWidth: 1, pixelHeight: 1))

            _ = try SiteExportWriter.write(
                gallery: gallery([item]),
                assets: [SiteAsset(source: first, filename: "x-1.png")], to: out)

            let second = temp.appendingPathComponent("second.png")
            makeFile(second, bytes: 40)
            let result = try SiteExportWriter.write(
                gallery: gallery([item]),
                assets: [SiteAsset(source: second, filename: "x-1.png")], to: out)

            #expect(result.copied == 1)
            let size = try FileManager.default.attributesOfItem(
                atPath: out.appendingPathComponent("assets/x-1.png").path)[.size] as? Int
            #expect(size == 40)
        }
    }

    // MARK: - Progress + cancel

    @Test("Progress rises monotonically and finishes at 1")
    func progress() throws {
        try withTempDirectory { temp in
            var items: [SiteItem] = []
            var assets: [SiteAsset] = []
            for index in 0..<5 {
                let source = temp.appendingPathComponent("f\(index).png")
                makeFile(source)
                items.append(SiteItem(
                    media: .image(file: "f\(index)-1.png", pixelWidth: 1, pixelHeight: 1)))
                assets.append(SiteAsset(source: source, filename: "f\(index)-1.png"))
            }
            var ticks: [Double] = []
            _ = try SiteExportWriter.write(
                gallery: gallery(items), assets: assets,
                to: temp.appendingPathComponent("out", isDirectory: true),
                onProgress: { ticks.append($0) })

            #expect(ticks == [0.2, 0.4, 0.6, 0.8, 1.0, 1.0])
            #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    @Test("Cancelling throws CancellationError and writes no page")
    func cancels() {
        withTempDirectory { temp in
            let source = temp.appendingPathComponent("a.png")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)
            var seen = 0

            #expect(throws: CancellationError.self) {
                try SiteExportWriter.write(
                    gallery: gallery([
                        SiteItem(media: .image(file: "a-1.png", pixelWidth: 1, pixelHeight: 1)),
                        SiteItem(media: .image(file: "b-2.png", pixelWidth: 1, pixelHeight: 1)),
                    ]),
                    assets: [
                        SiteAsset(source: source, filename: "a-1.png"),
                        SiteAsset(source: source, filename: "b-2.png"),
                    ],
                    to: out,
                    isCancelled: { seen += 1; return seen > 1 })
            }
            // The half-written folder exists; the page never does, so a partial
            // run can never be mistaken for a finished one.
            #expect(!FileManager.default.fileExists(
                atPath: out.appendingPathComponent("index.html").path))
        }
    }

    @Test("Cancelling after the last copy still stops before the page is written")
    func cancelsBeforeIndex() {
        withTempDirectory { temp in
            let source = temp.appendingPathComponent("a.png")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)
            var calls = 0

            #expect(throws: CancellationError.self) {
                try SiteExportWriter.write(
                    gallery: gallery([
                        SiteItem(media: .image(file: "a-1.png", pixelWidth: 1, pixelHeight: 1)),
                    ]),
                    assets: [SiteAsset(source: source, filename: "a-1.png")],
                    to: out,
                    // False for the copy, true for the pre-render check.
                    isCancelled: { calls += 1; return calls > 1 })
            }
            #expect(FileManager.default.fileExists(
                atPath: out.appendingPathComponent("assets/a-1.png").path))
            #expect(!FileManager.default.fileExists(
                atPath: out.appendingPathComponent("index.html").path))
        }
    }
}
