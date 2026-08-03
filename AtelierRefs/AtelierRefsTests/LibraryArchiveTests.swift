//
//  LibraryArchiveTests.swift
//  AtelierRefsTests
//
//  008 · H6 — the archive CONTRACT, host-free.
//
//  The golden-file test below is the point of this file: `manifest.json` is what
//  the importer (H7) and every future build read, so a change to its shape must
//  break a test loudly rather than ship as a silently different document.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

/// Fixed ids and dates, so the golden manifest is a constant.
private enum Fixture {
    static let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let assetID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let parentID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let childID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let itemID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    static let tagID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    /// 2026-01-02T03:04:05Z, with sub-second noise the wire format must drop.
    static let when = Date(timeIntervalSince1970: 1_767_323_045.678)

    static var source: Source {
        Source(
            id: sourceID, platform: .pinterest,
            originalURL: "https://pinterest.com/pin/1",
            authorHandle: "@designer", authorName: "A Designer",
            title: "Hero", capturedAt: when,
            rawMetadata: .object(["board": .string("Refs"), "saves": .number(12)]))
    }

    static var asset: Asset {
        Asset(
            id: assetID, kind: .image, blobHash: "ab12cd34ef567890",
            mimeType: "image/png", width: 800, height: 600, duration: nil,
            fileSize: 4096, downloadState: .downloaded, createdAt: when,
            name: "Named", note: "A note", sourceId: sourceID,
            viewCount: 3, lastViewedAt: when, payload: nil,
            dedupKey: nil, searchText: nil)
    }

    static var parent: Collection {
        Collection(
            id: parentID, name: "Design", description: "Top level",
            coverAssetID: nil, createdAt: when, updatedAt: when,
            parentCollectionID: nil, sortMode: .manual, sortIndex: 0)
    }

    static var child: Collection {
        Collection(
            id: childID, name: "Refs", description: nil, coverAssetID: assetID,
            createdAt: when, updatedAt: when, parentCollectionID: parentID,
            sortMode: .newest, sortIndex: 1)
    }

    static var item: CollectionItem {
        CollectionItem(
            id: itemID, collectionID: childID, assetID: assetID, addedAt: when,
            manualOrder: 0, canvasX: 12.5, canvasY: -4, canvasW: 100,
            canvasH: 50, canvasZ: 2)
    }

    static var manifest: ArchiveManifest {
        ArchiveManifest(
            schemaVersion: "v18", appVersion: "1.2-test", exportedAt: when,
            sources: [ArchiveManifest.SourceEntry(source)],
            assets: [ArchiveManifest.AssetEntry(
                asset, tags: [Tag(id: tagID, name: "moody", source: .user)])],
            collections: [
                ArchiveManifest.CollectionEntry(
                    parent, path: "Collections/Design", items: []),
                ArchiveManifest.CollectionEntry(
                    child, path: "Collections/Design/Refs",
                    items: [ArchiveManifest.MembershipEntry(
                        item, file: "Collections/Design/Refs/Hero-ab12cd34.png")]),
            ])
    }
}

// MARK: - The contract

@Suite("LibraryArchive: manifest.json contract (008 H6)")
struct ArchiveManifestGoldenTests {

