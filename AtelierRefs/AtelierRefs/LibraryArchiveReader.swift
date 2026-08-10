//
//  LibraryArchiveReader.swift
//  AtelierRefs
//
//  008 · H7 — the archive-specific half of the importer: an archive folder read
//  into `[ImportPlan]`, and nothing else.
//
//  PURE, in the sense that matters: it opens files and it decodes JSON, but it
//  never touches the library, the blob store or the app. Handed a temp directory
//  it produces plans a test can compare field by field — which is why the
//  well-formed / missing-manifest / malformed / missing-file / stray-file matrix
//  is a set of fast unit tests rather than a set of end-to-end ones.
//
//  Three rules it exists to keep:
//
//  1. **Refuse before you read anything.** `ArchiveManifest.refusal` already
//     implements the version rule in H5c's shape ("newer than me" on both axes,
//     an unparseable version deliberately NOT a refusal). This file calls it and
//     does not re-derive it. A refusal throws, so no plan — and therefore no
//     write — can exist for a contract this build doesn't understand.
//  2. **Read `parent_collection_id`, never `path`.** A collection's `path` is
//     where its copies were written for a human to browse; the archive relocates
//     a folder that would overrun the path budget, so two unrelated collections
//     can legitimately share one. `parentID` is the structure (008 · H6).
//  3. **A membership that can't be replayed is a NAMED skip, never a silent
//     one.** Missing bytes, provenance the manifest didn't ship, an asset id
//     nothing declares — each comes out as an ``ImportSkip`` with a reason.
//

import AtelierCore
import Foundation

// MARK: - Refusals and failures

/// Why an archive could not be read AT ALL. Distinct from a per-item skip: these
/// stop the import before a single row is written.
nonisolated enum ArchiveReadError: Error, Equatable {
    /// No `manifest.json` at the root. The manifest is written LAST and
    /// atomically (008 · H6), so its absence means that export never finished —
    /// the same commit-record reasoning `BackupCatalog` applies to a backup.
    case missingManifest
    /// A `manifest.json` that is present but not decodable — truncated, edited,
    /// or not a manifest at all.
    case unreadableManifest
    /// The contract is newer than this build understands. Never partially
    /// applied.
    case refused(ArchiveRefusal)
}

// MARK: - What a parse produced

/// An archive read into plans, with everything the report needs to be honest.
nonisolated struct ArchiveParse: Sendable, Equatable {
    /// The name the destination collection should take — the archive folder's
    /// own name, so an import is findable by what the user chose in Finder.
    var name: String
    var manifestVersion: Int
    var schemaVersion: String
    var appVersion: String
    var exportedAt: Date
    /// One per collection in the manifest, in the manifest's order. The replay
    /// layer reorders parents-first; the parse leaves the contract's order
    /// alone so a plan list is directly comparable to the manifest.
    var plans: [ImportPlan]
    /// Memberships that cannot be replayed, each with a reason.
    var skipped: [ImportSkip]
    /// Archive-relative paths of regular files no membership refers to. Never a
    /// failure — an archive the user has added a README to is still a valid
    /// archive — but counted, because a folder full of unreferenced images is
    /// how a torn manifest would look from the outside.
    var unreferenced: [String]
}

// MARK: - The parse

