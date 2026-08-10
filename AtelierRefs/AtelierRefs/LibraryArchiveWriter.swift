//
//  LibraryArchiveWriter.swift
//  AtelierRefs
//
//  008 · H6 — the engine that turns an open library into an archive folder.
//
//  Streaming by construction: the library is walked ONE COLLECTION AT A TIME
//  (`collectionItems(in:)` is already the collection-scoped read), and blob
//  bytes are moved with `FileManager.copyItem`, which streams. What is held in
//  memory is the manifest's metadata — a JSON document has to be complete before
//  it can be written — never the media.
//
//  Naming is `AssetExport`'s, unchanged: the same sanitizer, the same 60-char
//  cap, the same `<title-or-source>-<shorthash>.<ext>`, plus `ExportNameAllocator`
//  for the case-insensitive collision a folder full of names has and a single
//  drag-out never did. There is exactly one export naming rule in this app.
//
//  `nonisolated` and `Sendable` so the whole run happens off the main actor
//  (`ArchiveExportController` hops it out); nothing here touches AppKit, a
//  panel, or a bookmark.
//

import AtelierCore
import AtelierIngestion
import Foundation

/// Why a run produced nothing worth committing.
nonisolated enum ArchiveWriteError: Error, Equatable {
    /// Every byte-backed membership failed to copy — the destination is full or
    /// unwritable. No manifest is written, so the folder cannot be mistaken for
    /// a finished archive.
    case nothingCopied
}