    /// The golden file. If this test fails, the manifest's SHAPE changed — which
    /// is allowed, but only alongside a `manifest_version` bump and a matching
    /// change in the importer. Never "fix" it by pasting the new output.
    private static let golden = """
        {
          "app_version" : "1.2-test",
          "assets" : [
            {
              "blob_hash" : "ab12cd34ef567890",
              "created_at" : "2026-01-02T03:04:05Z",
              "download_state" : "downloaded",
              "file_size" : 4096,
              "height" : 600,
              "id" : "22222222-2222-2222-2222-222222222222",
              "kind" : "image",
              "last_viewed_at" : "2026-01-02T03:04:05Z",
              "mime_type" : "image\\/png",
              "name" : "Named",
              "note" : "A note",
              "source_id" : "11111111-1111-1111-1111-111111111111",
              "tags" : [
                {
                  "name" : "moody",
                  "source" : "user"
                }
              ],
              "view_count" : 3,
              "width" : 800
            }
          ],
          "collections" : [
            {
              "created_at" : "2026-01-02T03:04:05Z",
              "description" : "Top level",
              "id" : "33333333-3333-3333-3333-333333333333",
              "items" : [

              ],
              "name" : "Design",
              "path" : "Collections\\/Design",
              "sort_index" : 0,
              "sort_mode" : "manual",
              "updated_at" : "2026-01-02T03:04:05Z"
            },
            {
              "cover_asset_id" : "22222222-2222-2222-2222-222222222222",
              "created_at" : "2026-01-02T03:04:05Z",
              "id" : "44444444-4444-4444-4444-444444444444",
              "items" : [
                {
                  "added_at" : "2026-01-02T03:04:05Z",
                  "asset_id" : "22222222-2222-2222-2222-222222222222",
                  "canvas_h" : 50,
                  "canvas_w" : 100,
                  "canvas_x" : 12.5,
                  "canvas_y" : -4,
                  "canvas_z" : 2,
                  "file" : "Collections\\/Design\\/Refs\\/Hero-ab12cd34.png",
                  "manual_order" : 0
                }
              ],
              "name" : "Refs",
              "parent_collection_id" : "33333333-3333-3333-3333-333333333333",
              "path" : "Collections\\/Design\\/Refs",
              "sort_index" : 1,
              "sort_mode" : "newest",
              "updated_at" : "2026-01-02T03:04:05Z"
            }
          ],
          "exported_at" : "2026-01-02T03:04:05Z",
          "manifest_version" : 1,
          "schema_version" : "v18",
          "sources" : [
            {
              "author_handle" : "@designer",
              "author_name" : "A Designer",
              "captured_at" : "2026-01-02T03:04:05Z",
              "id" : "11111111-1111-1111-1111-111111111111",
              "original_url" : "https:\\/\\/pinterest.com\\/pin\\/1",
              "platform" : "pinterest",
              "raw_metadata" : {
                "board" : "Refs",
                "saves" : 12
              },
              "title" : "Hero"
            }
          ]
        }
        """

    @Test("The manifest serializes to the pinned golden document")
    func goldenSerialization() throws {
        let data = try ArchiveManifest.makeEncoder().encode(Fixture.manifest)
        #expect(String(decoding: data, as: UTF8.self) == Self.golden)
    }

    @Test("The golden document decodes back to the same manifest")
    func goldenRoundTrip() throws {
        let decoded = try ArchiveManifest.makeDecoder()
            .decode(ArchiveManifest.self, from: Data(Self.golden.utf8))
        #expect(decoded == Fixture.manifest)
    }

    /// Sub-second precision the wire format cannot carry is dropped ON THE WAY
    /// IN, so the in-memory manifest and the on-disk one are the same value —
    /// otherwise every "is this the archive I wrote?" comparison is quietly
    /// false.
    @Test("Timestamps are truncated to whole seconds in memory, not just on disk")
    func secondPrecision() {
        #expect(Fixture.manifest.exportedAt.timeIntervalSince1970 == 1_767_323_045)
        #expect(Fixture.manifest.assets[0].createdAt.timeIntervalSince1970 == 1_767_323_045)
        #expect(Fixture.manifest.collections[1].items[0].addedAt.timeIntervalSince1970
            == 1_767_323_045)
    }

    @Test("A manifest written to disk reads back identically")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Fixture.manifest.write(to: url)
        #expect(try ArchiveManifest.read(from: url) == Fixture.manifest)
    }

    /// Provenance is what `ingest`'s 18A dedup matches on. A normalized or
    /// dropped field here forks a second asset over the same bytes on re-import.
    @Test("Provenance rides verbatim — url, handle, name, title, raw metadata")
    func provenanceIsVerbatim() {
        let entry = Fixture.manifest.sources[0]
        #expect(entry.originalURL == "https://pinterest.com/pin/1")
        #expect(entry.authorHandle == "@designer")
        #expect(entry.authorName == "A Designer")
        #expect(entry.title == "Hero")
        #expect(entry.platform == .pinterest)
        #expect(entry.rawMetadata == .object(["board": .string("Refs"), "saves": .number(12)]))
    }
}

// MARK: - Version refusal

@Suite("LibraryArchive: version refusal (008 H6)")
struct ArchiveRefusalTests {

    private func manifest(manifestVersion: Int, schema: String) -> ArchiveManifest {
        ArchiveManifest(
            manifestVersion: manifestVersion, schemaVersion: schema,
            appVersion: "t", exportedAt: Date(),
            sources: [], assets: [], collections: [])
    }

