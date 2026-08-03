//
//  LibraryArchiveReaderTests.swift
//  AtelierRefsTests
//
//  008 · H7 — the PURE half of the importer, driven entirely from a temp
//  directory: no library, no blob store, no panel, no sandbox.
//
//  Every archive here is built in memory and written to disk, so each case is
//  exactly the archive it claims to be — including the ones that could not be
//  produced by the writer at all (a manifest naming an asset it doesn't ship, a
//  truncated file, two collections sharing one path). That is the point of
//  splitting the parse out: the cases that matter most are the malformed ones,
//  and a round-trip harness can't make them.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Rig

/// An archive folder assembled by hand.
private struct Fixture {
    let root: URL

    static let when = Date(timeIntervalSince1970: 1_700_000_000)

    static func make(named name: String = "Atelier Archive 2026-08-03") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryArchiveReaderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func write(_ manifest: ArchiveManifest) throws {
        try manifest.write(to: root.appendingPathComponent(ArchiveLayout.manifestFilename))
    }

    /// Raw bytes at the manifest's path — for the "present but not a manifest"
    /// case, which no encoder can produce.
    func writeRawManifest(_ text: String) throws {
        try Data(text.utf8).write(
            to: root.appendingPathComponent(ArchiveLayout.manifestFilename))
    }

    @discardableResult
    func writeFile(_ relative: String, bytes: String = "pixels") throws -> URL {
        let url = relative.split(separator: "/")
            .reduce(root) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func parse(schemaVersion: String = "v18") throws -> ArchiveParse {
        try LibraryArchiveReader.parse(root, schemaVersion: schemaVersion)
    }
}

// MARK: - Manifest builders

private func makeSource(
    _ id: UUID, url: String? = "https://example.com/one", platform: Platform = .pinterest
) -> ArchiveManifest.SourceEntry {
    ArchiveManifest.SourceEntry(Source(
        id: id, platform: platform, originalURL: url,
        authorHandle: "@designer", authorName: "A Designer", title: "A Title",
        capturedAt: Fixture.when,
        rawMetadata: .object(["board": .string("Refs")])))
}

private func makeImage(
    _ id: UUID, source sourceID: UUID, hash: String? = "ab12cd34",
    width: Int? = 10, height: Int? = 12, tags: [(String, TagSource)] = []
) -> ArchiveManifest.AssetEntry {
    ArchiveManifest.AssetEntry(
        Asset(
            id: id, kind: .image, blobHash: hash, mimeType: "image/png",
            width: width, height: height, fileSize: 6,
            downloadState: .downloaded, createdAt: Fixture.when,
            name: "Hero", note: "a note", sourceId: sourceID),
        // Built here rather than taken as a `[Tag]`: `Tag` is ambiguous in a type
        // position inside a Swift Testing file (`Testing.Tag` is the trait type).
        tags: tags.map { Tag(id: UUID(), name: $0.0, source: $0.1) })
}

private func makeColor(
    _ id: UUID, source sourceID: UUID, hex: String = "#ff0055"
) -> ArchiveManifest.AssetEntry {
    ArchiveManifest.AssetEntry(
        Asset(
            id: id, kind: .color, blobHash: nil, mimeType: nil,
            width: nil, height: nil, fileSize: nil,
            downloadState: .downloaded, createdAt: Fixture.when,
            sourceId: sourceID,
            payload: AssetPayload(color: ColorPayload(hex: hex)).jsonString(),
            dedupKey: hex, searchText: hex),
        tags: [])
}

private func makeMembership(
    _ assetID: UUID, in collectionID: UUID, order: Int, file: String?,
    canvas: (Double, Double, Double, Double, Int)? = nil
) -> ArchiveManifest.MembershipEntry {
    ArchiveManifest.MembershipEntry(
        CollectionItem(
            id: UUID(), collectionID: collectionID, assetID: assetID,
            addedAt: Fixture.when, manualOrder: order,
            canvasX: canvas?.0, canvasY: canvas?.1,
            canvasW: canvas?.2, canvasH: canvas?.3, canvasZ: canvas?.4),
        file: file)
}

private func makeCollection(
    _ id: UUID, name: String, parent: UUID? = nil, path: String,
    items: [ArchiveManifest.MembershipEntry] = []
) -> ArchiveManifest.CollectionEntry {
    ArchiveManifest.CollectionEntry(
        Collection(
            id: id, name: name, description: "about \(name)",
            createdAt: Fixture.when, updatedAt: Fixture.when,
            parentCollectionID: parent),
        path: path, items: items)
}

private func makeManifest(
    manifestVersion: Int = ArchiveManifest.currentVersion,
    schemaVersion: String = "v18",
    sources: [ArchiveManifest.SourceEntry] = [],
    assets: [ArchiveManifest.AssetEntry] = [],
    collections: [ArchiveManifest.CollectionEntry] = []
) -> ArchiveManifest {
    ArchiveManifest(
        manifestVersion: manifestVersion, schemaVersion: schemaVersion,
        appVersion: "1.0-test", exportedAt: Fixture.when,
        sources: sources, assets: assets, collections: collections)
}

// MARK: - Well-formed

@Suite("LibraryArchiveReader: reading an archive (008 H7)")
struct LibraryArchiveReaderTests {

