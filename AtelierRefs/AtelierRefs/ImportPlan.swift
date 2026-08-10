//
//  ImportPlan.swift
//  AtelierRefs
//
//  008 · H7 — the vocabulary the REPLAY LAYER speaks.
//
//  The importer is deliberately two pieces. The first is a pure parse that turns
//  something on disk into `[ImportPlan]`; the second walks those plans through
//  the shipped public writers (`createCollection`, `ingest` / `ingestContent`,
//  `addAssets`, `applyTag`, `setGridOrder`, `setCanvasPlacement`). This file is
//  the seam between them, and it is the whole reason the split exists: every
//  invariant, every validation and 18A's content-hash dedup come free, because
//  nothing an importer can express bypasses the funnel.
//
//  Two properties this shape exists to keep:
//
//  1. **An asset is identified by a KEY, not by a row.** A plan says "this
//     membership is asset X"; the replay layer materializes X exactly once and
//     turns every later mention into a membership. That is what makes a
//     multi-collection asset import as ONE asset with N memberships rather than
//     N copies — the archive's defining asymmetry (008 · H6), stated here so a
//     future non-archive parser inherits it rather than rediscovers it.
//  2. **Nesting is a key relationship, never a path.** `parentKey` is the whole
//     structure. Paths can legitimately repeat — the archive relocates a folder
//     that would overrun the path budget — so a layer that reconstructed nesting
//     from directories would silently merge two unrelated collections.
//
//  Everything here is a plain value: no database, no filesystem, no AppKit. A
//  parser can be tested by comparing plans, and the replay layer can be driven
//  from plans a test wrote by hand.
//

import AtelierCore
import Foundation

// MARK: - The plan

/// One collection to create, and the memberships to fill it with, in the order
/// they should end up in the manual grid.
nonisolated struct ImportPlan: Sendable, Equatable {
    /// This collection's identity IN THE SOURCE — opaque to the replay layer,
    /// which only ever compares it to a ``parentKey``. A `String` rather than a
    /// `UUID` because the archive's ids are UUIDs and nothing else's have to be.
    var key: String
    /// The source's parent id, or `nil` for a source-level root. A parent that
    /// is not among the plans is treated as absent — an importer must never be
    /// able to strand a collection by naming a parent it didn't ship.
    var parentKey: String?
    var name: String
    var description: String?
    /// Memberships in the order they should occupy the manual grid.
    var items: [ImportItem]

    init(
        key: String, parentKey: String? = nil, name: String,
        description: String? = nil, items: [ImportItem] = []
    ) {
        self.key = key
        self.parentKey = parentKey
        self.name = name
        self.description = description
        self.items = items
    }
}

/// One membership: which asset, where its substance is, and the per-asset facts
/// only the source knows.
nonisolated struct ImportItem: Sendable, Equatable {
    /// The asset's identity IN THE SOURCE. Two items sharing a key are the same
    /// asset in two collections — one asset, two memberships.
    var key: String
    /// Where the asset's substance comes from.
    var body: ImportBody
    /// Provenance, replayed VERBATIM. 18A dedup matches an existing asset over
    /// the same bytes only when its source matches — same `original_url` when
    /// one is given, else same `platform` — so a field normalized on the way
    /// through here forks a second asset on re-import. Idempotency is a property
    /// of what the parser produces, not only of the pipeline.
    var source: SourceDraft
    /// `(name, source)` pairs for ``AppServices/applyTag(_:to:source:)``.
    var tags: [ImportTag]
    /// The asset's display name, applied only when the asset is NEW (see
    /// ``LibraryImporter``).
    var name: String?
    /// The asset's note, applied only when the asset is NEW.
    var note: String?
    /// Whether the source marked this asset a favorite (011 · U5). Applied like a
    /// TAG, not like `name` / `note`: setting the star only ever ADDS information,
    /// so it is safe on a deduplicated asset, whereas overwriting a name would
    /// discard an edit made in this library. `false` is never replayed — an
    /// archive saying "not a favorite" is the absence of a claim, not an
    /// instruction to unstar something the user starred here.
    var isFavorite: Bool
    /// Whether the source had this asset on its archive shelf (023 · A). Applied
    /// like the star, and for the same reasons: archiving is additive user intent
    /// that nothing can recompute, and `false` is never replayed — a plan saying
    /// "not archived" is the absence of a claim, not an instruction to pull an
    /// item off the shelf the user put it on in THIS library.
    ///
    /// A Bool rather than the source's timestamp, because the timestamp is not
    /// replayable: `archive(_:)` is server-authoritative, exactly as `created_at`
    /// already is on this path. A restored shelf keeps its membership, not its
    /// original ordering.
    var isArchived: Bool
    /// This membership's canvas placement, when it had one.
    var placement: CanvasPlacement?

    init(
        key: String, body: ImportBody, source: SourceDraft,
        tags: [ImportTag] = [], name: String? = nil, note: String? = nil,
        isFavorite: Bool = false, isArchived: Bool = false,
        placement: CanvasPlacement? = nil
    ) {
        self.key = key
        self.body = body
        self.source = source
        self.tags = tags
        self.name = name
        self.note = note
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.placement = placement
    }
}