    @Test("A manifest at this build's versions is accepted")
    func current() {
        #expect(ArchiveManifest.refusal(
            for: manifest(manifestVersion: ArchiveManifest.currentVersion, schema: "v18"),
            schemaVersion: "v18") == nil)
    }

    @Test("An OLDER manifest version is accepted — the rule is 'newer than me'")
    func olderManifest() {
        #expect(ArchiveManifest.refusal(
            for: manifest(manifestVersion: 0, schema: "v3"), schemaVersion: "v18") == nil)
    }

    @Test("A newer manifest version is refused")
    func newerManifest() {
        let next = ArchiveManifest.currentVersion + 1
        #expect(ArchiveManifest.refusal(
            for: manifest(manifestVersion: next, schema: "v18"), schemaVersion: "v18")
            == .manifestTooNew(next))
    }

    @Test("A newer schema version is refused")
    func newerSchema() {
        #expect(ArchiveManifest.refusal(
            for: manifest(manifestVersion: 1, schema: "v19"), schemaVersion: "v18")
            == .schemaTooNew("v19"))
    }

    /// "I can't tell" is not evidence of "newer". Refusing on an unparseable
    /// version would brick an import over a version string this build simply
    /// doesn't recognise.
    @Test("An UNPARSEABLE version on either side is not a refusal", arguments: [
        ("2026.1", "v18"), ("v18", "2026.1"), ("", "v18"), ("vNext", "v18"),
    ])
    func unparseable(archive: String, local: String) {
        #expect(ArchiveManifest.refusal(
            for: manifest(manifestVersion: 1, schema: archive), schemaVersion: local) == nil)
    }

    @Test("The manifest rule wins over the schema rule when both trip")
    func manifestRuleFirst() {
        let next = ArchiveManifest.currentVersion + 1
        #expect(ArchiveManifest.refusal(
            for: manifest(manifestVersion: next, schema: "v99"), schemaVersion: "v18")
            == .manifestTooNew(next))
    }

    @Test("schemaOrdinal reads vN and nothing else", arguments: [
        ("v18", 18), ("v0", 0), ("v", nil), ("18", nil), ("va", nil), ("V18", nil),
    ] as [(String, Int?)])
    func ordinals(version: String, expected: Int?) {
        #expect(ArchiveManifest.schemaOrdinal(version) == expected)
    }
}

// MARK: - Layout

@Suite("LibraryArchive: ArchiveLayout paths (008 H6)")
struct ArchiveLayoutTests {

    private let id = UUID(uuidString: "3F2A1B9C-0000-0000-0000-000000000000")!

    @Test("A shallow collection nests under its parent, unchanged")
    func shallowNesting() {
        let placement = ArchiveLayout.placement(
            parent: ["Collections", "Design"], name: "Refs", collectionID: id)
        #expect(placement.parent == ["Collections", "Design"])
        #expect(placement.name == "Refs")
    }

    /// The deep-nesting case. `AssetExport.sanitize` caps a component at 60
    /// characters, so a tree deep enough still overruns the relative-path budget
    /// — and a path the filesystem refuses is a failed export, whereas a flatter
    /// folder is a cosmetic loss the manifest's `parent_collection_id` undoes.
    @Test("A collection too deep to nest is relocated to the top of Collections/")
    func deepNestingRelocates() {
        let deep = ["Collections"] + Array(repeating: String(repeating: "n", count: 60), count: 20)
        #expect(!ArchiveLayout.fits(deep))
        let placement = ArchiveLayout.placement(parent: deep, name: "Leaf", collectionID: id)
        #expect(placement.parent == ["Collections"])
        #expect(placement.name == "Leaf-3f2a1b9c")
    }

    /// Two deep folders that happen to share a name must not become one folder.
    @Test("A relocated folder carries the collection's id, so names can't merge")
    func relocationDisambiguates() {
        let deep = ["Collections"] + Array(repeating: String(repeating: "n", count: 60), count: 20)
        let other = UUID(uuidString: "AAAABBBB-0000-0000-0000-000000000000")!
        let first = ArchiveLayout.placement(parent: deep, name: "Leaf", collectionID: id)
        let second = ArchiveLayout.placement(parent: deep, name: "Leaf", collectionID: other)
        #expect(first.name != second.name)
    }

    /// Emoji are 4 UTF-8 bytes each, so a 60-CHARACTER cap is a 240-BYTE one.
    /// The budget is counted in bytes because `PATH_MAX` is.
    @Test("The budget is counted in bytes, not characters")
    func budgetIsBytes() {
        let emoji = String(repeating: "🌸", count: 60)
        let chars = String(repeating: "n", count: 60)
        #expect(ArchiveLayout.fits(["Collections", chars, chars, chars]))
        #expect(!ArchiveLayout.fits(["Collections"] + Array(repeating: emoji, count: 3)))
    }

    @Test("A relative path is /-joined and never absolute")
    func relativePath() {
        #expect(ArchiveLayout.relativePath(["Collections", "A", "b.png"]) == "Collections/A/b.png")
        #expect(ArchiveLayout.relativePath([]) == "")
    }

