// AtelierIngestion — direct-input adapter tests (chunk 5)
//
// Two layers, both GUI-free:
//   • the PURE provenance factories map each of the three LOCAL paths to the
//     right `platform` / `originalURL` / `rawMetadata` (paste → localPaste;
//     paste-with-url; file → localDrag with `original_path`; browser-image → web
//     with the page URL);
//   • `inputs(from:)` interprets a NAMED test `NSPasteboard` (never `.general`):
//     PNG bytes → one `.localPaste` `.data`; a file URL → one `.localDrag`
//     `.fileURL`; PNG bytes + a web URL → one `.web` (browser-image); empty → [].

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

import AtelierCore
@testable import AtelierIngestion

@Suite("DirectInputReader")
struct DirectInputReaderTests {

    // A fixed capture time so provenance assertions are deterministic.
    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let collectionID = UUID()

    // MARK: - Pure provenance factories

    @Test("pasteInput → .localPaste, no originalURL")
    func pasteInputProvenance() {
        let input = DirectInputReader.pasteInput(
            imageData: Data([0x1, 0x2, 0x3]), sourceURL: nil,
            into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.platform == .localPaste)
        #expect(input.provenance.originalURL == nil)
        #expect(input.provenance.capturedAt == Self.capturedAt)
        #expect(input.collectionID == Self.collectionID)
        // Bytes carried in-memory.
        if case .bytes(.data(let d)) = input.source {
            #expect(d == Data([0x1, 0x2, 0x3]))
        } else {
            Issue.record("expected .data source")
        }
    }

    @Test("pasteInput with a clipboard URL → .localPaste carrying originalURL")
    func pasteInputWithURL() {
        let url = URL(string: "https://example.com/pic.png")!
        let input = DirectInputReader.pasteInput(
            imageData: Data([0xAA]), sourceURL: url,
            into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.platform == .localPaste)
        #expect(input.provenance.originalURL == "https://example.com/pic.png")
    }

    // MARK: clipboardInput — ambient capture provenance (013 · K3)

    @Test("clipboardInput → .clipboard, the app as author, no originalURL")
    func clipboardInputProvenance() {
        let input = DirectInputReader.clipboardInput(
            imageData: Data([0x7]), appName: "Preview", appBundleID: "com.apple.Preview",
            into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.platform == .clipboard)
        // An ambient copy has no canonical URL — and `Validation.originalURL`
        // exempts `.clipboard`, so this must not be faked into something.
        #expect(input.provenance.originalURL == nil)
        #expect(input.provenance.authorName == "Preview")
        #expect(input.provenance.authorHandle == "com.apple.Preview")
        #expect(input.provenance.capturedAt == Self.capturedAt)
        #expect(input.collectionID == Self.collectionID)
        if case .bytes(.data(let d)) = input.source {
            #expect(d == Data([0x7]))
        } else {
            Issue.record("expected .data source")
        }
    }

    @Test("an unresolvable frontmost app falls back to \"Clipboard\", never to nothing")
    func clipboardInputFallsBack() {
        let input = DirectInputReader.clipboardInput(
            imageData: Data([0x7]), appName: nil, appBundleID: nil,
            into: Self.collectionID, at: Self.capturedAt)

        // Provenance is never null (013 §B): resolving the frontmost app races a
        // fast ⌘-tab and can simply fail, and a blank author would read as a bug
        // rather than as "we only know this much".
        #expect(input.provenance.authorName == "Clipboard")
        #expect(input.provenance.authorName == DirectInputReader.clipboardFallbackAppName)
        // No bundle id is honest as nil — unlike the name, nothing sensible stands in.
        #expect(input.provenance.authorHandle == nil)
        #expect(input.provenance.platform == .clipboard)
    }

    @Test("blank / whitespace-only app fields normalize like absent ones", arguments: [
        "", "   ", "\n\t",
    ])
    func clipboardInputNormalizesBlanks(_ blank: String) {
        let input = DirectInputReader.clipboardInput(
            imageData: Data([0x7]), appName: blank, appBundleID: blank,
            into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.authorName == "Clipboard")
        #expect(input.provenance.authorHandle == nil)
    }