nonisolated struct LibraryArchiveWriter: Sendable {

    /// What one export produced, for the toast / status line. Skips are counted
    /// and reported, never silently swallowed (004's batch-outcome lesson).
    struct Result: Sendable, Equatable {
        /// Collections written (every collection, including empty ones).
        var collections: Int = 0
        /// Distinct assets in the manifest — the CANONICAL count, not the file
        /// count, which is larger whenever an asset lives in several folders.
        var assets: Int = 0
        /// Files copied into the tree.
        var files: Int = 0
        /// Memberships whose bytes could not be written: a blob already gone
        /// from disk, or a copy the filesystem refused. The user-facing total.
        var skipped: Int = 0
        /// The subset of ``skipped`` the DESTINATION refused — a copy that threw,
        /// rather than a source blob that was already gone.
        ///
        /// Split out because the two causes look identical in a count and mean
        /// opposite things. A missing source blob is a fact about the library
        /// that no destination can fix, and archiving around it is correct. A
        /// refused copy is a fact about the destination — it is full, or
        /// read-only — and it is the one that must not be committed to as though
        /// it were a finished archive.
        var writeFailures: Int = 0
        /// Where the manifest landed.
        var manifestURL: URL
    }

    let services: AppServices
    let store: MediaStore
    let appVersion: String
    let schemaVersion: String

    init(
        services: AppServices,
        store: MediaStore,
        appVersion: String,
        schemaVersion: String = AppServices.schemaVersion
    ) {
        self.services = services
        self.store = store
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
    }

    // MARK: - The run

    /// Write the whole library into `root`, which is created if absent.
    ///
    /// `manifest.json` is written LAST and atomically, so a run that is
    /// cancelled or fails leaves a folder with no manifest — visibly incomplete
    /// rather than plausibly whole. Throws `CancellationError` the moment
    /// `isCancelled` trips; the caller classifies that, and must ask its own
    /// flag before it classifies anything (008 · H5b).
    func write(
        to root: URL,
        isCancelled: @Sendable () -> Bool,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> Result {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let plan = try await folderPlan()
        var result = Result(manifestURL: root.appendingPathComponent(ArchiveLayout.manifestFilename))

        // Canonical, deduplicated: an asset in five collections is copied five
        // times into the tree and recorded ONCE here.
        var sources: [UUID: ArchiveManifest.SourceEntry] = [:]
        var assets: [UUID: ArchiveManifest.AssetEntry] = [:]
        var collections: [ArchiveManifest.CollectionEntry] = []

        for (index, node) in plan.enumerated() {
            try check(isCancelled)
            let directory = url(root, node.components)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            // `includeArchived: true` — a backup is a copy of the library, not a
            // view of it (023 · A). Archiving is a browsing state, so an archive
            // that skipped the shelf would lose it silently on every restore.
            // The manifest carries `archivedAt`, so a restored item comes back
            // archived rather than reappearing in the middle of a collection.
            let details = try await services.collectionItems(
                in: node.collection.id, sort: .manual, includeArchived: true)

            // One allocator per DESTINATION FOLDER. Keying it by the resolved
            // directory rather than by the collection is what makes
            // `ArchiveLayout`'s relocation safe: if two collections ever land in
            // the same folder, their filenames still cannot collide.
            var names = ExportNameAllocator()
            // The same blob backing two rows in this folder keeps ONE name and
            // one copy rather than being disambiguated into two identical files.
            var byBlob: [String: String] = [:]
            var items: [ArchiveManifest.MembershipEntry] = []

            for (offset, detail) in details.enumerated() {
                try check(isCancelled)

                if assets[detail.asset.id] == nil {
                    let tags = try await services.tags(for: detail.asset.id)
                    assets[detail.asset.id] = ArchiveManifest.AssetEntry(detail.asset, tags: tags)
                    sources[detail.source.id] = ArchiveManifest.SourceEntry(detail.source)
                }

                let file = copy(
                    detail, into: directory, at: node.components,
                    names: &names, byBlob: &byBlob, result: &result)
                items.append(ArchiveManifest.MembershipEntry(detail.item, file: file))

                onProgress(Self.fraction(
                    collection: index, of: plan.count,
                    item: offset + 1, of: details.count))
            }

            collections.append(ArchiveManifest.CollectionEntry(
                node.collection,
                path: ArchiveLayout.relativePath(node.components),
                items: items))
            result.collections += 1
            onProgress(Self.fraction(collection: index + 1, of: plan.count, item: 0, of: 0))
        }

        try check(isCancelled)

        // A run the DESTINATION refused outright is a failed run, not an
        // incomplete one. A folder that is full or read-only makes every
        // `copyItem` throw in turn, and writing the manifest anyway would leave
        // something that reads as a finished archive — the manifest is the commit
        // record — over no media at all, which re-imports as a missing file per
        // membership.
        //
        // The condition is "the destination refused every copy", and each half of
        // that matters. Judging by `skipped` instead would fail a library whose
        // one asset had its blob reaped — a fact about the SOURCE, which the
        // archive is supposed to record and move past. Judging by `files == 0`
        // alone would fail a library made entirely of media-less kinds
        // (`link` / `tweet` / `color`), which legitimately copies nothing. A
        // PARTIAL write failure still commits: `.incomplete` names the count, and
        // a half-copied archive the user can see is worth more than none.
        guard result.writeFailures == 0 || result.files > 0 else {
            throw ArchiveWriteError.nothingCopied
        }

        let manifest = ArchiveManifest(
            schemaVersion: schemaVersion,
            appVersion: appVersion,
            exportedAt: Date(),
            sources: sources.values.sorted { $0.id.uuidString < $1.id.uuidString },
            assets: assets.values.sorted { $0.id.uuidString < $1.id.uuidString },
            collections: collections)
        try manifest.write(to: result.manifestURL)

        result.assets = assets.count
        onProgress(1)
        return result
    }

    // MARK: - Folder plan

    /// One collection's place in the archive's folder tree.
    struct Node: Equatable {
        var collection: Collection
        /// Archive-relative directory components, `Collections` first.
        var components: [String]
    }

    /// Resolve every collection to a folder, depth-first, parents before
    /// children — the order the tree is written in and the order the manifest
    /// lists them in, so a re-export of an unchanged library is byte-identical.
    ///
    /// Sibling order is the persisted `sort_index`, tie-broken by `(name, id)`,
    /// matching Core's own canonical child order. Names are `AssetExport`'s
    /// sanitizer plus a per-parent `ExportNameAllocator`, because sanitizing can
    /// make distinct sibling names identical (`Refs / Q3` and `Refs   Q3`) even
    /// though Core guarantees the originals differ.
    func folderPlan() async throws -> [Node] {
        let all = try await services.listCollections()
        var childrenByParent: [UUID?: [Collection]] = [:]
        for collection in all {
            childrenByParent[collection.parentCollectionID, default: []].append(collection)
        }
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort {
                ($0.sortIndex, $0.name, $0.id.uuidString)
                    < ($1.sortIndex, $1.name, $1.id.uuidString)
            }
        }

        var plan: [Node] = []
        var allocators: [String: ExportNameAllocator] = [:]
        // A parent cycle cannot be created through `moveCollection`, but a walk
        // that trusted that would hang instead of failing if one ever existed.
        var visited: Set<UUID> = []

        func walk(_ parentID: UUID?, under parent: [String]) {
            for collection in childrenByParent[parentID] ?? [] {
                guard visited.insert(collection.id).inserted else { continue }
                let placement = ArchiveLayout.placement(
                    parent: parent,
                    name: Self.folderName(for: collection.name),
                    collectionID: collection.id)
                let key = ArchiveLayout.relativePath(placement.parent)
                var allocator = allocators[key] ?? ExportNameAllocator()
                let name = allocator.claim(placement.name)
                allocators[key] = allocator
                let components = placement.parent + [name]
                plan.append(Node(collection: collection, components: components))
                walk(collection.id, under: components)
            }
        }
        walk(nil, under: [ArchiveLayout.collectionsDirectory])
        return plan
    }

    /// A collection's folder name: the shared sanitizer, with `"Refs"` — not
    /// `sanitize`'s `"image"` — for a name nothing survives. The fallback word is
    /// right for one file and wrong for a folder of many
    /// (`CollectionSiteExport.folderName` settled the same point).
    ///
    /// The test for "nothing survives" is the INPUT, not `sanitize`'s output: a
    /// collection genuinely called `image` must keep its name, and a collection
    /// called `///` must not become one.
    static func folderName(for name: String) -> String {
        let survivable = CharacterSet(charactersIn: "/\\:\u{0} .-")
            .union(.controlCharacters).union(.whitespacesAndNewlines).inverted
        guard name.rangeOfCharacter(from: survivable) != nil else { return "Refs" }
        return AssetExport.sanitize(name)
    }

    // MARK: - Copying

    /// Copy one membership's bytes into `directory`, returning the
    /// archive-relative path recorded in the manifest, or `nil` when there was
    /// nothing to copy.
    ///
    /// A media-less kind (`link` / `tweet` / `color`) has no file and is NOT a
    /// skip — its substance rides in the manifest's `payload`, so the archive is
    /// complete without bytes. A byte-backed asset whose blob is gone from disk
    /// IS a skip: something the archive was meant to carry isn't there.
    private func copy(
        _ detail: CollectionItemDetail,
        into directory: URL,
        at components: [String],
        names: inout ExportNameAllocator,
        byBlob: inout [String: String],
        result: inout Result
    ) -> String? {
        guard let hash = detail.asset.blobHash, !hash.isEmpty else { return nil }
        let source = store.blobURL(
            hash: hash,
            fileExtension: ImageMetadata.fileExtension(forMIMEType: detail.asset.mimeType ?? ""))
        guard let item = AssetExport.exportItem(
            asset: detail.asset, source: detail.source, blobURL: source) else {
            result.skipped += 1
            return nil
        }

        if let already = byBlob[item.blobURL.path] {
            return ArchiveLayout.relativePath(components + [already])
        }

        let name = names.claim(item.filename)
        let destination = directory.appendingPathComponent(name)
        do {
            // Replace rather than fail: re-exporting over an existing archive
            // folder must refresh it, not error on the first file it recognises.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item.blobURL, to: destination)
        } catch {
            result.skipped += 1
            result.writeFailures += 1
            return nil
        }
        byBlob[item.blobURL.path] = name
        result.files += 1
        return ArchiveLayout.relativePath(components + [name])
    }

    // MARK: - Helpers

    /// Progress across the whole run: whole collections done, plus how far into
    /// the current one. Denominated in COLLECTIONS rather than in memberships
    /// because a total membership count would need a full pre-pass over the
    /// library — the one thing a streaming writer must not do.
    static func fraction(collection: Int, of collections: Int, item: Int, of items: Int) -> Double {
        guard collections > 0 else { return 1 }
        let within = items > 0 ? Double(item) / Double(items) : 0
        return min(1, (Double(collection) + within) / Double(collections))
    }

    private func url(_ root: URL, _ components: [String]) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private func check(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