    /// The shape everything else is a deviation from: two collections, one
    /// nested, an asset in both, provenance and tags carried through.
    @Test("A well-formed archive becomes plans with verbatim provenance")
    func wellFormed() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sourceID = UUID(), assetID = UUID()
        let parentID = UUID(), childID = UUID()
        try fixture.writeFile("Collections/Design/Hero-ab12cd34.png")
        try fixture.writeFile("Collections/Design/Refs/Hero-ab12cd34.png")
        try fixture.write(makeManifest(
            sources: [makeSource(sourceID)],
            assets: [makeImage(
                assetID, source: sourceID,
                tags: [("brutalist", .user), ("poster", .agent)])],
            collections: [
                makeCollection(
                    parentID, name: "Design", path: "Collections/Design",
                    items: [makeMembership(
                        assetID, in: parentID, order: 0,
                        file: "Collections/Design/Hero-ab12cd34.png",
                        canvas: (10, 20, 30, 40, 5))]),
                makeCollection(
                    childID, name: "Refs", parent: parentID,
                    path: "Collections/Design/Refs",
                    items: [makeMembership(
                        assetID, in: childID, order: 0,
                        file: "Collections/Design/Refs/Hero-ab12cd34.png")]),
            ]))

        let parse = try fixture.parse()

        #expect(parse.name == "Atelier Archive 2026-08-03")
        #expect(parse.manifestVersion == ArchiveManifest.currentVersion)
        #expect(parse.schemaVersion == "v18")
        #expect(parse.skipped.isEmpty)
        #expect(parse.unreferenced.isEmpty)
        #expect(parse.plans.count == 2)

        let design = try #require(parse.plans.first { $0.name == "Design" })
        let refs = try #require(parse.plans.first { $0.name == "Refs" })
        #expect(design.parentKey == nil)
        #expect(refs.parentKey == parentID.uuidString)
        #expect(design.description == "about Design")

        // One asset key in two collections — the replay layer's cue to make one
        // asset and two memberships.
        #expect(design.items.count == 1)
        #expect(refs.items.count == 1)
        #expect(design.items[0].key == refs.items[0].key)

