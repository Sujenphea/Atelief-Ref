// AtelierArchive — the phone's captures as an archive the Mac can import (092 · S6).
//
// **What the phone actually has to send, which is not its library.** When this was written
// iOS never drained its inbox — `InboxDrain` lives in AtelierIngestion, which did not build
// there (`.change-log/452` fixed that, and 454 wired the drain) — so a capture made on the
// phone was a RECORD plus a payload file in `inbox/`, and never became an asset row on the
// device that captured it. The phone's SQLite library held only what had been synced back
// to it. So "export what the phone captured" means reading the inbox, not the library, and
// this file is the only writer in the program that starts from records.
//
// **And that stays true once the phone does drain.** 096 · 4 gives `InboxDrain` a retention
// policy so the phone can ingest a share into its own grid without destroying the record —
// the record moves to `inbox/ingested/` instead of being deleted, because the capture is in
// the local library and has still not reached the Mac. Those two facts are independent, and
// this file is where that shows: ``pendingRecords(in:)`` reads the pending set AND the
// ingested one, and ``payloadSite(of:layout:)`` finds a payload at either site. An export
// that read only the top level would ingest a capture and then be unable to send it.
//
// **Why an archive rather than shipping the inbox folder.** 091 · D4 chose the archive
// manifest for one property: import idempotency. Provenance is copied verbatim, so 18A
// blob-hash dedup collapses a re-import onto the existing asset instead of forking a
// second one over the same bytes. That makes the transport question boring — AirDrop it
// twice, keep a copy in iCloud Drive, re-import last week's folder — and it is what lets
// the phone KEEP its records after an export rather than deleting them on a promise that
// the other end succeeded.
//
// **One manifest builder, not two.** The entries are built through the same
// `ArchiveManifest.SourceEntry(_:)` / `.AssetEntry(_:tags:)` / `.MembershipEntry(_:file:)`
// initializers `LibraryArchiveWriter` uses, by constructing the domain values in memory
// from each record. Constructing an `Asset` that no database will ever hold looks odd for
// a moment; the alternative is a second set of entry initializers taking raw fields, which
// is a second definition of the format's contents. The golden-file tests pin one of those.
//
// **The folder an export lives in is this file's too, since 098 · finding 4.**
// ``InboxArchive/writeExport(_:layout:under:folderName:appVersion:schemaVersion:now:)``
// clears the parent, creates the timestamped folder, writes and returns both. It used to
// be four lines in the phone's controller that removed a folder of the same name — the
// same name only within the same minute — so two sends a minute apart left two complete
// copies of every capture in Caches, and "Clear" then made the abandoned one the sole
// owner of those bytes. An export owns its parent: one export exists at a time.
//
// **And what it could not read is a number, not a silence** (098 · finding 8).
// ``InboxArchive/pending(in:)`` returns the records AND the count of `.json` files that
// would not decode into one; ``InboxArchive/Summary/skipped`` folds that count in and
// ``InboxArchive/Summary/skippedIDs`` names the records the funnel refused. A capture the
// export is not carrying is now something the program can say out loud.
//
// **The provenance is the drain's, exactly.** Each record goes through
// `CaptureDecoder.decodeFileInput` / `.decodeInput` — the same funnel the Mac's drain runs
// (092 · S0's whole point) — so a capture that travels by archive arrives with the
// provenance it would have had if the Mac had drained it directly. Anything the funnel
// refuses is skipped and left in the inbox rather than being written half-formed.

