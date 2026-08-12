//
//  LibraryArchiveRoundTripTests.swift
//  AtelierRefsTests
//
//  008 · H7 — the half a fixture can't prove: that a real library, written out
//  by H6's writer and read back by H7's reader and replay layer, arrives whole.
//
//  Two temp libraries and an archive folder between them, so "the same" is
//  measured across a real export and a real import rather than asserted about a
//  plan. The load-bearing assertions here are COUNTS: 18A dedup reuses an asset
//  only when the incoming provenance matches, so a source field the archive
//  dropped or normalized would still leave every asset PRESENT — as a second
//  copy. Presence proves nothing; counting does.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Rig

/// A source library, a destination library, and an archive folder between them.
@MainActor
private struct RoundTripRig {
    let root: URL
    let source: AppServices
    let sourceStore: MediaStore
    let target: AppServices
    let targetStore: MediaStore
    let archive: URL

    var archiveName: String { archive.lastPathComponent }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func make(archiveNamed name: String = "Studio Archive") throws -> RoundTripRig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryArchiveRoundTripTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        for directory in [sourceRoot, targetRoot] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        return RoundTripRig(
            root: root,
            source: try AppServices(
                databasePath: sourceRoot.appendingPathComponent("library.sqlite").path),
            sourceStore: MediaStore(root: sourceRoot),
            target: try AppServices(
                databasePath: targetRoot.appendingPathComponent("library.sqlite").path),
            targetStore: MediaStore(root: targetRoot),
            archive: root.appendingPathComponent(name, isDirectory: true))
    }

    // MARK: Seeding

    /// Ingest one byte-backed asset into the SOURCE library, with its blob
    /// really on disk under its REAL content hash — the importer re-hashes what
    /// it stores, so a fabricated hash would be a fabricated test.
    @discardableResult
    func seedImage(
        bytes: String, into collectionID: UUID, title: String? = "Hero",
        url: String? = nil, platform: Platform = .pinterest,
        name: String? = nil, note: String? = nil, favorite: Bool = false,
        archived: Bool = false
    ) async throws -> Asset {
        let data = Data(bytes.utf8)
        let hash = ContentHasher.hash(data)
        if !sourceStore.hasBlob(hash: hash, fileExtension: "png") {
            try sourceStore.storeBlob(data, hash: hash, fileExtension: "png")
        }
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 40, height: 30, duration: nil, fileSize: data.count,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: platform, originalURL: url ?? "https://example.com/\(bytes)",
            authorHandle: "@designer", authorName: "A Designer", title: title,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawMetadata: .object(["board": .string("Refs"), "n": .number(3)]))
        let asset = try await self.source.ingest(draft, from: source, into: collectionID).asset
        if let name { try await self.source.setName(name, for: asset.id) }
        if let note { try await self.source.setNote(note, for: asset.id) }
        if favorite { try await self.source.setFavorite(true, for: asset.id) }
        if archived { try await self.source.archive([asset.id]) }
        return asset
    }

    /// The favorite flag as the TARGET library holds it, by source title — the
    /// question a favorites round trip is actually asking.
    func targetFavorites(_ collection: String) async throws -> [String: Bool] {
        Dictionary(
            try await targetItems(collection).map { ($0.source.title ?? "", $0.asset.isFavorite) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Whether each item is on the TARGET's shelf, by source title. Reads with
    /// `includeArchived: true` on purpose — the browse read cannot see the
    /// answer, which is the whole point of the round trip.
    func targetArchived(_ collection: String) async throws -> [String: Bool] {
        guard let c = try await targetCollections()[collection] else { return [:] }
        let details = try await target.collectionItems(
            in: c.id, sort: .manual, includeArchived: true)
        return Dictionary(
            details.map { ($0.source.title ?? "", $0.asset.archivedAt != nil) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: Running

    func export() async throws {
        let writer = LibraryArchiveWriter(
            services: source, store: sourceStore, appVersion: "1.0-test",
            schemaVersion: "v18")
        _ = try await writer.write(
            to: archive, isCancelled: { false }, onProgress: { _ in })
    }

    @discardableResult
    func importIntoTarget(
        flag: CancelFlag = CancelFlag(),
        snapshot: @escaping @Sendable () async -> Void = {},
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> ImportRunSummary {
        await ArchiveImportController.perform(
            services: target, store: targetStore,
            folder: DirectFolderAccess(url: archive),
            snapshot: snapshot, flag: flag, onProgress: onProgress)
    }

    // MARK: Reading the result

    /// Every collection in the TARGET, by name. Names are unique among siblings
    /// and these fixtures never reuse one across the tree.
    func targetCollections() async throws -> [String: Collection] {
        Dictionary(
            try await target.listCollections().map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    func targetItems(_ name: String) async throws -> [CollectionItemDetail] {
        guard let collection = try await targetCollections()[name] else { return [] }
        return try await target.collectionItems(in: collection.id, sort: .manual, includeArchived: false)
    }

    /// Distinct assets in a library, counted across every collection — the
    /// number that a dropped provenance field silently doubles.
    func assetCount(in services: AppServices) async throws -> Int {
        var ids: Set<UUID> = []
        for collection in try await services.listCollections() {
            for detail in try await services.collectionItems(in: collection.id, sort: .manual, includeArchived: false) {
                ids.insert(detail.asset.id)
            }
        }
        return ids.count
    }

    /// Rewrite the archive's manifest in place — the seam for the cases only a
    /// hand-edited archive can produce.
    func editManifest(_ edit: (inout ArchiveManifest) -> Void) throws {
        let url = archive.appendingPathComponent(ArchiveLayout.manifestFilename)
        var manifest = try ArchiveManifest.read(from: url)
        edit(&manifest)
        try manifest.write(to: url)
    }
}

// MARK: - The round trip

@MainActor
@Suite("LibraryArchive: export → import round trip (008 H7)")
struct LibraryArchiveRoundTripTests {

    /// The whole contract in one case: nesting, memberships, manual order,
    /// tags, name, note, provenance and the bytes themselves.
    @Test("A library survives a full export and re-import")
    func fullRoundTrip() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let design = try await rig.source.createCollection(name: "Design")
        let refs = try await rig.source.createCollection(name: "Refs", parent: design.id)
        let first = try await rig.seedImage(
            bytes: "alpha", into: refs.id, title: "Alpha",
            url: "https://example.com/alpha", name: "Alpha Name", note: "Alpha note")
        let second = try await rig.seedImage(
            bytes: "beta", into: refs.id, title: "Beta",
            url: "https://example.com/beta")
        _ = try await rig.source.applyTag("brutalist", to: first.id, source: .user)
        _ = try await rig.source.applyTag("poster", to: first.id, source: .agent)
        // A deliberate NON-alphabetical manual order, so "preserved" can't be
        // accidentally satisfied by any natural sort.
        try await rig.source.setGridOrder(
            collectionID: refs.id, orderedAssetIDs: [second.id, first.id])

        try await rig.export()
        let summary = await rig.importIntoTarget()

        #expect(summary.outcome == .succeeded)
        #expect(summary.destinationName == "Studio Archive")
        #expect(summary.skipped == 0)
        #expect(summary.failed == 0)
        #expect(summary.newAssets == 2)

        // Nesting: the archive's roots hang off the destination, not the library.
        let collections = try await rig.targetCollections()
        let destination = try #require(collections["Studio Archive"])
        #expect(destination.parentCollectionID == nil)
        #expect(collections["Design"]?.parentCollectionID == destination.id)
        #expect(collections["Refs"]?.parentCollectionID == collections["Design"]?.id)

        // Manual order, verbatim.
        let items = try await rig.targetItems("Refs")
        #expect(items.count == 2)
        #expect(items.map { $0.source.title } == ["Beta", "Alpha"])

        let alpha = try #require(items.first { $0.source.title == "Alpha" })
        #expect(alpha.asset.name == "Alpha Name")
        #expect(alpha.asset.note == "Alpha note")
        #expect(alpha.asset.width == 40)
        #expect(alpha.asset.height == 30)
        #expect(alpha.asset.kind == .image)
        #expect(alpha.asset.downloadState == .downloaded)

        // Provenance, field for field — this is what makes a re-import idempotent.
        #expect(alpha.source.platform == .pinterest)
        #expect(alpha.source.originalURL == "https://example.com/alpha")
        #expect(alpha.source.authorHandle == "@designer")
        #expect(alpha.source.authorName == "A Designer")
        #expect(alpha.source.capturedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(alpha.source.rawMetadata
            == .object(["board": .string("Refs"), "n": .number(3)]))

        let tags = try await rig.target.tags(for: alpha.asset.id)
        #expect(tags.map(\.name) == ["brutalist", "poster"])
        #expect(Set(tags.map(\.source)) == [.user, .agent])

        // The bytes themselves, not just a row that mentions them.
        let hash = try #require(alpha.asset.blobHash)
        #expect(try rig.targetStore.readBlob(hash: hash, fileExtension: "png")
            == Data("alpha".utf8))
        #expect(hash == ContentHasher.hash(Data("alpha".utf8)))
    }

    /// **The regression the manifest change exists for (011 · U5).** Favorites are
    /// user intent — nothing can recompute them — so an archive that dropped the
    /// flag would lose it on the first export after the feature shipped, silently
    /// and irreversibly. Measured end to end: a real export, a real import, two
    /// separate libraries.
    ///
    /// The NEGATIVE half is load-bearing. Asserting only that the starred item
    /// arrives starred would also pass if the importer starred everything, which is
    /// the more likely bug in a replay layer that applies favorites like tags.
    @Test("Favorites survive a full export and re-import")
    func favoritesRoundTrip() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let refs = try await rig.source.createCollection(name: "Refs")
        try await rig.seedImage(
            bytes: "starred", into: refs.id, title: "Starred",
            url: "https://example.com/starred", favorite: true)
        try await rig.seedImage(
            bytes: "plain", into: refs.id, title: "Plain",
            url: "https://example.com/plain")

        try await rig.export()
        // The manifest itself carries it — checked before the import, so a failure
        // here names the WRITER rather than looking like an importer bug.
        let manifest = try ArchiveManifest.read(
            from: rig.archive.appendingPathComponent(ArchiveLayout.manifestFilename))
        #expect(Set(manifest.assets.map(\.isFavorite)) == [true, false])

        let summary = await rig.importIntoTarget()
        #expect(summary.outcome == .succeeded)
        #expect(summary.newAssets == 2)
        #expect(try await rig.targetFavorites("Refs") == ["Starred": true, "Plain": false])
    }

    /// **The regression the `suppressed_tags` manifest field exists for
    /// (012 · I3).** A dismissed suggestion is user intent by the same test the
    /// star passes — nothing can recompute which labels someone refused — and a
    /// restore that dropped them would re-suggest every one of them on the first
    /// idle pass after the import. That is the exact failure `tag_suppression`
    /// was built to prevent, arrived at by a different road, and it would surface
    /// days later as "the tags I deleted keep coming back".
    ///
    /// The NEGATIVE half is load-bearing, as with favorites: asserting only that
    /// the refusal arrives would also pass if the importer suppressed every tag
    /// it saw, which is the likelier bug in a replay layer that applies refusals
    /// like tags.
    @Test("Dismissed suggestions survive a full export and re-import")
    func suppressionsRoundTrip() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let refs = try await rig.source.createCollection(name: "Refs")
        let refused = try await rig.seedImage(
            bytes: "refused", into: refs.id, title: "Refused",
            url: "https://example.com/refused")
        let plain = try await rig.seedImage(
            bytes: "plain", into: refs.id, title: "Plain",
            url: "https://example.com/plain")
        _ = try await rig.source.applyTag("poster", to: refused.id, source: .agent)
        try await rig.source.dismissSuggestion("poster", on: refused.id)
        _ = try await rig.source.applyTag("brutalist", to: plain.id, source: .user)

        try await rig.export()
        // The WRITER's half, checked before the import so a failure here names it.
        let manifest = try ArchiveManifest.read(
            from: rig.archive.appendingPathComponent(ArchiveLayout.manifestFilename))
        #expect(manifest.assets.compactMap(\.suppressedTags) == [["poster"]])

        let summary = await rig.importIntoTarget()
        #expect(summary.outcome == .succeeded)
        #expect(summary.newAssets == 2)

        let items = try await rig.targetItems("Refs")
        let restoredRefused = try #require(items.first { $0.source.title == "Refused" })
        let restoredPlain = try #require(items.first { $0.source.title == "Plain" })
        #expect(try await rig.target.suppressedTagNames(for: restoredRefused.asset.id) == ["poster"])
        // The negative half: nothing else picked up a refusal.
        #expect(try await rig.target.suppressedTagNames(for: restoredPlain.asset.id).isEmpty)
        // And the user's own tag is untouched by any of it.
        #expect(try await rig.target.tags(for: restoredPlain.asset.id).map(\.name) == ["brutalist"])
    }

    /// **The regression the `includeArchived: true` in the writer exists for
    /// (023 · A).** A backup is a COPY of the library, not a view of it, so the
    /// writer walks every collection including the shelf — and the moment it
    /// does, `archived_at` has to ride the manifest or the restore puts the
    /// user's whole shelf back in the middle of their collections.
    ///
    /// Both halves matter. Without the writer change the archived item is not in
    /// the archive AT ALL (`newAssets` would be 1); without the manifest field
    /// it is there but comes back un-archived. The negative half — that the
    /// plain item does NOT arrive archived — is what catches an importer that
    /// archives everything, the likelier bug in a replay layer.
    @Test("Archived items survive a full export and re-import, still archived")
    func archivedRoundTrip() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let refs = try await rig.source.createCollection(name: "Refs")
        try await rig.seedImage(
            bytes: "shelved", into: refs.id, title: "Shelved",
            url: "https://example.com/shelved", archived: true)
        try await rig.seedImage(
            bytes: "plain", into: refs.id, title: "Plain",
            url: "https://example.com/plain")

        try await rig.export()
        // The manifest carries it — checked before the import, so a failure here
        // names the WRITER rather than looking like an importer bug.
        let manifest = try ArchiveManifest.read(
            from: rig.archive.appendingPathComponent(ArchiveLayout.manifestFilename))
        #expect(manifest.assets.count == 2)
        #expect(manifest.assets.filter { $0.archivedAt != nil }.count == 1)

        let summary = await rig.importIntoTarget()
        #expect(summary.outcome == .succeeded)
        // 2, not 1: the shelved item was exported rather than silently skipped.
        #expect(summary.newAssets == 2)
        #expect(try await rig.targetArchived("Refs") == ["Shelved": true, "Plain": false])
        // …and it lands hidden from browsing, where an archived item belongs.
        #expect(try await rig.targetItems("Refs").map { $0.source.title } == ["Plain"])
    }

    /// An archived multi-collection asset arrives as ONE shelved asset, not as a
    /// shelf state that only stuck in the first folder the importer visited.
    @Test("An archived multi-collection asset survives in every collection")
    func archivedSurvivesMultiCollection() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let alpha = try await rig.source.createCollection(name: "Alpha")
        let beta = try await rig.source.createCollection(name: "Beta")
        let asset = try await rig.seedImage(bytes: "shared", into: alpha.id, archived: true)
        try await rig.source.addAssets([asset.id], to: beta.id)

        try await rig.export()
        #expect(await rig.importIntoTarget().outcome == .succeeded)

        for name in ["Alpha", "Beta"] {
            #expect(try await rig.targetArchived(name) == ["Hero": true])
            #expect(try await rig.targetItems(name).isEmpty)
        }
    }

    /// Rule 3 of the replay layer, for the shelf: applying it is ADDITIVE, so a
    /// second import onto a deduplicated asset must not pull an item off a shelf
    /// the user put it on HERE. An archive saying "not archived" is the absence
    /// of a claim, not an instruction.
    @Test("Re-importing a non-archived archive never unarchives what is here")
    func importNeverUnarchives() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let refs = try await rig.source.createCollection(name: "Refs")
        try await rig.seedImage(
            bytes: "later-shelved", into: refs.id, title: "Later",
            url: "https://example.com/later")

        try await rig.export()
        #expect(await rig.importIntoTarget().outcome == .succeeded)

        // Archive it HERE, in the destination library — an edit the archive
        // knows nothing about.
        let landed = try #require(try await rig.targetItems("Refs").first)
        try await rig.target.archive([landed.asset.id])

        // Import the same (un-archived) archive again: it dedups onto that asset.
        let second = await rig.importIntoTarget()
        #expect(second.newAssets == 0)
        #expect(try await rig.targetArchived("Refs") == ["Later": true])
    }

    /// A multi-collection favorite arrives as ONE starred asset, not as a star that
    /// only stuck in the first folder the importer happened to visit.
    @Test("A favorite on a multi-collection asset survives in every collection")
    func favoriteSurvivesMultiCollection() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let alpha = try await rig.source.createCollection(name: "Alpha")
        let beta = try await rig.source.createCollection(name: "Beta")
        let asset = try await rig.seedImage(bytes: "shared", into: alpha.id, favorite: true)
        try await rig.source.addAssets([asset.id], to: beta.id)

        try await rig.export()
        #expect(await rig.importIntoTarget().outcome == .succeeded)

        for name in ["Alpha", "Beta"] {
            let items = try await rig.targetItems(name)
            #expect(items.count == 1)
            #expect(items.first?.asset.isFavorite == true)
        }
    }

    /// Rule 3 of the replay layer, for the star: applying it is ADDITIVE, so a
    /// second import onto a deduplicated asset must not clear a star the user set
    /// in this library, and an archive that says "not a favorite" must not unstar
    /// anything. (Contrast `name` / `note`, which are new-assets-only.)
    @Test("Re-importing an unstarred archive never unstars what is here")
    func importNeverUnstars() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let refs = try await rig.source.createCollection(name: "Refs")
        try await rig.seedImage(
            bytes: "later-starred", into: refs.id, title: "Later",
            url: "https://example.com/later")

        try await rig.export()
        #expect(await rig.importIntoTarget().outcome == .succeeded)

        // Star it HERE, in the destination library — an edit the archive knows
        // nothing about.
        let landed = try #require(try await rig.targetItems("Refs").first)
        #expect(landed.asset.isFavorite == false)
        try await rig.target.setFavorite(true, for: landed.asset.id)

        // Import the same (unstarred) archive again: it dedups onto that asset.
        let second = await rig.importIntoTarget()
        #expect(second.newAssets == 0)
        let after = try #require(try await rig.targetItems("Refs").first)
        #expect(after.asset.id == landed.asset.id)
        #expect(after.asset.isFavorite == true)
    }

    /// The archive's defining asymmetry, measured from the other end: the tree
    /// holds three copies, the library that reads it holds ONE asset.
    @Test("A multi-collection asset imports as N memberships and exactly 1 asset")
    func multiCollectionAsset() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let alpha = try await rig.source.createCollection(name: "Alpha")
        let beta = try await rig.source.createCollection(name: "Beta")
        let gamma = try await rig.source.createCollection(name: "Gamma")
        let asset = try await rig.seedImage(bytes: "shared", into: alpha.id)
        try await rig.source.addAssets([asset.id], to: beta.id)
        try await rig.source.addAssets([asset.id], to: gamma.id)

        try await rig.export()
        let summary = await rig.importIntoTarget()

        #expect(summary.assets == 1)
        #expect(summary.newAssets == 1)
        #expect(summary.memberships == 3)
        #expect(try await rig.assetCount(in: rig.target) == 1)

        // …and it is the SAME asset in all three, not three rows with equal bytes.
        var ids: Set<UUID> = []
        for name in ["Alpha", "Beta", "Gamma"] {
            let items = try await rig.targetItems(name)
            #expect(items.count == 1)
            ids.formUnion(items.map(\.asset.id))
        }
        #expect(ids.count == 1)
    }

    /// Import idempotency is a property of the MANIFEST, not of the pipeline:
    /// 18A dedup reuses an asset only when the incoming provenance matches, so
    /// this passes only because the archive carries provenance verbatim.
    @Test("Importing the same archive twice does not double the assets")
    func importTwice() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let design = try await rig.source.createCollection(name: "Design")
        try await rig.seedImage(bytes: "one", into: design.id, url: "https://example.com/1")
        try await rig.seedImage(bytes: "two", into: design.id, url: "https://example.com/2")
        // A local capture, whose dedup matches on PLATFORM rather than URL.
        try await rig.seedImage(
            bytes: "three", into: design.id, url: nil, platform: .localDrag)

        try await rig.export()
        let first = await rig.importIntoTarget()
        let second = await rig.importIntoTarget()

        #expect(first.outcome == .succeeded)
        #expect(second.outcome == .succeeded)
        #expect(first.newAssets == 3)
        // Every asset the second run touched was already here.
        #expect(second.assets == 3)
        #expect(second.newAssets == 0)
        #expect(try await rig.assetCount(in: rig.target) == 3)

        // Two destinations, not one clobbered: the second import is its own
        // container, disambiguated Finder-style.
        let collections = try await rig.targetCollections()
        #expect(collections["Studio Archive"] != nil)
        #expect(collections["Studio Archive 2"] != nil)
        #expect(second.destinationName == "Studio Archive 2")
    }

    /// A library with only media-less kinds still round-trips: the substance
    /// rides in the manifest's payload, and there is nothing to copy.
    @Test("Colors, links and tweets round-trip through the payload")
    func mediaLessRoundTrip() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let ideas = try await rig.source.createCollection(name: "Ideas")
        let provenance = SourceDraft(
            platform: .localDrag, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await rig.source.ingestContent(
            .color(hex: "#FF0055"), from: provenance, into: ideas.id)
        try await rig.source.ingestContent(
            .link(url: "https://example.com/read", title: "Read me"),
            from: SourceDraft(platform: .web, capturedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            into: ideas.id)

        try await rig.export()
        let summary = await rig.importIntoTarget()

        #expect(summary.outcome == .succeeded)
        #expect(summary.assets == 2)
        let items = try await rig.targetItems("Ideas")
        #expect(Set(items.map(\.asset.kind)) == [.color, .link])
        let color = try #require(items.first { $0.asset.kind == .color })
        #expect(AssetPayload(jsonString: color.asset.payload)?.color?.hex == "#ff0055")
        // The funnel derives these, so they come back canonical rather than copied.
        #expect(color.asset.dedupKey == "#ff0055")

        // …and a second import dedups on `(kind, dedup_key)` + provenance.
        let again = await rig.importIntoTarget()
        #expect(again.newAssets == 0)
        #expect(try await rig.assetCount(in: rig.target) == 2)
    }

    /// The rule H6 flagged, end to end: two collections whose copies were
    /// written to ONE folder still come back as two folders under their own
    /// parents, because the importer reads `parent_collection_id`.
    @Test("Nesting survives two collections sharing one path")
    func sharedPathKeepsNesting() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let alpha = try await rig.source.createCollection(name: "Alpha")
        let beta = try await rig.source.createCollection(name: "Beta")
        _ = try await rig.source.createCollection(name: "Refs", parent: alpha.id)
        _ = try await rig.source.createCollection(name: "Refs", parent: beta.id)

        try await rig.export()
        // Force the collision the path budget produces on a pathologically deep
        // tree, without needing a 768-byte name to do it.
        try rig.editManifest { manifest in
            for index in manifest.collections.indices where manifest.collections[index].name == "Refs" {
                manifest.collections[index].path = "Collections/Refs"
            }
        }
        let summary = await rig.importIntoTarget()
        #expect(summary.outcome == .succeeded)

        let all = try await rig.target.listCollections()
        let alphaCopy = try #require(all.first { $0.name == "Alpha" })
        let betaCopy = try #require(all.first { $0.name == "Beta" })
        let refs = all.filter { $0.name == "Refs" }
        #expect(refs.count == 2)
        #expect(Set(refs.compactMap(\.parentCollectionID)) == [alphaCopy.id, betaCopy.id])
    }

    /// One missing image must not cost a user the rest of their library — and
    /// the run must not call itself a success.
    @Test("A blob the archive lost is a skip, and the outcome says so")
    func missingBlobIsIncomplete() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let design = try await rig.source.createCollection(name: "Design")
        try await rig.seedImage(bytes: "kept", into: design.id, title: "Kept")
        try await rig.seedImage(bytes: "lost", into: design.id, title: "Lost")

        try await rig.export()
        let manifest = try ArchiveManifest.read(
            from: rig.archive.appendingPathComponent(ArchiveLayout.manifestFilename))
        let lostHash = ContentHasher.hash(Data("lost".utf8))
        let lost = try #require(manifest.assets.first { $0.blobHash == lostHash })
        let file = try #require(
            manifest.collections.flatMap(\.items).first { $0.assetID == lost.id }?.file)
        try FileManager.default.removeItem(at: rig.archive.appendingPathComponent(file))

        let summary = await rig.importIntoTarget()
        #expect(summary.outcome == .incomplete)
        #expect(summary.skipped == 1)
        #expect(summary.assets == 1)
        #expect(try await rig.targetItems("Design").map { $0.source.title } == ["Kept"])
    }
}