        let item = design.items[0]
        #expect(item.source.platform == .pinterest)
        #expect(item.source.originalURL == "https://example.com/one")
        #expect(item.source.authorHandle == "@designer")
        #expect(item.source.authorName == "A Designer")
        #expect(item.source.title == "A Title")
        #expect(item.source.capturedAt == Fixture.when)
        #expect(item.source.rawMetadata == .object(["board": .string("Refs")]))
        #expect(item.name == "Hero")
        #expect(item.note == "a note")
        #expect(item.tags == [
            ImportTag(name: "brutalist", source: .user),
            ImportTag(name: "poster", source: .agent),
        ])
        #expect(item.placement == CanvasPlacement(x: 10, y: 20, w: 30, h: 40, z: 5))

        guard case let .media(kind, bytes, state) = item.body else {
            Issue.record("expected a media body")
            return
        }
        #expect(kind == .image)
        #expect(state == .downloaded)
        #expect(bytes.mimeType == "image/png")
        #expect(bytes.width == 10)
        #expect(bytes.height == 12)
        #expect(bytes.url.lastPathComponent == "Hero-ab12cd34.png")
    }

    /// A media-less kind has no file and is not a skip: its substance is the
    /// manifest's payload, which the funnel re-derives a canonical form from.
    @Test("A media-less asset parses from its payload, with no file at all")
    func mediaLessAsset() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sourceID = UUID(), assetID = UUID(), collectionID = UUID()
        try fixture.write(makeManifest(
            sources: [makeSource(sourceID, url: nil)],
            assets: [makeColor(assetID, source: sourceID)],
            collections: [makeCollection(
                collectionID, name: "Palette", path: "Collections/Palette",
                items: [makeMembership(assetID, in: collectionID, order: 0, file: nil)])]))

        let parse = try fixture.parse()
        #expect(parse.skipped.isEmpty)
        guard case let .content(draft, card) = parse.plans[0].items[0].body else {
            Issue.record("expected a content body")
            return
        }
        #expect(draft.kind == .color)
        #expect(draft.payload.color?.hex == "#ff0055")
        #expect(card == nil)
        // The funnel is authoritative on these; carrying the archive's copy
        // could only ever disagree with it.
        #expect(draft.dedupKey == nil)
        #expect(draft.searchText == nil)
    }

    /// Empty is a legitimate archive, not an error — an empty library exports
    /// exactly this.
    @Test("An archive of nothing parses to a plan of nothing")
    func emptyArchive() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try fixture.write(makeManifest())

        let parse = try fixture.parse()
        #expect(parse.plans.isEmpty)
        #expect(parse.skipped.isEmpty)
        #expect(parse.unreferenced.isEmpty)
    }
}

// MARK: - Malformed

@Suite("LibraryArchiveReader: archives that can't be read (008 H7)")
struct LibraryArchiveReaderFailureTests {

    /// The manifest is written LAST and atomically, so a folder without one is a
    /// run that never finished — the same commit-record rule `BackupCatalog`
    /// applies to a backup.
    @Test("A folder with no manifest is not an archive")
    func missingManifest() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFile("Collections/Design/Hero-ab12cd34.png")