import AtelierCapture
import AtelierCore
import AtelierLibraryPaths
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns pending inbox records into a `LibraryArchive`-shaped folder.
public nonisolated enum InboxArchive {

    /// What a run produced. `skipped` is not a failure: a record the funnel refuses, or one
    /// whose payload is gone, stays in the inbox for a later run to reconsider.
    public struct Summary: Sendable, Equatable {
        /// Captures written into the manifest.
        public var captures: Int = 0
        /// Payload files copied. Lower than ``captures`` when a capture is media-less.
        public var files: Int = 0
        /// Everything the run did not send: ``unreadable`` plus ``skippedIDs``.
        ///
        /// One number because it is one answer to one question — "how many captures did
        /// this run leave behind" — and the two halves are separately available for a
        /// caller that wants to say more. The invariant `skipped == unreadable +
        /// skippedIDs.count` is pinned by a test.
        public var skipped: Int = 0
        /// Records the funnel refused, or whose payload file was missing, BY NAME
        /// (098 · finding 8).
        ///
        /// The count alone said one capture was left behind and said nothing about
        /// which, which is exactly the fact a person looking at a stuck "Send 3" needs.
        /// Named rather than logged because this is a package with no logger, and the
        /// only caller that can say anything to anyone is the app.
        public var skippedIDs: [UUID] = []
        /// `.json` files in the inbox that would not decode at all (098 · finding 8).
        ///
        /// These never became records, so they have no id to be named by and cannot be
        /// in ``skippedIDs``; they are counted here and folded into ``skipped`` so that
        /// the number a button shows and the number of entries in the manifest cannot
        /// disagree. Before this they were dropped silently by
        /// ``pendingRecords(in:)``'s `try?`, and one of them made "Send 4" a permanent
        /// lie on a phone that could only ever send 3.
        public var unreadable: Int = 0
        /// The ids that actually reached the manifest, in the order they were written
        /// (096 · 3B).
        ///
        /// **`captures` counts; this names.** A caller retiring what it just sent needs the
        /// second, and cannot derive it from the first: the records it handed in are a
        /// superset, because ``skipped`` records — a funnel refusal, a payload gone missing —
        /// stay pending on purpose. Retiring on the strength of an export a capture was not
        /// in is exactly the way "nothing is deleted" would stop being true.
        public var exported: [UUID] = []
        /// Where the manifest landed.
        public var manifestURL: URL

        public init(
            captures: Int = 0, files: Int = 0, skipped: Int = 0,
            skippedIDs: [UUID] = [], unreadable: Int = 0,
            exported: [UUID] = [], manifestURL: URL
        ) {
            self.captures = captures
            self.files = files
            self.skipped = skipped
            self.skippedIDs = skippedIDs
            self.unreadable = unreadable
            self.exported = exported
            self.manifestURL = manifestURL
        }

        /// Leave a capture behind, counting it and naming it in one step — so a future
        /// fourth `continue` in the write loop cannot move one and forget the other.
        mutating func skip(_ id: UUID) {
            skipped += 1
            skippedIDs.append(id)
        }
    }

    /// The records an export would send, and the files it could not read (098 · finding 8).
    ///
    /// The pair is one value because they are one reading of the inbox and a caller that
    /// has the first without the second reports a number it cannot justify — which is the
    /// defect this closes: the phone counted `.json` FILES, `pendingRecords(in:)` silently
    /// dropped the ones that would not decode, and the two numbers were allowed to differ
    /// forever with nothing in the program able to notice.
    public struct Pending: Sendable, Equatable {
        /// What will be written, in the order it should be written.
        public var records: [InboxRecord]
        /// How many `.json` files across the two sites would not decode into one.
        ///
        /// A count and not a list of URLs: nothing downstream can do anything with the
        /// path (the drain's sweep is what quarantines these — 098 · finding 8), and the
        /// only question this answers is how many captures the export is not carrying.
        public var unreadable: Int

        public init(records: [InboxRecord] = [], unreadable: Int = 0) {
            self.records = records
            self.unreadable = unreadable
        }
    }

    /// What a whole export produced: the folder to hand to a share sheet, and the run.
    public struct Export: Sendable {
        /// The timestamped folder, freshly created, with the manifest inside it.
        public let folder: URL
        /// The run — `exported` is what the caller may retire.
        public let summary: Summary

        public init(folder: URL, summary: Summary) {
            self.folder = folder
            self.summary = summary
        }
    }

    /// Why a run produced nothing worth handing to anyone.
    public enum WriteError: Error, Equatable {
        /// There were no pending captures. The caller should say so rather than offering
        /// an empty folder to a share sheet.
        case nothingToExport
        /// Every capture failed to copy — the destination is full or unwritable. No
        /// manifest is written, for the reason ``LibraryArchiveWriter`` gives: a folder
        /// without one is visibly incomplete rather than plausibly whole.
        case nothingCopied
    }

    /// The collection every phone capture belongs to.
    ///
    /// Unsorted, always: the share sheet has no collection picker (093 § 1 posts and
    /// dismisses), so `collectionId` is nil on every record this reads, and the drain's own
    /// default for that is Unsorted. The archive says the same thing the drain would have.
    /// Public because it is the name the collection ARRIVES under on the Mac, which the
    /// S6c round trip asserts rather than re-spells.
    public static let collectionName = "Unsorted"

    /// Every record the phone still owes the Mac, in the order an export should write
    /// them.
    ///
    /// **"Pending" here has always meant pending EXPORT, and 096 · 4 is what made the
    /// difference visible.** Until the phone drained its own inbox the two sets were the
    /// same one: a record was in `inbox/` until somebody took it away, and nobody did. Now
    /// a retaining `InboxDrain` moves an ingested record to `inbox/ingested/` so no pass
    /// runs it twice — and if this read only the top level, the phone would ingest a
    /// capture into its own grid and then be permanently unable to send it. Being in the
    /// phone's library says nothing about having reached the Mac; that is the whole reason
    /// the record is kept at all.
    ///
    /// So the union is composed HERE and nowhere else. ``InboxLayout/pendingRecordURLs()``
    /// deliberately still cannot see `ingested/` — the drain asks that question and must
    /// get the old answer — and the export asks a second one on top of it.
    ///
    /// Ids are deduplicated, keeping the first of a repeat. A record cannot legitimately be
    /// in both places (the drain MOVES it), so this is guarding a state that should not
    /// exist rather than a state that happens; it costs a set and it stops a half-finished
    /// hand-edit of the inbox from producing a manifest with two entries under one source
    /// id, which the reader has no way to make sense of.
    ///
    /// Capture-time order, the same order the Mac's drain walks (405), so a folder opened
    /// on the Mac reads in the order the user actually saved things; the id breaks a tie
    /// so two captures made in the same millisecond do not reorder between runs.
    ///
    /// This is a HELPER, not a step ``write(records:layout:to:appVersion:schemaVersion:exportedAt:)``
    /// takes for itself — a writer that silently decided its own order would be a second
    /// opinion about it. It exists so the phone's export and the round-trip test that
    /// checks the phone's export agree by construction rather than by retyping.
    ///
    /// **`InboxRecord.makeDecoder()`, never a bare `JSONDecoder`.** Records are written
    /// with `.secondsSince1970` and a stock decoder reads a bare number as
    /// `timeIntervalSinceReferenceDate` — the same digits, 31 years later. The order came
    /// out right either way (every date was shifted by the same constant), so the only
    /// place it showed was the `created_at` the Mac ended up storing: every phone capture
    /// dated 2054 and pinned to the top of Newest forever. 092 · S6c caught it.
    public static func pendingRecords(in layout: InboxLayout) throws -> [InboxRecord] {
        try pending(in: layout).records
    }

    /// ``pendingRecords(in:)``, plus the count of what would not read (098 · finding 8).
    ///
    /// **The `try?` used to be the end of the story.** A `.json` that will not decode was
    /// dropped here without a sound, so an export wrote a manifest of three captures while
    /// the control above it said four — the phone counted files, this counted records, and
    /// nothing in the program could see both numbers. Now the drop is a number, it is
    /// folded into ``Summary/skipped``, and the phone counts what this returns.
    ///
    /// It is deliberately still a DROP and not a throw: one unreadable file must not stop
    /// the other captures from being sent, which is the same judgement ``write`` makes for
    /// a record the funnel refuses. Getting the file out of the way is the drain's job
    /// (`InboxDrain`'s ingested-site sweep), not the export's — an export is something the
    /// user asked for and must not be a filesystem tidy-up.
    public static func pending(in layout: InboxLayout) throws -> Pending {
        let decoder = InboxRecord.makeDecoder()
        let urls = try layout.pendingRecordURLs() + layout.ingestedRecordURLs()
        var seen: Set<UUID> = []
        var records: [InboxRecord] = []
        var unreadable = 0
        records.reserveCapacity(urls.count)

        for url in urls {
            guard let record = try? decoder.decode(
                InboxRecord.self, from: Data(contentsOf: url)) else {
                unreadable += 1
                continue
            }
            // A duplicate id is not unreadable — it is the same capture, read twice.
            if seen.insert(record.id).inserted { records.append(record) }
        }

        records.sort { ($0.capturedAt, $0.id.uuidString) < ($1.capturedAt, $1.id.uuidString) }
        return Pending(records: records, unreadable: unreadable)
    }

    /// Write `records` into `root` as an archive.
    ///
    /// `manifest.json` is written LAST, which is the format's commit marker — an
    /// interrupted run leaves a folder the reader refuses rather than a partial import.
    ///
    /// - Parameters:
    ///   - records: pending records, in the order they should appear. The caller sorts;
    ///     `InboxLayout.pendingRecordURLs()` plus a capture-time sort is what the drain
    ///     does, and doing it here would be a second opinion about order.
    ///   - layout: resolves each record's payload file.
    ///   - root: the archive folder, created if absent.
    ///   - unreadable: how many `.json` files the caller could not decode into records
    ///     at all (``Pending/unreadable``), folded into ``Summary/skipped`` so the
    ///     manifest and the count the caller shows describe the same inbox. Defaulted
    ///     because a caller that hands over a list it built itself is claiming there was
    ///     nothing it could not read.
    public static func write(
        records: [InboxRecord],
        layout: InboxLayout,
        to root: URL,
        appVersion: String,
        schemaVersion: String = AppServices.schemaVersion,
        exportedAt: Date,
        unreadable: Int = 0
    ) throws -> Summary {
        guard !records.isEmpty else { throw WriteError.nothingToExport }

        let fileManager = FileManager.default
        // Placed exactly as `LibraryArchiveWriter` places a root collection, so a
        // phone-written archive and a Mac-written one have the same shape on disk.
        let placement = ArchiveLayout.placement(
            parent: [ArchiveLayout.collectionsDirectory],
            name: LibraryArchiveWriter.folderName(for: collectionName),
            collectionID: Collection.unsortedID)
        let components = placement.parent + [placement.name]
        let directory = components.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // The unreadable files start the skip count: they are captures this run is not
        // carrying, they have no id to be named by, and a caller that adds them itself
        // afterwards is a caller that can forget to.
        var summary = Summary(
            skipped: unreadable, unreadable: unreadable,
            manifestURL: root.appendingPathComponent(ArchiveLayout.manifestFilename))
        var names = ExportNameAllocator()
        var sources: [ArchiveManifest.SourceEntry] = []
        var assets: [ArchiveManifest.AssetEntry] = []
        var memberships: [ArchiveManifest.MembershipEntry] = []
        // Two captures of the same bytes share one file in the archive, exactly as
        // `LibraryArchiveWriter` does — the manifest refers to it twice.
        var byHash: [String: String] = [:]

        for record in records {
            guard let capture = decode(record, layout: layout) else {
                summary.skip(record.id)
                continue
            }

            var blob: (hash: String, size: Int, mimeType: String, width: Int, height: Int)?
            var file: String?
            if let payload = capture.payloadURL {
                guard let probed = probe(payload) else {
                    summary.skip(record.id)
                    continue
                }
                blob = probed
                if let already = byHash[probed.hash] {
                    file = ArchiveLayout.relativePath(components + [already])
                } else {
                    let name = names.claim(
                        AssetExport.filename(
                            base: AssetExport.baseName(
                                title: capture.provenance.title,
                                authorHandle: capture.provenance.authorHandle,
                                sourceURL: capture.provenance.originalURL),
                            blobHash: probed.hash,
                            ext: LibraryMediaPaths.fileExtension(forMIMEType: probed.mimeType)))
                    do {
                        try fileManager.copyItem(
                            at: payload, to: directory.appendingPathComponent(name))
                    } catch {
                        summary.skip(record.id)
                        continue
                    }
                    byHash[probed.hash] = name
                    file = ArchiveLayout.relativePath(components + [name])
                    summary.files += 1
                }
            }

            // Ids are the RECORD's, so exporting the same inbox twice produces the same
            // manifest. They are opaque keys to the importer — it re-ingests and dedups on
            // provenance and bytes — but a stable one makes two exports diffable.
            let sourceID = record.id
            let assetID = record.id
            sources.append(ArchiveManifest.SourceEntry(Source(
                id: sourceID,
                platform: capture.provenance.platform,
                originalURL: capture.provenance.originalURL,
                authorHandle: capture.provenance.authorHandle,
                authorName: capture.provenance.authorName,
                title: capture.provenance.title,
                capturedAt: capture.provenance.capturedAt,
                rawMetadata: capture.provenance.rawMetadata)))
            assets.append(ArchiveManifest.AssetEntry(
                Asset(
                    id: assetID,
                    kind: capture.kind,
                    blobHash: blob?.hash,
                    mimeType: blob?.mimeType,
                    width: blob?.width,
                    height: blob?.height,
                    fileSize: blob?.size,
                    downloadState: .downloaded,
                    createdAt: record.capturedAt,
                    sourceId: sourceID,
                    payload: capture.payload?.jsonString()),
                tags: []))
            memberships.append(ArchiveManifest.MembershipEntry(
                CollectionItem(
                    id: record.id,
                    collectionID: Collection.unsortedID,
                    assetID: assetID,
                    addedAt: record.capturedAt,
                    manualOrder: summary.captures),
                file: file))
            summary.captures += 1
            // Recorded here and nowhere earlier: every `continue` above is a record that
            // stays pending, and this is the one line the loop reaches only when a capture
            // is genuinely in the manifest.
            summary.exported.append(record.id)
        }

        guard summary.captures > 0 else { throw WriteError.nothingCopied }

        let manifest = ArchiveManifest(
            schemaVersion: schemaVersion,
            appVersion: appVersion,
            exportedAt: exportedAt,
            sources: sources,
            assets: assets,
            collections: [ArchiveManifest.CollectionEntry(
                Collection(
                    id: Collection.unsortedID,
                    name: collectionName,
                    createdAt: exportedAt,
                    updatedAt: exportedAt),
                path: ArchiveLayout.relativePath(components),
                items: memberships)])
        try manifest.write(to: summary.manifestURL)
        return summary
    }

    // MARK: - A whole export

    /// The folder lifecycle an export needs, in the package that owns the format
    /// (098 · finding 4): clear the parent, make the timestamped folder, write into it,
    /// hand back the folder and the run.
    ///
    /// **Why the parent is CLEARED and not just the folder.** The phone wrote into
    /// `Caches/Exports/Atelier <date> <time>/` and removed only a folder of the same
    /// name, which is the same name only within one minute. Send at 18:30 and again at
    /// 18:31 and both folders survive; each one holds a full copy of every capture's
    /// bytes. That is free while the inbox still owns those bytes — the copies are hard
    /// facts about the same files on the same volume — right up until "Clear" retires the
    /// captures and deletes the ingested payloads, at which point every abandoned export
    /// folder becomes the sole owner of a complete copy of the user's captures, in Caches,
    /// unreachable from any screen. So an export owns its parent directory: exactly one
    /// export exists at a time, and the folder handed to the share sheet is the only one.
    ///
    /// Everything in the parent goes, not only directories. A stray file there is either
    /// something this program left or something nothing put there on purpose, and the
    /// directory's whole meaning is "the current export"; a tidy-up that skipped files
    /// would leave the one kind of litter it could not explain.
    ///
    /// **Clearing before writing, not after.** A failed write leaves an empty parent and
    /// no folder, which is honest — the previous export was stale the moment this one was
    /// asked for, and the captures themselves are still in the inbox, which is the only
    /// copy that was ever load-bearing.
    ///
    /// `folderName` is the caller's because naming is presentation: the string is what a
    /// person reads on a Mac desktop beside whatever else was AirDropped that day, and
    /// this package has no locale, no formatter and no opinion about it.
    ///
    /// - Throws: ``WriteError`` from ``write(records:layout:to:appVersion:schemaVersion:exportedAt:unreadable:)``,
    ///   or a `FileManager` error if the folder cannot be made.
    public static func writeExport(
        _ pending: Pending,
        layout: InboxLayout,
        under parent: URL,
        folderName: String,
        appVersion: String,
        schemaVersion: String = AppServices.schemaVersion,
        now: Date
    ) throws -> Export {
        // Refused before anything is deleted: an empty inbox must not cost the user the
        // folder they are still holding a share sheet over.
        guard !pending.records.isEmpty else { throw WriteError.nothingToExport }

        let fileManager = FileManager.default
        if let existing = try? fileManager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil) {
            for item in existing { try? fileManager.removeItem(at: item) }
        }

        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let summary = try write(
            records: pending.records, layout: layout, to: folder,
            appVersion: appVersion, schemaVersion: schemaVersion, exportedAt: now,
            unreadable: pending.unreadable)
        return Export(folder: folder, summary: summary)
    }

    // MARK: - One record

    /// What a record amounts to once the shared funnel has had it.
    private struct Capture {
        var kind: AssetKind
        var provenance: SourceDraft
        var payload: AssetPayload?
        var payloadURL: URL?
    }

    /// Run `record` through the same decode funnel the Mac's drain uses, or `nil` when the
    /// funnel refuses it or its payload file is not there.
    private static func decode(_ record: InboxRecord, layout: InboxLayout) -> Capture? {
        let payloadURL = payloadSite(of: record, layout: layout)
        if let payloadURL, FileManager.default.fileExists(atPath: payloadURL.path) {
            guard let decoded = try? CaptureDecoder.decodeFileInput(
                record.request, now: record.capturedAt) else { return nil }
            switch decoded {
            case let .bytes(capture):
                return Capture(
                    kind: .image, provenance: capture.provenance, payload: nil,
                    payloadURL: payloadURL)
            case let .contentWithFile(capture):
                return Capture(
                    kind: capture.draft.kind, provenance: capture.provenance,
                    payload: capture.draft.payload, payloadURL: payloadURL)
            }
        }

        // No file. A media-less capture is complete without one — a shared link is the
        // link. A byte-backed record whose payload has gone missing is not, and the funnel
        // below refuses it for us: `decodeInput` requires image bytes it does not have.
        guard let decoded = try? CaptureDecoder.decodeInput(
            record.request, now: record.capturedAt) else { return nil }
        switch decoded {
        case let .content(capture):
            return Capture(
                kind: capture.draft.kind, provenance: capture.provenance,
                payload: capture.draft.payload, payloadURL: nil)
        case .image, .contentWithImage:
            // Base64 bytes inside the record. The share extension never writes one (091 ·
            // D2 keeps the image out of memory), so this is a shape from another producer
            // that has no business in an inbox export.
            return nil
        }
    }

    /// Where this record's bytes actually are: beside it in `inbox/`, or under
    /// `inbox/ingested/` where a retaining drain parked them. `nil` for a media-less
    /// record, for a `payloadFile` the layout refuses, and for bytes that are in neither
    /// place.
    ///
    /// **Both sites, and only the export looks in both.** The drain reads exactly one —
    /// asking it to consider `ingested/` would be asking it to re-run captures it has
    /// already run — so the two-site question is asked here, by the one caller whose set of
    /// records genuinely spans them. A layout method meaning "wherever the payload is"
    /// would have been the tidier-looking place for it and would have put that answer
    /// within reach of the code that must not have it.
    ///
    /// The inbox is checked first, and the order is not arbitrary. ``InboxDrain`` moves the
    /// record before the payload, so an interrupted retention leaves an ingested record
    /// whose bytes are still in the inbox — a real state, reachable by a crash, and one
    /// this reads as the whole capture it is.
    ///
    /// The name is the record's own throughout: `payloadURL(for record:)` is what refuses a
    /// record naming a neighbour's sidecar, and the `ingested/` candidate is the layout's
    /// mirror for the record's ID — ``InboxLayout/ingestedPayloadURL(for:)`` — rather than
    /// anything derived from `payloadFile`, so the second site cannot honour a name the
    /// first one rejected.
    private static func payloadSite(
        of record: InboxRecord, layout: InboxLayout
    ) -> URL? {
        guard let inInbox = layout.payloadURL(for: record) else { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: inInbox.path) { return inInbox }
        let retained = layout.ingestedPayloadURL(for: record.id)
        return fileManager.fileExists(atPath: retained.path) ? retained : inInbox
    }

    /// The facts about a payload file an `AssetEntry` needs, read from its header.
    ///
    /// `CGImageSourceCopyPropertiesAtIndex` reads dimensions out of the container without
    /// decoding pixels, so a 4000 px capture costs a header read rather than a bitmap —
    /// the same care 091 · D2 takes in the extension, applied here because this runs on
    /// the same phone.
    ///
    /// Dimensions are mandatory: the reader refuses a byte-backed entry without positive
    /// width and height (`LibraryArchiveReader.body(for:membership:root:)`), so a capture
    /// whose header cannot be read is skipped HERE, where it is still in the inbox, rather
    /// than shipped as an entry the other end will drop.
    private static func probe(
        _ url: URL
    ) -> (hash: String, size: Int, mimeType: String, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }

        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        guard let mimeType = type?.preferredMIMEType else { return nil }
        guard let hash = try? ContentHasher.hash(contentsOf: url),
              let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int else { return nil }
        return (hash, size, mimeType, width, height)
    }
}
