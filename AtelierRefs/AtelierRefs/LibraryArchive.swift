//
//  LibraryArchive.swift
//  AtelierRefs
//
//  008 · H6 — the portability archive's CONTRACT.
//
//  An archive is a folder tree a human can browse, plus ONE machine-readable
//  file that is the whole graph:
//
//      <archive>/manifest.json
//      <archive>/Collections/<collection path…>/<title-or-source>-<shorthash>.<ext>
//
//  The tree is for people; `manifest.json` is for the importer (008 · H7). They
//  are deliberately NOT symmetric — a multi-collection asset is copied into each
//  folder it belongs to (browsability is the archive's whole point), while the
//  manifest records that asset exactly ONCE with N memberships, so re-import
//  yields one asset rather than N duplicates.
//
//  Three rules this file exists to keep honest:
//
//  1. **Provenance is copied verbatim.** `AppServices.ingest`'s 18A dedup reuses
//     an existing asset sharing a blob hash only when its source matches the
//     incoming provenance — same `original_url` when one is given, else same
//     `platform`. A field this file drops or normalizes therefore forks a second
//     asset over the same bytes on re-import. Import idempotency is a property
//     of the MANIFEST, not just of the pipeline.
//  2. **Derived data is excluded.** `asset_analysis` (OCR / colors / phash) and
//     `asset_embedding` are recomputable by definition, and writing them here
//     would freeze an `analyzer_version` into a portability contract.
//  3. **Two version axes, one refusal rule** — "newer than me", mirroring
//     `RestoreRunner.refusal` (008 · H5c). An UNPARSEABLE version is not a
//     refusal: "I can't tell" is not evidence of "newer".
//
//  Everything here is pure and AppKit-free, so the contract is golden-file
//  testable without a library, a panel or a sandbox.
//

import AtelierCore
import Foundation

// MARK: - Layout

