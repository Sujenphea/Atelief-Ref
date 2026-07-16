// AtelierIngestion — drag-provider decode tests
//
// Mirrors the pasteboard suite (`DirectInputReaderTests`) for the DRAG path:
// `inputs(from providers:)` turns a drop's `NSItemProvider`s into the same three
// LOCAL paths (file → `.localDrag`; image bytes → `.web` when a page URL rode
// along, else `.localPaste`), surfaces a fall-back `webURL` for a bare link drag,
// and counts providers that decoded to NOTHING so a partial drop is reported
// rather than silently dropped (7A). GUI-free: providers are built in-process.
//
// Per-provider file-over-image precedence (fileURL checked before image inside
// the single-provider decoder) is straight-line code and is already proven at the
// pasteboard level (`pasteboardFileURLBeatsInlinePreview`); constructing one
// provider that reliably advertises BOTH a file URL and inline image bytes in a
// unit test is brittle, so it is intentionally not re-tested here.

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

import AtelierCore
@testable import AtelierIngestion

@Suite("DirectInputReader — drag providers")
struct DirectInputReaderProvidersTests {

    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let collectionID = UUID()

    // MARK: - Provider builders (in-process, no drag session)

    private func imageProvider(_ data: Data) -> NSItemProvider {
        NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
    }

    private func urlProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    private func textProvider(_ string: String) -> NSItemProvider {
        NSItemProvider(object: string as NSString)
    }

    /// A temp file whose URL round-trips through a provider as `public.file-url`.
    private func tempImageFile() throws -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("ref.png")
        let png = try FixtureImages.solidImage(width: 4, height: 4, format: .png)
        try png.write(to: fileURL)
        return (fileURL, { try? FileManager.default.removeItem(at: dir) })
    }

    // MARK: - Tests

    @Test("a file URL provider → one .localDrag, no webURL, nothing undecoded")
    func fileURLProvider() async throws {
        let (fileURL, cleanup) = try tempImageFile()
        defer { cleanup() }

        let decoded = await DirectInputReader.inputs(
            from: [urlProvider(fileURL)], into: Self.collectionID, now: Self.capturedAt)

        #expect(decoded.inputs.count == 1)
        #expect(decoded.webURL == nil)
        #expect(decoded.undecodedCount == 0)
        let input = try #require(decoded.inputs.first)
        #expect(input.provenance.platform == .localDrag)
        if case .bytes(.fileURL(let u)) = input.source {
            #expect(u.lastPathComponent == "ref.png")
        } else {
            Issue.record("expected .fileURL source")
        }
    }

    @Test("image bytes with no page URL → one .localPaste")
    func imageOnlyProvider() async throws {
        let png = try FixtureImages.solidImage(width: 8, height: 8, format: .png)

        let decoded = await DirectInputReader.inputs(
            from: [imageProvider(png)], into: Self.collectionID, now: Self.capturedAt)

        #expect(decoded.inputs.count == 1)
        #expect(decoded.webURL == nil)
        #expect(decoded.undecodedCount == 0)
        let input = try #require(decoded.inputs.first)
        #expect(input.provenance.platform == .localPaste)
        #expect(input.provenance.originalURL == nil)
    }

    @Test("image bytes + a web URL provider → one .web browser-image with the page URL")
    func browserImageProvider() async throws {
        let png = try FixtureImages.solidImage(width: 8, height: 8, format: .png)
        let page = URL(string: "https://gallery.example/post/7")!

        let decoded = await DirectInputReader.inputs(
            from: [imageProvider(png), urlProvider(page)],
            into: Self.collectionID, now: Self.capturedAt)

        #expect(decoded.inputs.count == 1)
        #expect(decoded.webURL == page)
        #expect(decoded.undecodedCount == 0)
        let input = try #require(decoded.inputs.first)
        #expect(input.provenance.platform == .web)
        #expect(input.provenance.originalURL == "https://gallery.example/post/7")
    }

    @Test("a bare web URL drag → no inputs, webURL set, nothing undecoded")
    func bareWebURLProvider() async {
        let page = URL(string: "https://example.com/some/page")!

        let decoded = await DirectInputReader.inputs(
            from: [urlProvider(page)], into: Self.collectionID, now: Self.capturedAt)

        #expect(decoded.inputs.isEmpty)
        #expect(decoded.webURL == page)
        // The URL carrier is the fall-back, NOT an unreadable item.
        #expect(decoded.undecodedCount == 0)
    }

    @Test("no providers → empty decode")
    func emptyProviders() async {
        let decoded = await DirectInputReader.inputs(
            from: [], into: Self.collectionID, now: Self.capturedAt)

        #expect(decoded.inputs.isEmpty)
        #expect(decoded.webURL == nil)
        #expect(decoded.undecodedCount == 0)
    }

    @Test("an unreadable (plain-text) provider → counted as undecoded")
    func undecodableProvider() async {
        let decoded = await DirectInputReader.inputs(
            from: [textProvider("just some words")],
            into: Self.collectionID, now: Self.capturedAt)

        #expect(decoded.inputs.isEmpty)
        #expect(decoded.webURL == nil)
        #expect(decoded.undecodedCount == 1)
    }

    @Test("mixed drop: one image + one unreadable → one input AND an undecoded count (7A)")
    func partialDrop() async throws {
        let png = try FixtureImages.solidImage(width: 8, height: 8, format: .png)

        let decoded = await DirectInputReader.inputs(
            from: [imageProvider(png), textProvider("garbage")],
            into: Self.collectionID, now: Self.capturedAt)

        #expect(decoded.inputs.count == 1)
        #expect(decoded.undecodedCount == 1)
        #expect(decoded.inputs.first?.provenance.platform == .localPaste)
    }
}
