//
//  AssetExportTests.swift
//  AtelierRefsTests
//
//  011 · Cluster A (out-flow) — the shared export-naming rule. The base pick +
//  sanitizer + filename assembly are pure; `exportItem` is temp-file testable.
//  This is the DRY naming contract every out-flow surface (drag-out, ⌘C, 008)
//  shares, so it is covered exhaustively (12A / 10A / 5A).
//

import AtelierArchive
import AtelierCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

// MARK: - sanitize

@Suite("AssetExport: sanitize")
struct AssetExportSanitizeTests {

    @Test("path-hostile and control chars become spaces, runs collapse", arguments: [
        ("a/b:c\\d", "a b c d"),        // slash, colon, backslash → spaces
        ("a\tb\nc", "a b c"),           // control chars → spaces
        ("a   b", "a b"),               // whitespace runs collapse
        ("hello world", "hello world"), // already clean
    ] as [(String, String)])
    func replacesHostile(_ input: String, _ expected: String) {
        #expect(AssetExport.sanitize(input) == expected)
    }

    @Test("leading/trailing spaces, dots and dashes are trimmed", arguments: [
        ("  spaced  ", "spaced"),
        (".hidden", "hidden"),          // no hidden-file dot
        ("trail.", "trail"),
        ("--dashes--", "dashes"),
        (" .-mixed-. ", "mixed"),
    ] as [(String, String)])
    func trimsEdges(_ input: String, _ expected: String) {
        #expect(AssetExport.sanitize(input) == expected)
    }

    @Test("an empty or all-separator result falls back to 'image'", arguments: [
        "", "   ", "///", "...", "- - -", "\t\n",
    ])
    func emptyFallsBack(_ input: String) {
        #expect(AssetExport.sanitize(input) == "image")
    }

    @Test("the result is capped at 60 characters")
    func capsLength() {
        let long = String(repeating: "a", count: 100)
        #expect(AssetExport.sanitize(long).count == 60)
        // A cap that lands on a trailing dash/space still trims it.
        let padded = String(repeating: "a", count: 59) + " bbbb"
        #expect(AssetExport.sanitize(padded).count <= 60)
        #expect(!AssetExport.sanitize(padded).hasSuffix(" "))
    }

    @Test("unicode and emoji are preserved")
    func preservesUnicode() {
        #expect(AssetExport.sanitize("naïve café 🎨") == "naïve café 🎨")
    }
}

// MARK: - baseName

@Suite("AssetExport: baseName priority")
struct AssetExportBaseNameTests {

    @Test("a title wins over handle and URL")
    func titleWins() {
        #expect(AssetExport.baseName(
            title: "  Sunset study  ", authorHandle: "@dieter", sourceURL: "https://x.com/p")
            == "Sunset study")
    }

    @Test("a whitespace-only title falls through to the handle")
    func blankTitleFallsThrough() {
        #expect(AssetExport.baseName(title: "   ", authorHandle: "@dieter", sourceURL: nil)
            == "dieter")
    }

    @Test("a handle's leading @ is dropped; a bare handle is kept")
    func handleStripsAt() {
        #expect(AssetExport.baseName(title: nil, authorHandle: "@dieter", sourceURL: nil) == "dieter")
        #expect(AssetExport.baseName(title: nil, authorHandle: "dieter", sourceURL: nil) == "dieter")
    }

    @Test("with no title or handle, the URL host is used (www dropped)", arguments: [
        ("https://www.example.com/a/b", "example.com"),
        ("https://pinterest.com/pin/42", "pinterest.com"),
    ] as [(String, String)])
    func hostFromURL(_ url: String, _ expected: String) {
        #expect(AssetExport.baseName(title: nil, authorHandle: nil, sourceURL: url) == expected)
    }

    @Test("with nothing usable, the base is 'image'")
    func nothingUsable() {
        #expect(AssetExport.baseName(title: nil, authorHandle: nil, sourceURL: nil) == "image")
        #expect(AssetExport.baseName(title: "  ", authorHandle: "  ", sourceURL: "not a url") == "image")
    }
}

// MARK: - filename assembly

@Suite("AssetExport: filename assembly")
struct AssetExportFilenameTests {

    @Test("assembles base-shorthash.ext with an 8-char hash, lowercased ext")
    func assembles() {
        #expect(AssetExport.filename(base: "Sunset", blobHash: "abcdef1234567890", ext: "JPG")
            == "Sunset-abcdef12.jpg")
    }

    @Test("the base is sanitized in the assembled name")
    func sanitizesBase() {
        #expect(AssetExport.filename(base: "a/b:c", blobHash: "hash1234", ext: "png")
            == "a b c-hash1234.png")
    }

    @Test("the extension is reduced to bare alphanumerics")
    func cleansExt() {
        #expect(AssetExport.filename(base: "x", blobHash: "hash1234", ext: "jp g!")
            == "x-hash1234.jpg")
    }

    @Test("a missing hash drops the hash segment")
    func missingHash() {
        #expect(AssetExport.filename(base: "x", blobHash: "", ext: "png") == "x.png")
    }

    @Test("a missing extension drops the dot segment")
    func missingExt() {
        #expect(AssetExport.filename(base: "x", blobHash: "hash1234", ext: "") == "x-hash1234")
    }

    @Test("a hash shorter than 8 chars is used whole")
    func shortHash() {
        #expect(AssetExport.filename(base: "x", blobHash: "abc", ext: "png") == "x-abc.png")
    }

    @Test("an empty base sanitizes to 'image'")
    func emptyBase() {
        #expect(AssetExport.filename(base: "  ", blobHash: "hash1234", ext: "png")
            == "image-hash1234.png")
    }
}