        #expect(throws: ArchiveReadError.missingManifest) { try fixture.parse() }
    }

    @Test("A manifest that isn't JSON is a refusal to read, not a crash")
    func malformedManifest() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try fixture.writeRawManifest("{ \"manifest_version\": 1, \"sources\": [ ")

        #expect(throws: ArchiveReadError.unreadableManifest) { try fixture.parse() }
    }

    @Test("A manifest missing a required key reads as unreadable")
    func manifestMissingKeys() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try fixture.writeRawManifest("{\"manifest_version\": 1}")

        #expect(throws: ArchiveReadError.unreadableManifest) { try fixture.parse() }
    }

    /// The file an entry points at is gone. The asset is skipped WITH A REASON
    /// and the rest of the archive still imports — one missing image must not
    /// cost a user their whole library.
    @Test("A referenced file that isn't there is a named skip")
    func missingReferencedFile() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sourceID = UUID(), present = UUID(), absent = UUID(), collectionID = UUID()
        try fixture.writeFile("Collections/Design/Here-ab12cd34.png")
        try fixture.write(makeManifest(
            sources: [makeSource(sourceID)],
            assets: [makeImage(present, source: sourceID),
                     makeImage(absent, source: sourceID, hash: "ff00ff00")],
            collections: [makeCollection(
                collectionID, name: "Design", path: "Collections/Design",
                items: [
                    makeMembership(
                        present, in: collectionID, order: 0,
                        file: "Collections/Design/Here-ab12cd34.png"),
                    makeMembership(
                        absent, in: collectionID, order: 1,
                        file: "Collections/Design/Gone-ff00ff00.png"),
                ])]))

        let parse = try fixture.parse()
        #expect(parse.plans[0].items.count == 1)
        #expect(parse.plans[0].items[0].key == present.uuidString)
        #expect(parse.skipped == [ImportSkip(
            collection: "Design", item: absent.uuidString, reason: .missingFile)])
        // A file the manifest NAMES is not a stray, even when it's absent.
        #expect(parse.unreferenced.isEmpty)
    }

    /// A file nobody refers to is reported, never a failure: an archive the user
    /// dropped a README into is still a valid archive.
    @Test("An unreferenced file is counted, not fatal")
    func unreferencedFile() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sourceID = UUID(), assetID = UUID(), collectionID = UUID()
        try fixture.writeFile("Collections/Design/Hero-ab12cd34.png")
        try fixture.writeFile("Collections/Design/stray.png")
        try fixture.writeFile("README.txt", bytes: "hello")
        try fixture.writeFile(".DS_Store", bytes: "junk")
        try fixture.write(makeManifest(
            sources: [makeSource(sourceID)],
            assets: [makeImage(assetID, source: sourceID)],
            collections: [makeCollection(
                collectionID, name: "Design", path: "Collections/Design",
                items: [makeMembership(
                    assetID, in: collectionID, order: 0,
                    file: "Collections/Design/Hero-ab12cd34.png")])]))

        let parse = try fixture.parse()
        #expect(parse.plans[0].items.count == 1)
        #expect(parse.skipped.isEmpty)
        // Hidden files are Finder's, not the archive's.
        #expect(parse.unreferenced == ["Collections/Design/stray.png", "README.txt"])
    }

    @Test("A membership naming an asset the manifest doesn't ship is skipped")
    func unknownAsset() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let missing = UUID(), collectionID = UUID()
        try fixture.write(makeManifest(
            collections: [makeCollection(
                collectionID, name: "Design", path: "Collections/Design",
                items: [makeMembership(missing, in: collectionID, order: 0, file: nil)])]))

        let parse = try fixture.parse()
        #expect(parse.plans[0].items.isEmpty)
        #expect(parse.skipped == [ImportSkip(
            collection: "Design", item: missing.uuidString, reason: .unknownAsset)])
    }

    /// Provenance is non-optional in the funnel (C6), so an asset whose source
    /// the manifest didn't ship cannot be ingested at all.
    @Test("An asset with no shipped source is skipped, not invented")
    func unknownSource() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let assetID = UUID(), collectionID = UUID()
        try fixture.writeFile("Collections/Design/Hero-ab12cd34.png")
        try fixture.write(makeManifest(
            assets: [makeImage(assetID, source: UUID())],
            collections: [makeCollection(
                collectionID, name: "Design", path: "Collections/Design",
                items: [makeMembership(
                    assetID, in: collectionID, order: 0,
                    file: "Collections/Design/Hero-ab12cd34.png")])]))

        let parse = try fixture.parse()
        #expect(parse.plans[0].items.isEmpty)
        #expect(parse.skipped == [ImportSkip(
            collection: "Design", item: assetID.uuidString, reason: .unknownSource)])
    }

    /// The funnel requires positive dimensions; an entry without them is not
    /// something any public writer can be handed, so it is refused here rather
    /// than thrown at `ingest` and reported as a mysterious failure.
    @Test("An image with no dimensions is unusable, not a failure later")
    func unusableAsset() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sourceID = UUID(), assetID = UUID(), collectionID = UUID()
        try fixture.writeFile("Collections/Design/Hero-ab12cd34.png")
        try fixture.write(makeManifest(
            sources: [makeSource(sourceID)],
            assets: [makeImage(assetID, source: sourceID, width: nil, height: nil)],
            collections: [makeCollection(
                collectionID, name: "Design", path: "Collections/Design",
                items: [makeMembership(
                    assetID, in: collectionID, order: 0,
                    file: "Collections/Design/Hero-ab12cd34.png")])]))

        let parse = try fixture.parse()
        #expect(parse.skipped.map(\.reason) == [.unusable])
    }
}

// MARK: - Nesting

@Suite("LibraryArchiveReader: nesting comes from the id (008 H7)")
struct LibraryArchiveReaderNestingTests {

    /// The rule H6 flagged: `path` is where the copies were WRITTEN, and the
    /// archive relocates a folder that would overrun the path budget, so two
    /// unrelated collections can share one. Reconstructing nesting from paths
    /// would merge them; reconstructing it from `parent_collection_id` cannot.
    @Test("Two collections sharing one path keep their separate parents")
    func sharedPathDistinctParents() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let alpha = UUID(), beta = UUID(), oneRefs = UUID(), twoRefs = UUID()
        try fixture.write(makeManifest(collections: [
            makeCollection(alpha, name: "Alpha", path: "Collections/Alpha"),
            makeCollection(beta, name: "Beta", path: "Collections/Beta"),
            // Both relocated to the top of Collections/ under the same name —
            // the shape a deep tree produces.
            makeCollection(oneRefs, name: "Refs", parent: alpha, path: "Collections/Refs"),
            makeCollection(twoRefs, name: "Refs", parent: beta, path: "Collections/Refs"),
        ]))

