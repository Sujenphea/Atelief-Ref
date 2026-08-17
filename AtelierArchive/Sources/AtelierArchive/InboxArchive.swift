// AtelierArchive — the phone's captures as an archive the Mac can import (092 · S6).
//
// **What the phone actually has to send, which is not its library.** iOS never drains its
// inbox — `InboxDrain` lives in AtelierIngestion and does not build there — so a capture
// made on the phone is a RECORD plus a payload file in `inbox/`, and never becomes an
// asset row on the device that captured it. The phone's SQLite library holds only what has
// been synced back to it. So "export what the phone captured" means reading the inbox, not
// the library, and this file is the only writer in the program that starts from records.
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
// **The provenance is the drain's, exactly.** Each record goes through
// `CaptureDecoder.decodeFileInput` / `.decodeInput` — the same funnel the Mac's drain runs
// (092 · S0's whole point) — so a capture that travels by archive arrives with the
// provenance it would have had if the Mac had drained it directly. Anything the funnel
// refuses is skipped and left in the inbox rather than being written half-formed.

import AtelierCapture
import AtelierCore
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
        /// Records the funnel refused, or whose payload file was missing.
        public var skipped: Int = 0
        /// Where the manifest landed.
        public var manifestURL: URL

        public init(captures: Int = 0, files: Int = 0, skipped: Int = 0, manifestURL: URL) {
            self.captures = captures
            self.files = files
            self.skipped = skipped
            self.manifestURL = manifestURL
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
    static let collectionName = "Unsorted"

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
    public static func write(
        records: [InboxRecord],
        layout: InboxLayout,
        to root: URL,
        appVersion: String,
        schemaVersion: String = AppServices.schemaVersion,
        exportedAt: Date
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

        var summary = Summary(
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
                summary.skipped += 1
                continue
            }

            var blob: (hash: String, size: Int, mimeType: String, width: Int, height: Int)?
            var file: String?
            if let payload = capture.payloadURL {
                guard let probed = probe(payload) else {
                    summary.skipped += 1
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
                        summary.skipped += 1
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
        let payloadURL = layout.payloadURL(for: record)
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