/// A tag as a plan carries it — exactly what `applyTag` finds-or-creates. No id:
/// the destination library mints its own.
nonisolated struct ImportTag: Sendable, Equatable {
    var name: String
    var source: TagSource

    init(name: String, source: TagSource) {
        self.name = name
        self.source = source
    }
}

/// Bytes waiting on disk, plus the facts the source declared about them.
///
/// The HASH is deliberately absent. The replay layer computes it from the file
/// it is about to store, because the blob store is content-addressed: bytes
/// filed under a hash nobody verified would render as the wrong image for every
/// future asset that hashes there, and that is not recoverable. A source's
/// declared hash is a claim about a file the user can open, rename and replace.
nonisolated struct ImportBytes: Sendable, Equatable {
    var url: URL
    var mimeType: String
    var width: Int
    var height: Int
    var duration: Double?

    init(url: URL, mimeType: String, width: Int, height: Int, duration: Double? = nil) {
        self.url = url
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.duration = duration
    }
}

/// Where an item's substance is: in a file, or in the plan itself.
nonisolated enum ImportBody: Sendable, Equatable {
    /// A byte-backed kind (`image` / `video`) — replayed through `ingest`.
    case media(kind: AssetKind, bytes: ImportBytes, downloadState: DownloadState)
    /// A media-less kind (`color` / `link` / `tweet`) — replayed through
    /// `ingestContent`, optionally with the card image it also carries (003 · C3).
    /// The funnel derives the canonical payload, `dedup_key` and `search_text`,
    /// so a plan supplies intent and never canonical form.
    case content(AssetContentDraft, card: ImportBytes?)
}

// MARK: - The report

/// Why one membership was not imported. A skip is a decision the importer made
/// knowingly; a failure is a writer that threw. Both are counted and named — a
/// silent partial is the one outcome an import must never produce.
nonisolated enum ImportSkipReason: String, Sendable, Equatable {
    /// The membership named an asset the source didn't ship.
    case unknownAsset
    /// The asset named provenance the source didn't ship. Without it the asset
    /// cannot be ingested at all: `source` is non-optional in the funnel (C6).
    case unknownSource
    /// The asset's bytes were supposed to be in the archive and aren't.
    case missingFile
    /// The asset carries neither usable bytes nor a usable payload — nothing a
    /// public writer could be handed.
    case unusable
}

/// One membership the importer knowingly did not import.
nonisolated struct ImportSkip: Sendable, Equatable {
    /// The collection it would have joined, by name — what a user recognises.
    var collection: String
    /// The item's source key, for a diagnostic log.
    var item: String
    var reason: ImportSkipReason

    init(collection: String, item: String, reason: ImportSkipReason) {
        self.collection = collection
        self.item = item
        self.reason = reason
    }
}

/// One write that threw. `item` is `nil` when the whole collection failed.
nonisolated struct ImportFailure: Sendable, Equatable {
    var collection: String
    var item: String?
    var message: String

    init(collection: String, item: String? = nil, message: String) {
        self.collection = collection
        self.item = item
        self.message = message
    }
}

/// What one replay produced. Honest by construction: every count here is
/// something that happened, and everything that didn't happen is in ``failed``.
nonisolated struct ImportReport: Sendable, Equatable {
    /// The new root collection everything landed under.
    var destinationID: UUID?
    /// Its name AS CREATED — `createCollection` disambiguates a duplicate
    /// sibling name Finder-style, so this can differ from what was asked for.
    var destinationName: String = ""
    /// Collections created BELOW the destination (the destination itself is not
    /// counted — it is the container, not content).
    var collections: Int = 0
    /// Distinct assets the memberships resolved to, deduplicated ones included.
    var assets: Int = 0
    /// How many of those were newly created rather than matched by 18A dedup.
    /// `assets - newAssets` is what a second import of the same archive reuses.
    var newAssets: Int = 0
    /// Memberships written.
    var memberships: Int = 0
    /// Writes that threw.
    var failed: [ImportFailure] = []

    init() {}
}