// MARK: - The controller

@MainActor
@Suite("ArchiveImportController: refusing, stopping, reporting (008 H7)")
struct ArchiveImportControllerTests {

    /// Cancelling tears down in-flight work, and those throws are a CONSEQUENCE
    /// of the user pressing Stop. Reporting them as a failure is the bug the
    /// flag-before-error ordering exists to prevent (008 · H5b/H5c/H6).
    @Test("A stopped import is cancelled, never failed, and keeps what it wrote")
    func cancelIsNotFailure() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        for name in ["One", "Two", "Three", "Four"] {
            let collection = try await rig.source.createCollection(name: name)
            try await rig.seedImage(bytes: "b-\(name)", into: collection.id, title: name)
        }

        try await rig.export()
        let flag = CancelFlag()
        let summary = await rig.importIntoTarget(flag: flag, onProgress: { _ in
            // Stop as soon as the first collection is done.
            flag.cancel()
        })

        #expect(summary.outcome == .cancelled)
        #expect(summary.message == nil)

        // Consistent, not broken: every row went in through the funnel, so what
        // landed is a smaller library rather than a damaged one.
        let collections = try await rig.target.listCollections()
        #expect(collections.contains { $0.name == "Studio Archive" })
        // Whole would be 7: this library's Unsorted, the destination, the
        // archive's Unsorted, and One…Four.
        #expect(collections.count < 7)
        #expect(collections.count >= 2)
        for collection in collections {
            for detail in try await rig.target.collectionItems(in: collection.id, sort: .manual, includeArchived: false) {
                #expect(detail.asset.sourceId == detail.source.id)
                let hash = try #require(detail.asset.blobHash)
                #expect(rig.targetStore.hasBlob(hash: hash, fileExtension: "png"))
            }
        }
    }

    /// A refusal must cost NOTHING: no snapshot, no destination collection, no
    /// partially applied contract.
    @Test("A too-new archive is refused before the snapshot is even taken")
    func refusalCostsNothing() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }
        let design = try await rig.source.createCollection(name: "Design")
        try await rig.seedImage(bytes: "one", into: design.id)
        try await rig.export()
        try rig.editManifest { $0.manifestVersion = ArchiveManifest.currentVersion + 1 }

        let snapshots = Counter()
        let summary = await rig.importIntoTarget(snapshot: { await snapshots.bump() })

        #expect(summary.outcome == .refused)
        #expect(summary.message?.contains("newer version of AtelierRefs") == true)
        #expect(await snapshots.value == 0)
        #expect(try await rig.target.listCollections().count == 1)   // just Unsorted
    }

    /// The net goes in after the archive proves readable and before the first
    /// row is written — an ordering worth pinning, because getting it wrong is
    /// invisible until the day it matters.
    @Test("The pre-destructive snapshot runs before anything is created")
    func snapshotRunsBeforeTheFirstWrite() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }
        let design = try await rig.source.createCollection(name: "Design")
        try await rig.seedImage(bytes: "one", into: design.id)
        try await rig.export()

        let target = rig.target
        let observed = Counter()
        let summary = await rig.importIntoTarget(snapshot: {
            let count = (try? await target.listCollections().count) ?? -1
            await observed.set(count)
        })

        #expect(summary.outcome == .succeeded)
        // Only the destination library's own Unsorted existed at that moment.
        #expect(await observed.value == 1)
    }

    @Test("A folder with no manifest fails with a sentence about manifest.json")
    func missingManifestFails() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }
        try FileManager.default.createDirectory(
            at: rig.archive, withIntermediateDirectories: true)

        let summary = await rig.importIntoTarget()
        #expect(summary.outcome == .failed)
        #expect(summary.message == ArchiveImportCopy.message(for: .missingManifest))
        #expect(try await rig.target.listCollections().count == 1)
    }

    @Test("A folder that can't be reached is reported as such, not as a crash")
    func unreachableFolder() async throws {
        let rig = try RoundTripRig.make()
        defer { rig.cleanup() }

        let summary = await ArchiveImportController.perform(
            services: rig.target, store: rig.targetStore,
            folder: FailingFolderAccess(error: .bookmarkUnresolvable),
            snapshot: {}, flag: CancelFlag(), onProgress: { _ in })

        #expect(summary.outcome == .failed)
        #expect(summary.message == ArchiveImportCopy.message(for: .bookmarkUnresolvable))
    }
}

// MARK: - Doubles

/// Counts (or records) calls from a `@Sendable` closure.
private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
    func set(_ newValue: Int) { value = newValue }
}

/// A ``FolderAccess`` that refuses — the sandbox failure a test process cannot
/// otherwise produce.
private struct FailingFolderAccess: FolderAccess {
    let error: FolderAccessError
    func resolve() throws -> URL { throw error }
    func beginAccess(to url: URL) throws {}
    func endAccess(to url: URL) {}
}