    @Test("the app name is trimmed, not mangled")
    func clipboardInputTrims() {
        let input = DirectInputReader.clipboardInput(
            imageData: Data([0x7]), appName: "  Sketch  ", appBundleID: " com.bohemian.sketch ",
            into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.authorName == "Sketch")
        #expect(input.provenance.authorHandle == "com.bohemian.sketch")
    }

    @Test("fileInput → .localDrag with original_path in raw_metadata")
    func fileInputProvenance() {
        let url = URL(fileURLWithPath: "/Users/someone/Pictures/ref.png")
        let input = DirectInputReader.fileInput(
            fileURL: url, into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.platform == .localDrag)
        #expect(input.provenance.originalURL == nil)
        #expect(input.provenance.rawMetadata
            == .object(["original_path": .string("/Users/someone/Pictures/ref.png")]))
        // Bytes read from the file URL at ingest.
        if case .bytes(.fileURL(let u)) = input.source {
            #expect(u == url)
        } else {
            Issue.record("expected .fileURL source")
        }
    }

    @Test("browserImageInput → .web with the page URL as originalURL")
    func browserImageInputProvenance() {
        let page = URL(string: "https://gallery.example/post/42")!
        let input = DirectInputReader.browserImageInput(
            imageData: Data([0x1]), pageURL: page,
            into: Self.collectionID, at: Self.capturedAt)

        #expect(input.provenance.platform == .web)
        #expect(input.provenance.originalURL == "https://gallery.example/post/42")
        if case .bytes(.data) = input.source {} else {
            Issue.record("expected .data source")
        }
    }

    @Test("remoteInput → carries the caller's SourceDraft verbatim + bytes in-memory")
    func remoteInputProvenance() {
        let provenance = SourceDraft(
            platform: .twitter,
            originalURL: "https://x.com/designer/status/42",
            authorHandle: "@designer",
            authorName: "A Designer",
            title: "a great reference",
            capturedAt: Self.capturedAt,
            rawMetadata: .object(["likes": .number(1234)]))
        let input = DirectInputReader.remoteInput(
            imageData: Data([0xDE, 0xAD]), provenance: provenance,
            into: Self.collectionID)

        // The rich provenance is passed straight through, unmodified.
        #expect(input.provenance == provenance)
        #expect(input.provenance.platform == .twitter)
        #expect(input.provenance.authorHandle == "@designer")
        #expect(input.collectionID == Self.collectionID)
        if case .bytes(.data(let d)) = input.source {
            #expect(d == Data([0xDE, 0xAD]))
        } else {
            Issue.record("expected .data source (bytes ride in with the request)")
        }
    }

    @Test("remoteVideo → caller's SourceDraft verbatim + bytes read from a file URL")
    func remoteVideoProvenance() {
        let url = URL(fileURLWithPath: "/tmp/atelier-capture/clip.mp4")
        let provenance = SourceDraft(
            platform: .twitter,
            originalURL: "https://x.com/designer/status/42",
            authorHandle: "@designer",
            capturedAt: Self.capturedAt,
            rawMetadata: .object(["tweetId": .string("42")]))
        let input = DirectInputReader.remoteVideo(
            fileURL: url, provenance: provenance, into: Self.collectionID)

        #expect(input.provenance == provenance)
        #expect(input.collectionID == Self.collectionID)
        // Bytes stream from disk (a video is too large to hold in memory).
        if case .bytes(.fileURL(let u)) = input.source {
            #expect(u == url)
        } else {
            Issue.record("expected .fileURL source (video streamed to a temp file)")
        }
    }

    // MARK: - Pasteboard interpretation (named pasteboard, no GUI)

    /// A fresh, uniquely-named pasteboard so tests never touch `.general` and
    /// never collide with one another.
    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("AtelierTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test("inputs(from:) with PNG bytes → one .localPaste .data")
    func pasteboardImageOnly() throws {
        let png = try FixtureImages.solidImage(width: 8, height: 8, format: .png)
        let pb = makePasteboard()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pb.writeObjects([item])

        let inputs = DirectInputReader.inputs(
            from: pb, into: Self.collectionID, now: Self.capturedAt)

        #expect(inputs.count == 1)
        let input = try #require(inputs.first)
        #expect(input.provenance.platform == .localPaste)
        #expect(input.provenance.originalURL == nil)
        if case .bytes(.data(let d)) = input.source {
            #expect(d == png)
        } else {
            Issue.record("expected .data source")
        }
    }

    @Test("inputs(from:) with a file URL → one .localDrag .fileURL")
    func pasteboardFileURL() throws {
        // A real temp file so its file URL round-trips through the pasteboard.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ref.png")
        let png = try FixtureImages.solidImage(width: 4, height: 4, format: .png)
        try png.write(to: fileURL)

        let pb = makePasteboard()
        pb.writeObjects([fileURL as NSURL])

        let inputs = DirectInputReader.inputs(
            from: pb, into: Self.collectionID, now: Self.capturedAt)

        #expect(inputs.count == 1)
        let input = try #require(inputs.first)
        #expect(input.provenance.platform == .localDrag)
        if case .bytes(.fileURL(let u)) = input.source {
            #expect(u.isFileURL)
            #expect(u.lastPathComponent == "ref.png")
        } else {
            Issue.record("expected .fileURL source")
        }
        // The original path is preserved in raw_metadata.
        if case .object(let obj) = input.provenance.rawMetadata,
           case .string(let path)? = obj["original_path"] {
            #expect(path.hasSuffix("ref.png"))
        } else {
            Issue.record("expected original_path in raw_metadata")
        }
    }

    @Test("inputs(from:) with PNG bytes + a web URL → one .web browser-image")
    func pasteboardBrowserImage() throws {
        let png = try FixtureImages.solidImage(width: 8, height: 8, format: .png)
        let pb = makePasteboard()
        // A single item carrying BOTH the image bytes and its source page URL —
        // the shape a browser image drag produces.
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString("https://gallery.example/post/7", forType: .URL)
        pb.writeObjects([item])

        let inputs = DirectInputReader.inputs(
            from: pb, into: Self.collectionID, now: Self.capturedAt)

        #expect(inputs.count == 1)
        let input = try #require(inputs.first)
        #expect(input.provenance.platform == .web)
        #expect(input.provenance.originalURL == "https://gallery.example/post/7")
        if case .bytes(.data(let d)) = input.source {
            #expect(d == png)
        } else {
            Issue.record("expected .data source")
        }
    }

    @Test("inputs(from:) prefers a file URL over an accompanying inline image (Finder copy)")
    func pasteboardFileURLBeatsInlinePreview() throws {
        // The shape a copied image FILE produces: the file URL (real full-res
        // bytes) PLUS a small inline image that is only an icon/QuickLook
        // preview. We must ingest the file, not the preview.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("real.png")
        let realBytes = try FixtureImages.solidImage(width: 64, height: 64, format: .png)
        try realBytes.write(to: fileURL)

        // A tiny, DIFFERENT inline "preview" image alongside the file URL.
        let preview = try FixtureImages.solidImage(width: 8, height: 8, format: .png)
        let previewItem = NSPasteboardItem()
        previewItem.setData(preview, forType: .png)

        let pb = makePasteboard()
        pb.writeObjects([previewItem, fileURL as NSURL])

        let inputs = DirectInputReader.inputs(
            from: pb, into: Self.collectionID, now: Self.capturedAt)

        #expect(inputs.count == 1)
        let input = try #require(inputs.first)
        // The file URL won: a .localDrag reading the real file, NOT a paste of
        // the 8×8 preview bytes.
        #expect(input.provenance.platform == .localDrag)
        if case .bytes(.fileURL(let u)) = input.source {
            #expect(u.lastPathComponent == "real.png")
        } else {
            Issue.record("expected .fileURL source (the real file), not the inline preview")
        }
    }

    @Test("inputs(from:) over an empty pasteboard → []")
    func pasteboardEmpty() {
        let pb = makePasteboard()
        let inputs = DirectInputReader.inputs(
            from: pb, into: Self.collectionID, now: Self.capturedAt)
        #expect(inputs.isEmpty)
    }
}