nonisolated enum LibraryArchiveReader {

    /// The destination name for an archive whose folder name is unusable (a
    /// volume root, a name that is entirely whitespace). `createCollection`
    /// rejects an empty name, and failing an otherwise-good import on the
    /// destination's *label* would be absurd.
    static let fallbackName = "Imported Archive"

    /// Read the archive rooted at `root`.
    ///
    /// Throws ``ArchiveReadError`` and only that: everything survivable is a
    /// skip in the returned parse. Nothing here writes, so a throw leaves the
    /// library exactly as it was — which is what "never partially apply an
    /// unknown contract" means in practice.
    static func parse(
        _ root: URL, schemaVersion: String = AppServices.schemaVersion
    ) throws -> ArchiveParse {
        let manifestURL = root.appendingPathComponent(ArchiveLayout.manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveReadError.missingManifest
        }
        let manifest: ArchiveManifest
        do {
            manifest = try ArchiveManifest.read(from: manifestURL)
        } catch {
            throw ArchiveReadError.unreadableManifest
        }
        if let refusal = ArchiveManifest.refusal(for: manifest, schemaVersion: schemaVersion) {
            throw ArchiveReadError.refused(refusal)
        }

        // Last-wins on a duplicated id rather than a crash: `Dictionary(uniqueKeysWithValues:)`
        // traps, and a hand-edited manifest must not be able to kill the app.
        let sources = Dictionary(
            manifest.sources.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let assets = Dictionary(
            manifest.assets.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        var plans: [ImportPlan] = []
        var skipped: [ImportSkip] = []
        var referenced: Set<String> = [ArchiveLayout.manifestFilename]

        for entry in manifest.collections {
            var items: [ImportItem] = []
            for membership in entry.items {
                // Counted as referenced even when the item is skipped: the file
                // IS named by the manifest, so it is not a stray.
                if let file = membership.file { referenced.insert(file) }

                guard let asset = assets[membership.assetID] else {
                    skipped.append(ImportSkip(
                        collection: entry.name, item: membership.assetID.uuidString,
                        reason: .unknownAsset))
                    continue
                }
                guard let source = sources[asset.sourceID] else {
                    skipped.append(ImportSkip(
                        collection: entry.name, item: asset.id.uuidString,
                        reason: .unknownSource))
                    continue
                }
                switch body(for: asset, membership: membership, root: root) {
                case let .success(body):
                    items.append(ImportItem(
                        key: asset.id.uuidString,
                        body: body,
                        source: draft(from: source),
                        tags: asset.tags.map { ImportTag(name: $0.name, source: $0.source) },
                        name: asset.name,
                        note: asset.note,
                        isFavorite: asset.isFavorite,
                        isArchived: asset.archivedAt != nil,
                        placement: CanvasPlacement(
                            x: membership.canvasX, y: membership.canvasY,
                            w: membership.canvasW, h: membership.canvasH,
                            z: membership.canvasZ)))
                case let .failure(reason):
                    skipped.append(ImportSkip(
                        collection: entry.name, item: asset.id.uuidString, reason: reason))
                }
            }
            plans.append(ImportPlan(
                key: entry.id.uuidString,
                // The STRUCTURE, from the id. `entry.path` is presentation and
                // can repeat (see the file header, rule 2).
                parentKey: entry.parentID?.uuidString,
                name: entry.name,
                description: entry.description,
                items: items))
        }

        return ArchiveParse(
            name: destinationName(for: root),
            manifestVersion: manifest.manifestVersion,
            schemaVersion: manifest.schemaVersion,
            appVersion: manifest.appVersion,
            exportedAt: manifest.exportedAt,
            plans: plans,
            skipped: skipped,
            unreferenced: unreferencedFiles(in: root, referenced: referenced))
    }

    // MARK: - One membership's substance

    private enum Body {
        case success(ImportBody)
        case failure(ImportSkipReason)
    }

    /// Where this membership's substance is — a file in the tree for a
    /// byte-backed kind, the manifest's `payload` for a media-less one.
    ///
    /// A `tweet` / `link` / `color` may ALSO have bytes (the card image, 003 ·
    /// C3): they ride along when the file is there and are simply absent when it
    /// isn't, because a tweet without its picture is still the tweet. A missing
    /// file for an `image` is a skip — that asset has nothing left.
    private static func body(
        for asset: ArchiveManifest.AssetEntry,
        membership: ArchiveManifest.MembershipEntry,
        root: URL
    ) -> Body {
        let bytes = self.bytes(for: asset, membership: membership, root: root)

        switch asset.kind {
        case .image, .video:
            guard let hash = asset.blobHash, !hash.isEmpty else { return .failure(.unusable) }
            guard let bytes else { return .failure(.missingFile) }
            // The funnel requires positive dimensions; an entry without them is
            // not something any public writer can be handed.
            guard bytes.width > 0, bytes.height > 0 else { return .failure(.unusable) }
            return .success(.media(
                kind: asset.kind, bytes: bytes, downloadState: asset.downloadState))

        case .color, .link, .tweet:
            guard let payload = AssetPayload(jsonString: asset.payload) else {
                return .failure(.unusable)
            }
            // `dedupKey` / `searchText` are deliberately NOT carried across: the
            // funnel derives the canonical pair per kind, so replaying the
            // archive's copy could only ever disagree with it.
            return .success(.content(
                AssetContentDraft(kind: asset.kind, payload: payload), card: bytes))
        }
    }

    /// The file this membership points at, when it is really there.
    private static func bytes(
        for asset: ArchiveManifest.AssetEntry,
        membership: ArchiveManifest.MembershipEntry,
        root: URL
    ) -> ImportBytes? {
        guard let hash = asset.blobHash, !hash.isEmpty,
              let file = membership.file, !file.isEmpty else { return nil }
        let url = file
            .split(separator: "/")
            .reduce(root) { $0.appendingPathComponent(String($1)) }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ImportBytes(
            url: url, mimeType: asset.mimeType ?? "",
            width: asset.width ?? 0, height: asset.height ?? 0,
            duration: asset.duration)
    }

    /// Provenance, field for field. Verbatim is the round-trip's correctness:
    /// 18A dedup matches on `original_url` when one exists and on `platform`
    /// otherwise, so a field normalized here forks a second asset over the same
    /// bytes when the archive is imported twice.
    private static func draft(from source: ArchiveManifest.SourceEntry) -> SourceDraft {
        SourceDraft(
            platform: source.platform,
            originalURL: source.originalURL,
            authorHandle: source.authorHandle,
            authorName: source.authorName,
            title: source.title,
            capturedAt: source.capturedAt,
            rawMetadata: source.rawMetadata)
    }

    // MARK: - The folder

    /// The destination collection's name: the archive folder's own.
    static func destinationName(for root: URL) -> String {
        let name = root.standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? fallbackName : name
    }

    /// Regular files under `root` that no membership named, archive-relative and
    /// sorted. Hidden files are skipped: `.DS_Store` follows a user around
    /// Finder and reporting it as unexplained content would be noise.
    static func unreferencedFiles(in root: URL, referenced: Set<String>) -> [String] {
        let base = root.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in walk {
            let isRegular = (try? url.resourceValues(
                forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            let path = url.standardizedFileURL.path
            guard path.count > base.count + 1 else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if !referenced.contains(relative) { out.append(relative) }
        }
        return out.sorted()
    }
}