        let parse = try fixture.parse()
        let plans = Dictionary(uniqueKeysWithValues: parse.plans.map { ($0.key, $0) })
        #expect(plans[oneRefs.uuidString]?.parentKey == alpha.uuidString)
        #expect(plans[twoRefs.uuidString]?.parentKey == beta.uuidString)
        #expect(plans[alpha.uuidString]?.parentKey == nil)
    }

    @Test("Parents come before children, however the manifest is ordered")
    func parentsFirst() {
        let root = ImportPlan(key: "root", name: "Root")
        let child = ImportPlan(key: "child", parentKey: "root", name: "Child")
        let grandchild = ImportPlan(key: "grand", parentKey: "child", name: "Grand")

        let ordered = LibraryImporter.parentsFirst([grandchild, child, root])
        #expect(ordered.map(\.key) == ["root", "child", "grand"])
    }

    /// An importer must not be able to strand a collection by naming a parent it
    /// didn't ship — the plan becomes a root rather than disappearing.
    @Test("A plan whose parent wasn't shipped becomes a root")
    func unknownParentIsARoot() {
        let orphan = ImportPlan(key: "orphan", parentKey: "nowhere", name: "Orphan")
        #expect(LibraryImporter.parentsFirst([orphan]).map(\.key) == ["orphan"])
    }

    /// A cycle can't come out of this app, but a manifest is a FILE. Nothing is
    /// dropped; the cycle's members come out flat.
    @Test("A parent cycle loses nesting, never a collection")
    func cycleKeepsEveryPlan() {
        let a = ImportPlan(key: "a", parentKey: "b", name: "A")
        let b = ImportPlan(key: "b", parentKey: "a", name: "B")
        let free = ImportPlan(key: "c", name: "C")

        let ordered = LibraryImporter.parentsFirst([a, b, free])
        #expect(Set(ordered.map(\.key)) == ["a", "b", "c"])
        #expect(ordered.count == 3)
    }
}

// MARK: - Version refusal

@Suite("LibraryArchiveReader: the version refusal matrix (008 H7)")
struct LibraryArchiveReaderRefusalTests {

    private func fixture(
        manifestVersion: Int = ArchiveManifest.currentVersion, schemaVersion: String = "v18"
    ) throws -> Fixture {
        let fixture = try Fixture.make()
        try fixture.write(makeManifest(
            manifestVersion: manifestVersion, schemaVersion: schemaVersion))
        return fixture
    }

    @Test("A newer manifest version is refused before anything is read")
    func manifestTooNew() throws {
        let fixture = try self.fixture(manifestVersion: ArchiveManifest.currentVersion + 1)
        defer { fixture.cleanup() }

        #expect(throws: ArchiveReadError.refused(
            .manifestTooNew(ArchiveManifest.currentVersion + 1))) { try fixture.parse() }
    }

    @Test("A newer library schema is refused")
    func schemaTooNew() throws {
        let fixture = try self.fixture(schemaVersion: "v19")
        defer { fixture.cleanup() }

        #expect(throws: ArchiveReadError.refused(.schemaTooNew("v19"))) {
            try fixture.parse(schemaVersion: "v18")
        }
    }

    @Test("An older or equal schema reads fine")
    func olderSchemaReads() throws {
        for version in ["v17", "v18"] {
            let fixture = try self.fixture(schemaVersion: version)
            defer { fixture.cleanup() }
            #expect(throws: Never.self) { try fixture.parse(schemaVersion: "v18") }
        }
    }

    /// The rule is "newer than me", and only that. "I can't tell" is not
    /// evidence of "newer" — refusing on an unparseable version would brick an
    /// import over a string this build simply doesn't recognise.
    @Test("An unparseable schema version on EITHER side is not a refusal")
    func unparseableIsNotARefusal() throws {
        let archiveSide = try fixture(schemaVersion: "banana")
        defer { archiveSide.cleanup() }
        #expect(throws: Never.self) { try archiveSide.parse(schemaVersion: "v18") }

        let localSide = try fixture(schemaVersion: "v99")
        defer { localSide.cleanup() }
        #expect(throws: Never.self) { try localSide.parse(schemaVersion: "banana") }
    }

    /// A refusal must beat everything else: an archive that is BOTH too new and
    /// missing its files never reaches the point of counting skips.
    @Test("A refusal wins over anything else wrong with the archive")
    func refusalIsFirst() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sourceID = UUID(), assetID = UUID(), collectionID = UUID()
        try fixture.write(makeManifest(
            manifestVersion: ArchiveManifest.currentVersion + 1,
            sources: [makeSource(sourceID)],
            assets: [makeImage(assetID, source: sourceID)],
            collections: [makeCollection(
                collectionID, name: "Design", path: "Collections/Design",
                items: [makeMembership(
                    assetID, in: collectionID, order: 0,
                    file: "Collections/Design/Gone.png")])]))

        #expect(throws: ArchiveReadError.refused(
            .manifestTooNew(ArchiveManifest.currentVersion + 1))) { try fixture.parse() }
    }
}