// MARK: - Folder uniqueness (014 · S3)

/// `AssetExport.filename` names a file by content; a FOLDER export is the first
/// caller to write many of those names side by side. These are the cases where a
/// naive write loses data rather than erroring.
@Suite("AssetExport: ExportNameAllocator")
struct ExportNameAllocatorTests {

    @Test("Distinct names pass through untouched")
    func distinctNames() {
        var allocator = ExportNameAllocator()
        #expect(allocator.claim("a-1111.png") == "a-1111.png")
        #expect(allocator.claim("b-2222.png") == "b-2222.png")
    }

    @Test("An exact duplicate gets -2, -3, … before the extension")
    func exactDuplicates() {
        var allocator = ExportNameAllocator()
        #expect(allocator.claim("hero-ab12cd34.png") == "hero-ab12cd34.png")
        #expect(allocator.claim("hero-ab12cd34.png") == "hero-ab12cd34-2.png")
        #expect(allocator.claim("hero-ab12cd34.png") == "hero-ab12cd34-3.png")
    }

    /// The one that loses data silently: macOS volumes are case-INSENSITIVE, so
    /// `copyItem` to the second name overwrites the first instead of failing.
    @Test("Names differing only by case are treated as the same path")
    func caseInsensitiveCollision() {
        var allocator = ExportNameAllocator()
        #expect(allocator.claim("Hero-ab12cd34.png") == "Hero-ab12cd34.png")
        #expect(allocator.claim("hero-ab12cd34.png") == "hero-ab12cd34-2.png")
        #expect(allocator.claim("HERO-AB12CD34.PNG") == "HERO-AB12CD34-3.PNG")
    }

    @Test("The casing the asset's own title gave it is preserved")
    func preservesCasing() {
        var allocator = ExportNameAllocator()
        _ = allocator.claim("hero-ab12cd34.png")
        #expect(allocator.claim("HeRo-ab12cd34.png") == "HeRo-ab12cd34-2.png")
    }

    @Test("A name with no extension just gains the suffix")
    func noExtension() {
        var allocator = ExportNameAllocator()
        #expect(allocator.claim("plain-ab12cd34") == "plain-ab12cd34")
        #expect(allocator.claim("plain-ab12cd34") == "plain-ab12cd34-2")
    }

    @Test("A disambiguated name that later arrives for real is itself disambiguated")
    func suffixCollision() {
        var allocator = ExportNameAllocator()
        _ = allocator.claim("x-1.png")           // x-1.png
        _ = allocator.claim("x-1.png")           // x-1-2.png
        // A different asset genuinely named `x-1-2.png` must not land on it.
        #expect(allocator.claim("x-1-2.png") == "x-1-2-2.png")
    }

    @Test("Unicode names collide on case the same way")
    func unicodeCasing() {
        var allocator = ExportNameAllocator()
        #expect(allocator.claim("Café-ab12cd34.png") == "Café-ab12cd34.png")
        #expect(allocator.claim("café-ab12cd34.png") == "café-ab12cd34-2.png")
    }

    @Test("A whole run of names stays unique when compared case-insensitively")
    func runStaysUnique() {
        var allocator = ExportNameAllocator()
        let claimed = ["A-1.png", "a-1.png", "A-1.PNG", "b-2.png", "B-2.png", "A-1.png"]
            .map { allocator.claim($0) }
        #expect(Set(claimed.map { $0.lowercased() }).count == claimed.count)
    }