    @Test("A budget-fitting directory leaves room for the longest filename")
    func reserveHoldsAFilename() {
        // The worst filename the naming layer can produce: 60 emoji + hash + ext.
        let worst = AssetExport.filename(
            base: String(repeating: "🌸", count: 80), blobHash: "ab12cd34ef", ext: "jpeg")
        let directory = ["Collections", String(repeating: "n", count: 60)]
        #expect(ArchiveLayout.fits(directory))
        #expect(ArchiveLayout.relativePath(directory + [worst]).utf8.count
            <= ArchiveLayout.maxRelativeBytes)
    }
}

// MARK: - Folder names + progress

@Suite("LibraryArchive: folder names and progress (008 H6)")
struct ArchiveWriterPureTests {

    @Test("A collection folder is the shared sanitizer's output")
    func folderNames() {
        #expect(LibraryArchiveWriter.folderName(for: "Refs / Q3") == "Refs Q3")
        #expect(LibraryArchiveWriter.folderName(for: "  spaced  ") == "spaced")
    }

    /// `sanitize` falls back to `"image"`, which is the right word for one file
    /// and the wrong one for a folder of many.
    @Test("A nameless collection becomes 'Refs', never 'image'")
    func namelessFolder() {
        #expect(LibraryArchiveWriter.folderName(for: "   ") == "Refs")
        #expect(LibraryArchiveWriter.folderName(for: "///") == "Refs")
        #expect(LibraryArchiveWriter.folderName(for: " . - ") == "Refs")
    }

    /// The fallback keys off the INPUT, so a collection the user really did call
    /// "image" keeps its own name.
    @Test("A collection genuinely called 'image' keeps that name")
    func literalImageFolder() {
        #expect(LibraryArchiveWriter.folderName(for: "image") == "image")
    }

    @Test("Progress is monotonic and bounded to 0…1")
    func progressBounds() {
        #expect(LibraryArchiveWriter.fraction(collection: 0, of: 4, item: 0, of: 0) == 0)
        #expect(LibraryArchiveWriter.fraction(collection: 0, of: 4, item: 1, of: 2) == 0.125)
        #expect(LibraryArchiveWriter.fraction(collection: 4, of: 4, item: 0, of: 0) == 1)
        #expect(LibraryArchiveWriter.fraction(collection: 9, of: 4, item: 0, of: 0) == 1)
    }

    /// An empty library still has the seeded Unsorted folder, but a raw database
    /// with no collections at all must not divide by zero.
    @Test("No collections means the run is already done, not a divide by zero")
    func noCollections() {
        #expect(LibraryArchiveWriter.fraction(collection: 0, of: 0, item: 0, of: 0) == 1)
    }
}

// MARK: - Words

@Suite("LibraryArchive: the words a run reports (008 H6)")
struct ArchiveCopyTests {

    @Test("The suggested folder name is dated, so two archives are tellable apart")
    func suggestedName() {
        let date = Date(timeIntervalSince1970: 1_767_323_045)
        #expect(ArchiveCopy.suggestedName(for: date).hasPrefix("Atelier Archive 2026-01-"))
    }

    @Test("A clean run counts what it wrote")
    func successLine() {
        let summary = ArchiveRunSummary(
            outcome: .succeeded, finishedAt: Date(), collections: 3, assets: 7, files: 9)
        #expect(ArchiveCopy.statusLine(for: summary) == "Archived 7 items in 3 collections.")
    }

    @Test("A run that couldn't copy everything says so rather than claiming success")
    func incompleteLine() {
        let summary = ArchiveRunSummary(
            outcome: .incomplete, finishedAt: Date(), collections: 1, assets: 1,
            files: 0, skipped: 1)
        #expect(ArchiveCopy.statusLine(for: summary)
            == "Archived 1 item in 1 collection. 1 file couldn't be copied.")
    }

    @Test("A cancelled run says the folder is incomplete, not that it failed")
    func cancelledLine() {
        let summary = ArchiveRunSummary(outcome: .cancelled, finishedAt: Date())
        #expect(ArchiveCopy.statusLine(for: summary)?.contains("stopped") == true)
    }

    /// A failure already shows its own message in orange; a second line
    /// restating it would be noise.
    @Test("A failed run has no status line — its message carries the words")
    func failedLine() {
        #expect(ArchiveCopy.statusLine(for: .failure("nope")) == nil)
        #expect(ArchiveCopy.statusLine(for: nil) == nil)
    }

    @Test("Every folder-access failure maps to its own sentence")
    func folderMessages() {
        let messages = [FolderAccessError.noFolderChosen, .bookmarkUnresolvable, .accessDenied]
            .map(ArchiveCopy.message(for:))
        #expect(Set(messages).count == 3)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }
}