// MARK: - Prose

@Suite("ArchiveImportCopy: what an import says (008 H7)")
struct ArchiveImportCopyTests {

    @Test("A refusal names the axis so the user can search for it")
    func refusalProse() {
        #expect(ArchiveImportCopy.message(for: .manifestTooNew(9)).contains("manifest version 9"))
        #expect(ArchiveImportCopy.message(for: .schemaTooNew("v19")).contains("v19"))
        // Both must say plainly that the library is untouched.
        #expect(ArchiveImportCopy.message(for: .manifestTooNew(9)).contains("Nothing was changed"))
        #expect(ArchiveImportCopy.message(for: .schemaTooNew("v19")).contains("Nothing was changed"))
    }

    @Test("A missing manifest is explained as an unfinished export")
    func readErrorProse() {
        #expect(ArchiveImportCopy.message(for: .missingManifest).contains("manifest.json"))
        #expect(ArchiveImportCopy.message(for: .unreadableManifest).contains("Nothing was imported"))
        #expect(ArchiveImportCopy.message(for: .refused(.manifestTooNew(2)))
            == ArchiveImportCopy.message(for: .manifestTooNew(2)))
    }

    /// A bare "succeeded" over a partial import is the outcome 004 taught this
    /// codebase not to report.
    @Test("The status line counts what happened, including what didn't")
    func statusLine() {
        var summary = ImportRunSummary(
            outcome: .succeeded, finishedAt: .now, destinationName: "Archive",
            collections: 3, assets: 4, newAssets: 4, memberships: 5)
        #expect(ArchiveImportCopy.statusLine(for: summary)
            == "Imported 4 items in 3 collections into “Archive”.")

        summary.outcome = .incomplete
        summary.skipped = 1
        summary.failed = 2
        #expect(ArchiveImportCopy.statusLine(for: summary)?
            .contains("1 item couldn’t be read") == true)
        #expect(ArchiveImportCopy.statusLine(for: summary)?
            .contains("2 items couldn’t be added") == true)

        summary.skipped = 0
        summary.failed = 0
        summary.newAssets = 1
        #expect(ArchiveImportCopy.statusLine(for: summary)?
            .contains("3 already in your library") == true)
    }

    @Test("A stopped import says what it kept; a refusal says nothing twice")
    func terminalStates() {
        let cancelled = ImportRunSummary(outcome: .cancelled, finishedAt: .now)
        #expect(ArchiveImportCopy.statusLine(for: cancelled)?.contains("kept") == true)
        // The message line carries these, in orange — a second sentence under it
        // would say the same thing twice.
        #expect(ArchiveImportCopy.statusLine(
            for: ImportRunSummary(outcome: .refused, finishedAt: .now)) == nil)
        #expect(ArchiveImportCopy.statusLine(
            for: ImportRunSummary(outcome: .failed, finishedAt: .now)) == nil)
        #expect(ArchiveImportCopy.statusLine(for: nil) == nil)
    }

    @Test("Folder-access failures are named separately")
    func folderAccessProse() {
        #expect(ArchiveImportCopy.message(for: .noFolderChosen).contains("No archive folder"))
        #expect(ArchiveImportCopy.message(for: .bookmarkUnresolvable).contains("reached"))
        #expect(ArchiveImportCopy.message(for: .accessDenied).contains("allowed to read"))
    }
}