    @Test("The suffix goes before the extension, so the file still says what it is")
    func suffixPlacement() {
        #expect(ExportNameAllocator.disambiguated("hero-ab12cd34.png", suffix: 2)
            == "hero-ab12cd34-2.png")
        #expect(ExportNameAllocator.disambiguated("hero-ab12cd34", suffix: 7)
            == "hero-ab12cd34-7")
    }

    /// The reason the allocator exists at archive scale (008 · H6): the suffix is
    /// the first 8 characters of a longer digest, so two genuinely DIFFERENT
    /// blobs can produce the same one. Across a whole library that stops being
    /// hypothetical, and the failure is a silent overwrite rather than an error.
    @Test("Two different blobs sharing an 8-char hash prefix stay two files")
    func shortHashIsNotUnique() {
        var allocator = ExportNameAllocator()
        let first = AssetExport.filename(
            base: "Hero", blobHash: "ab12cd34" + "0000", ext: "png")
        let second = AssetExport.filename(
            base: "Hero", blobHash: "ab12cd34" + "ffff", ext: "png")
        #expect(first == second)                       // the naming rule collides…
        #expect(allocator.claim(first) == "Hero-ab12cd34.png")
        #expect(allocator.claim(second) == "Hero-ab12cd34-2.png")   // …the folder doesn't
    }

    /// The archive names files across a whole library, where the same title
    /// repeats freely — a run of them must never shrink to one file.
    @Test("A library-scale run of repeated titles yields one name per file")
    func libraryScaleRun() {
        var allocator = ExportNameAllocator()
        let names = (0..<50).map { _ in
            allocator.claim(AssetExport.filename(base: "Untitled", blobHash: "0f0f0f0f", ext: "jpg"))
        }
        #expect(Set(names.map { $0.lowercased() }).count == 50)
        #expect(names.first == "Untitled-0f0f0f0f.jpg")
        #expect(names.last == "Untitled-0f0f0f0f-50.jpg")
    }
}

// MARK: - exportItem (temp-file backed)

@Suite("AssetExport: exportItem")
struct AssetExportItemTests {

    private func asset(blobHash: String?, mime: String? = "image/png") -> Asset {
        Asset(
            id: UUID(), kind: .image, blobHash: blobHash, mimeType: mime,
            width: 10, height: 10, duration: nil, fileSize: 10,
            downloadState: .downloaded, createdAt: Date(), sourceId: UUID())
    }

    private func source(title: String? = nil) -> Source {
        Source(id: UUID(), platform: .web, title: title, capturedAt: Date())
    }

    /// A real on-disk temp file with the given extension; removed after `body`.
    private func withTempFile(ext: String, _ body: (URL) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @Test("a byte-backed asset with an on-disk blob yields an item (name + type + url)")
    func byteBacked() throws {
        try withTempFile(ext: "png") { url in
            let item = AssetExport.exportItem(
                asset: asset(blobHash: "abcdef1234"), source: source(title: "Sunset"), blobURL: url)
            let unwrapped = try #require(item)
            #expect(unwrapped.blobURL == url)
            #expect(unwrapped.filename == "Sunset-abcdef12.png")   // ext from the blob file
            #expect(unwrapped.utType == .png)
        }
    }

    @Test("a media-less asset (no blob hash) yields nil")
    func mediaLess() {
        #expect(AssetExport.exportItem(
            asset: asset(blobHash: nil), source: source(), blobURL: nil) == nil)
    }

    @Test("a byte-backed asset with a nil blob URL yields nil")
    func nilURL() {
        #expect(AssetExport.exportItem(
            asset: asset(blobHash: "abc"), source: source(), blobURL: nil) == nil)
    }

    @Test("a blob hash whose file is missing on disk yields nil (5A)")
    func missingFile() {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        #expect(AssetExport.exportItem(
            asset: asset(blobHash: "abc"), source: source(), blobURL: ghost) == nil)
    }
}

// MARK: - dragProvider (the detail view's drag, 192)

@MainActor
@Suite("AssetExport: dragProvider")
struct AssetExportDragProviderTests {

    private func tempItem() -> AssetExportItem {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2]))
        return AssetExportItem(blobURL: url, filename: "pretty-abc.png", utType: .png)
    }

    @Test("the provider vends the file AND the internal .assetIDs identity")
    func vendsFileAndIdentity() throws {
        let item = tempItem()
        defer { try? FileManager.default.removeItem(at: item.blobURL) }
        let payload = AssetDragPayload(assetIDs: [UUID()], sourceCollectionID: UUID())
        let provider = AssetExport.dragProvider(item: item, payload: payload)

        #expect(provider.suggestedName == "pretty-abc.png")
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.assetIDs.identifier))
        // The file representation is present too (the external-drop half).
        #expect(provider.registeredTypeIdentifiers.count > 1)
    }

    @Test("the registered .assetIDs bytes decode back to the SAME payload")
    func identityRoundTrips() async throws {
        let item = tempItem()
        defer { try? FileManager.default.removeItem(at: item.blobURL) }
        let payload = AssetDragPayload(
            assetIDs: [UUID(), UUID()], sourceCollectionID: UUID())
        let provider = AssetExport.dragProvider(item: item, payload: payload)

        let decoded: AssetDragPayload? = await withCheckedContinuation { cont in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.assetIDs.identifier
            ) { data, _ in
                cont.resume(returning: data.flatMap(AssetDragPayload.decode))
            }
        }
        #expect(decoded == payload)
    }

    @Test("the marker payload rides the provider just the same (search/Space hosts)")
    func markerRegisters() {
        let item = tempItem()
        defer { try? FileManager.default.removeItem(at: item.blobURL) }
        let provider = AssetExport.dragProvider(item: item, payload: .internalMarker)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.assetIDs.identifier))
    }
}