/// Where things go inside an archive folder, and the one rule that keeps a
/// deeply-nested collection tree from producing a path the filesystem refuses.
nonisolated enum ArchiveLayout {

    /// The manifest's filename at the archive root.
    static let manifestFilename = "manifest.json"

    /// The single top-level directory the browsable tree lives under. One
    /// directory rather than collections at the root, so the manifest always has
    /// an unambiguous neighbour and a future `Spaces/` sibling is additive.
    static let collectionsDirectory = "Collections"

    /// Byte budget for an archive-RELATIVE path (`Collections/a/b/hero-ab12.png`).
    ///
    /// macOS caps a full path at `PATH_MAX` (1024 bytes). The archive root is
    /// chosen by the user and can be arbitrarily long, so the budget here is the
    /// relative part only, leaving ~256 bytes of room for the root.
    static let maxRelativeBytes = 768

    /// Room reserved inside ``maxRelativeBytes`` for the filename a directory
    /// will hold. `AssetExport.sanitize` caps a base at 60 CHARACTERS, which is
    /// up to 240 UTF-8 bytes of emoji, plus `-<8 hex>` and an extension.
    static let filenameReserve = 256

    /// Whether a directory built from `components` still leaves room for the
    /// longest filename the naming layer can produce.
    static func fits(_ components: [String]) -> Bool {
        relativePath(components).utf8.count + filenameReserve <= maxRelativeBytes
    }

    /// Join path components the way the manifest spells them: `/`-separated and
    /// archive-relative, never an absolute URL. The manifest travels with the
    /// folder, so an absolute path in it would be wrong the moment the archive
    /// is copied anywhere.
    static func relativePath(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    /// Where a collection's folder goes: normally beside its siblings under
    /// `parent`, but RELOCATED to the top of `Collections/` when nesting it
    /// there would blow the path budget.
    ///
    /// The relocation is safe because the folder tree is a PRESENTATION of the
    /// graph, not the graph: `manifest.json` records every collection's real
    /// `parent_collection_id`, so an importer reconstructs the true nesting
    /// regardless of where the bytes were browsable. Losing depth is a cosmetic
    /// cost; a path the filesystem refuses to create is a failed export.
    ///
    /// A relocated folder keeps the collection's name plus the first 8
    /// characters of its id, so two deep folders that happen to share a name
    /// cannot silently become one. The caller still runs the returned name
    /// through the destination's ``ExportNameAllocator``, which is what makes
    /// the result unique even against that suffix repeating.
    ///
    /// Relocation is per-collection and therefore CASCADES gently: a relocated
    /// folder sits at depth 1, so its own children nest under it again until
    /// they in turn run out of budget. A pathologically deep tree comes out as
    /// several shallow trees rather than one flat pile — which is both the more
    /// browsable outcome and the one that needs no extra rule.
    static func placement(
        parent: [String], name: String, collectionID: UUID
    ) -> (parent: [String], name: String) {
        let nested = parent + [name]
        if fits(nested) { return (parent, name) }
        let short = String(collectionID.uuidString.prefix(8)).lowercased()
        return ([collectionsDirectory], "\(name)-\(short)")
    }
}

// MARK: - Refusal

/// Why this build must not read an archive.
///
/// Two cases, because they are two different things to tell a user: one is "this
/// archive was written by a newer AtelierRefs", the other is "its library schema
/// is ahead of mine". Both are refusals BEFORE anything is applied — never a
/// partial application of an unknown contract.
nonisolated enum ArchiveRefusal: Error, Equatable {
    /// `manifest_version` is newer than ``ArchiveManifest/currentVersion``.
    case manifestTooNew(Int)
    /// `schema_version` is newer than this build migrates to.
    case schemaTooNew(String)
}

// MARK: - The manifest

/// `manifest.json` — the whole graph an archive carries.
///
/// Ordering is fixed so a re-export of an unchanged library produces a
/// byte-identical file: `sources` and `assets` by id, `collections` in the same
/// depth-first order the folders were written in, memberships in manual order.
///
/// **Timestamps are whole seconds.** The wire format is ISO-8601 without
/// fractional seconds — chosen so a human opening the file can read it — and
/// every date is truncated on the way IN as well, so the in-memory manifest and
/// the on-disk one are the same value. (The same reasoning, and the same
/// encoder, as `BackupManifest`.)
nonisolated struct ArchiveManifest: Codable, Equatable, Sendable {

    /// The manifest shape this build writes.
    ///
    /// **Still 1 after favorites (011 · U5), deliberately.** `manifest_version`
    /// answers one question — "would a reader that does not know this shape
    /// MISREAD the file?" — and the answer for `is_favorite` is no: it is a new
    /// optional key, `JSONDecoder` ignores keys it has no property for, and every
    /// field a v1 reader does read still means exactly what it meant. Bumping for
    /// an additive field would spend the one signal we have for a genuinely
    /// incompatible change (a field removed, renamed, or re-meaninged) on a change
    /// that isn't one, and would make every future additive field look like a
    /// break.
    ///
    /// The "an older build must not mis-read a newer archive" guarantee is carried
    /// by the OTHER axis, and carried more precisely: favorites is a schema change,
    /// so an archive written with it records `schema_version = "v19"`, and
    /// ``refusal(for:schemaVersion:)`` returns ``ArchiveRefusal/schemaTooNew(_:)``
    /// for any build that only migrates to v18. That build refuses the archive
    /// whole — it never gets as far as silently dropping a star. In the other
    /// direction a v18-era archive decodes here with `is_favorite` absent, which
    /// ``AssetEntry/init(from:)`` reads as `false` — the truth, since the flag did
    /// not exist when it was written.
    static let currentVersion = 1

    /// The shape of this file. A reader that does not recognise the number must
    /// refuse rather than guess.
    var manifestVersion: Int

    /// The database migration identifier the export was written from ("v18").
    var schemaVersion: String

    /// The app build that wrote it — diagnostic only; nothing branches on it.
    var appVersion: String

    /// When the export finished.
    var exportedAt: Date

    /// Every source referenced by an asset below, by id. Provenance is verbatim
    /// (see the file header, rule 1).
    var sources: [SourceEntry]

    /// Every asset, ONCE, regardless of how many collections hold it.
    var assets: [AssetEntry]

    /// Every collection, depth-first, each carrying its memberships.
    var collections: [CollectionEntry]

    init(
        manifestVersion: Int = ArchiveManifest.currentVersion,
        schemaVersion: String,
        appVersion: String,
        exportedAt: Date,
        sources: [SourceEntry],
        assets: [AssetEntry],
        collections: [CollectionEntry]
    ) {
        self.manifestVersion = manifestVersion
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.exportedAt = Self.wire(exportedAt)
        self.sources = sources
        self.assets = assets
        self.collections = collections
    }

    /// snake_case on disk. Spelled out rather than left to a key-encoding
    /// strategy so the wire names are visible at the type and cannot drift when
    /// a property is renamed — this file is a contract with future readers.
    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case exportedAt = "exported_at"
        case sources, assets, collections
    }

    /// Truncate to whole seconds — the precision the wire format carries.
    static func wire(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: Entries

    /// One ``Source`` — the provenance an importer must replay verbatim.
    struct SourceEntry: Codable, Equatable, Sendable {
        var id: UUID
        var platform: Platform
        var originalURL: String?
        var authorHandle: String?
        var authorName: String?
        var title: String?
        var capturedAt: Date
        /// Platform extras, preserved exactly as captured — the escape hatch a
        /// round-trip must not quietly drop.
        var rawMetadata: JSONValue

        init(_ source: Source) {
            self.id = source.id
            self.platform = source.platform
            self.originalURL = source.originalURL
            self.authorHandle = source.authorHandle
            self.authorName = source.authorName
            self.title = source.title
            self.capturedAt = ArchiveManifest.wire(source.capturedAt)
            self.rawMetadata = source.rawMetadata
        }

        enum CodingKeys: String, CodingKey {
            case id, platform, title
            case originalURL = "original_url"
            case authorHandle = "author_handle"
            case authorName = "author_name"
            case capturedAt = "captured_at"
            case rawMetadata = "raw_metadata"
        }
    }

    /// A tag as the archive carries it: `(name, source)`, which is exactly what
    /// `AppServices.applyTag(_:to:source:)` finds-or-creates.
    ///
    /// No tag id — an importer mints its own, so exporting ours would be data an
    /// importer must ignore. A tag attached to NO asset is likewise not carried:
    /// there is no public writer that could recreate one, and everything in this
    /// contract is replayable through the shipped funnel.
    struct TagEntry: Codable, Equatable, Sendable {
        var name: String
        var source: TagSource

        init(_ tag: Tag) {
            self.name = tag.name
            self.source = tag.source
        }
    }

    /// One ``Asset``, canonical: written once no matter how many collections
    /// hold it.
    ///
    /// Byte columns are optional because the media-less kinds (`tweet` / `link`
    /// / `color`) carry their substance in `payload` instead — copied verbatim
    /// as the stored JSON TEXT, alongside the `dedup_key` that makes those kinds
    /// dedup on re-import.
    struct AssetEntry: Codable, Equatable, Sendable {
        var id: UUID
        var sourceID: UUID
        var kind: AssetKind
        var blobHash: String?
        var mimeType: String?
        var width: Int?
        var height: Int?
        var duration: Double?
        var fileSize: Int?
        var downloadState: DownloadState
        var createdAt: Date
        var name: String?
        var note: String?
        /// The star (011 · U5). Carried because it is user intent, not derived
        /// data — nothing can recompute which items someone chose to favorite, so
        /// an archive that dropped it would lose them silently on the first
        /// export after the flag shipped. Written unconditionally (`false`
        /// included) rather than as an omit-when-nil optional, so a reader can
        /// tell "written by a build that knows favorites, and this one isn't one"
        /// from "written before the flag existed" if it ever needs to.
        var isFavorite: Bool
        var viewCount: Int
        var lastViewedAt: Date?
        var payload: String?
        var dedupKey: String?
        var searchText: String?
        /// This asset's tags, in the stable `(name, id)` order Core returns.
        var tags: [TagEntry]

        init(_ asset: Asset, tags: [Tag]) {
            self.id = asset.id
            self.sourceID = asset.sourceId
            self.kind = asset.kind
            self.blobHash = asset.blobHash
            self.mimeType = asset.mimeType
            self.width = asset.width
            self.height = asset.height
            self.duration = asset.duration
            self.fileSize = asset.fileSize
            self.downloadState = asset.downloadState
            self.createdAt = ArchiveManifest.wire(asset.createdAt)
            self.name = asset.name
            self.note = asset.note
            self.isFavorite = asset.isFavorite
            self.viewCount = asset.viewCount
            self.lastViewedAt = asset.lastViewedAt.map(ArchiveManifest.wire)
            self.payload = asset.payload
            self.dedupKey = asset.dedupKey
            self.searchText = asset.searchText
            self.tags = tags.map(TagEntry.init)
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, width, height, duration, name, note, payload, tags
            case sourceID = "source_id"
            case blobHash = "blob_hash"
            case mimeType = "mime_type"
            case fileSize = "file_size"
            case downloadState = "download_state"
            case createdAt = "created_at"
            case isFavorite = "is_favorite"
            case viewCount = "view_count"
            case lastViewedAt = "last_viewed_at"
            case dedupKey = "dedup_key"
            case searchText = "search_text"
        }

        /// Hand-written ONLY to make `is_favorite` optional on the way in.
        ///
        /// Swift's synthesized `Decodable` calls `decode`, not `decodeIfPresent`,
        /// for a non-optional property — a default value on the declaration does
        /// nothing for it. So without this, adding the field would make every
        /// archive written before v19 fail to decode ENTIRELY: the whole
        /// backward-compatibility argument for not bumping `manifest_version`
        /// rests on this one `decodeIfPresent`. Everything else is the synthesized
        /// behaviour spelled out, and `encode(to:)` is left synthesized.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sourceID = try container.decode(UUID.self, forKey: .sourceID)
            kind = try container.decode(AssetKind.self, forKey: .kind)
            blobHash = try container.decodeIfPresent(String.self, forKey: .blobHash)
            mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            width = try container.decodeIfPresent(Int.self, forKey: .width)
            height = try container.decodeIfPresent(Int.self, forKey: .height)
            duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
            downloadState = try container.decode(DownloadState.self, forKey: .downloadState)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            note = try container.decodeIfPresent(String.self, forKey: .note)
            // Absent = written before favorites existed = not a favorite.
            isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
            viewCount = try container.decode(Int.self, forKey: .viewCount)
            lastViewedAt = try container.decodeIfPresent(Date.self, forKey: .lastViewedAt)
            payload = try container.decodeIfPresent(String.self, forKey: .payload)
            dedupKey = try container.decodeIfPresent(String.self, forKey: .dedupKey)
            searchText = try container.decodeIfPresent(String.self, forKey: .searchText)
            tags = try container.decode([TagEntry].self, forKey: .tags)
        }
    }

    /// One ``CollectionItem`` — an asset's membership in the enclosing
    /// collection, with the manual order that makes a re-import land in the
    /// arrangement the user made, and the per-membership canvas placement.
    struct MembershipEntry: Codable, Equatable, Sendable {
        var assetID: UUID
        var addedAt: Date
        var manualOrder: Int?
        /// Archive-relative path of this asset's copy inside this collection's
        /// folder, or `nil` when there was nothing to copy — a media-less kind,
        /// or a blob whose file was already gone from disk.
        var file: String?
        var canvasX: Double?
        var canvasY: Double?
        var canvasW: Double?
        var canvasH: Double?
        var canvasZ: Int?

        init(_ item: CollectionItem, file: String?) {
            self.assetID = item.assetID
            self.addedAt = ArchiveManifest.wire(item.addedAt)
            self.manualOrder = item.manualOrder
            self.file = file
            self.canvasX = item.canvasX
            self.canvasY = item.canvasY
            self.canvasW = item.canvasW
            self.canvasH = item.canvasH
            self.canvasZ = item.canvasZ
        }

        enum CodingKeys: String, CodingKey {
            case file
            case assetID = "asset_id"
            case addedAt = "added_at"
            case manualOrder = "manual_order"
            case canvasX = "canvas_x"
            case canvasY = "canvas_y"
            case canvasW = "canvas_w"
            case canvasH = "canvas_h"
            case canvasZ = "canvas_z"
        }
    }

    /// One ``Collection``, its nesting, and its memberships.
    struct CollectionEntry: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var description: String?
        var parentID: UUID?
        var coverAssetID: UUID?
        var createdAt: Date
        var updatedAt: Date
        var sortMode: SortMode
        var sortIndex: Int
        /// The folder this collection's copies were written to, archive-relative
        /// (`Collections/Design/Refs`). Presentation, not structure — `parentID`
        /// is the real nesting, and a path CAN repeat when the tree was too deep
        /// to nest (see ``ArchiveLayout/placement(parent:name:collectionID:)``).
        var path: String
        /// Memberships, in this collection's manual order.
        var items: [MembershipEntry]

        init(_ collection: Collection, path: String, items: [MembershipEntry]) {
            self.id = collection.id
            self.name = collection.name
            self.description = collection.description
            self.parentID = collection.parentCollectionID
            self.coverAssetID = collection.coverAssetID
            self.createdAt = ArchiveManifest.wire(collection.createdAt)
            self.updatedAt = ArchiveManifest.wire(collection.updatedAt)
            self.sortMode = collection.sortMode
            self.sortIndex = collection.sortIndex
            self.path = path
            self.items = items
        }

        enum CodingKeys: String, CodingKey {
            case id, name, description, path, items
            case parentID = "parent_collection_id"
            case coverAssetID = "cover_asset_id"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case sortMode = "sort_mode"
            case sortIndex = "sort_index"
        }
    }

    // MARK: - Serialization

    /// Deterministic: sorted keys and ISO-8601 dates, so the same manifest
    /// always produces byte-identical output. That is what lets a test pin the
    /// contract against a golden string and fail loudly when the shape moves.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Write to `url`, replacing any previous manifest. `.atomic` so an export
    /// interrupted here leaves no truncated contract behind — and because the
    /// manifest is written LAST, its presence is the export's commit record (the
    /// same role `BackupRunner`'s manifest plays for a backup).
    func write(to url: URL) throws {
        try Self.makeEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Read a manifest, or throw if it is absent or unparseable.
    static func read(from url: URL) throws -> ArchiveManifest {
        try makeDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: url))
    }

    // MARK: - Version refusal

    /// Why `manifest` must not be read by a build at `schemaVersion`, or `nil`
    /// if it can be. Pure, so both version rules are directly testable.
    ///
    /// The rule is "newer than me", and only that. An UNPARSEABLE version on
    /// either side is deliberately NOT a refusal: refusing on it would brick an
    /// import for anyone whose version string this build simply doesn't
    /// recognise, and "I can't tell" is not evidence of "newer".
    static func refusal(
        for manifest: ArchiveManifest,
        schemaVersion: String = AppServices.schemaVersion
    ) -> ArchiveRefusal? {
        if manifest.manifestVersion > currentVersion {
            return .manifestTooNew(manifest.manifestVersion)
        }
        guard let archive = schemaOrdinal(manifest.schemaVersion),
              let local = schemaOrdinal(schemaVersion),
              archive > local else { return nil }
        return .schemaTooNew(manifest.schemaVersion)
    }

    /// `"v18"` → `18`; anything else → `nil` (unreadable, not "newer").
    static func schemaOrdinal(_ version: String) -> Int? {
        guard version.hasPrefix("v") else { return nil }
        return Int(version.dropFirst())
    }
}
