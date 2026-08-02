// AtelierIngestion — the Library's on-disk storage scan (016 · A).
//
// The READ half of library management: how much disk the Library occupies,
// broken out per tier, plus the per-blob sizes the largest-items list ranks by.
// Deliberately NOT an engine — it opens nothing, writes nothing, and deletes
// nothing. It is `stat` over a `LibraryLayout` and no more.
//
// Two properties earn the two-phase shape below:
//
// 1. **Honest progress.** A fraction needs a denominator, and a directory
//    enumerator has none until it finishes. So phase 1 collects the file list
//    and phase 2 sizes it — only phase 2 reports a fraction, and it is a real
//    one rather than a bar that crawls to 90% and guesses.
// 2. **A library that moves under the scan.** The user can empty the Trash (or
//    restore from it) while this runs. A file that vanished between the two
//    phases is SKIPPED, not fatal; a file that appeared after phase 1 is simply
//    not in this scan's totals and lands in the next one. Neither is an error
//    condition, because neither is the user doing anything wrong.
//
// Sizes are LOGICAL (`fileSize`), not allocated: it is the number Finder's Size
// column shows and the number a user means by "that video is 240 MB". Allocated
// size is a block-rounded second answer to the same question, and two different
// totals for one library is worse than the less precise one.

import AtelierCore
import Foundation

// MARK: - Tiers

/// The Library's on-disk directories, as the storage breakdown names them.
///
/// The split is the point: `thumbnails` and `cache` are DERIVED, and are
/// already excluded from Time Machine (008 H2), so surfacing them separately is
/// what lets the UI say "regenerable: X GB" instead of one opaque total.
public enum LibraryStorageTier: String, Sendable, CaseIterable, Hashable {
    /// Content-addressed originals — the irreplaceable bytes.
    case blobs
    /// Derived thumbnail tiers. Regenerable from `blobs`.
    case thumbnails
    /// Transient staging space. Regenerable (and purgeable) by definition.
    case cache
    /// Recovery snapshots (008 H3) — small, but real, and not derived.
    case snapshots

    /// Whether this tier's bytes can be rebuilt from what remains if lost.
    public var isRegenerable: Bool {
        switch self {
        case .thumbnails, .cache: true
        case .blobs, .snapshots: false
        }
    }
}

// MARK: - Usage

/// The Library's disk footprint, per tier. A plain value type — every field is
/// a measured byte count, and every derived total is computed here so no caller
/// re-adds them differently.
public struct LibraryStorageUsage: Sendable, Equatable {
    /// `library.sqlite` plus its `-wal` / `-shm` sidecars, sized as one unit
    /// (they are inseparable — see ``SQLiteFileSet``).
    public var databaseBytes: Int64
    /// `blobs/` — the originals.
    public var blobBytes: Int64
    /// `thumbnails/` — derived, regenerable, TM-excluded.
    public var thumbnailBytes: Int64
    /// `cache/` — transient staging, purgeable.
    public var cacheBytes: Int64
    /// `snapshots/` — in-app recovery points.
    public var snapshotBytes: Int64
    /// How many blob files were sized (not how many assets — dedup means one
    /// file can back many assets).
    public var blobFileCount: Int
    /// How many thumbnail files were sized (blobs × tiers, when complete).
    public var thumbnailFileCount: Int

    public init(
        databaseBytes: Int64 = 0,
        blobBytes: Int64 = 0,
        thumbnailBytes: Int64 = 0,
        cacheBytes: Int64 = 0,
        snapshotBytes: Int64 = 0,
        blobFileCount: Int = 0,
        thumbnailFileCount: Int = 0
    ) {
        self.databaseBytes = databaseBytes
        self.blobBytes = blobBytes
        self.thumbnailBytes = thumbnailBytes
        self.cacheBytes = cacheBytes
        self.snapshotBytes = snapshotBytes
        self.blobFileCount = blobFileCount
        self.thumbnailFileCount = thumbnailFileCount
    }

    /// Every tier plus the database — the whole Library directory.
    public var totalBytes: Int64 {
        databaseBytes + blobBytes + thumbnailBytes + cacheBytes + snapshotBytes
    }

    /// What could be thrown away and rebuilt: thumbnails + cache. The figure
    /// 008 H2's Time-Machine exclusion is actually saving.
    public var regenerableBytes: Int64 { thumbnailBytes + cacheBytes }

    /// The bytes that only exist here — originals, the database, snapshots.
    public var irreplaceableBytes: Int64 { blobBytes + databaseBytes + snapshotBytes }

    /// This tier's measured bytes.
    public func bytes(for tier: LibraryStorageTier) -> Int64 {
        switch tier {
        case .blobs: blobBytes
        case .thumbnails: thumbnailBytes
        case .cache: cacheBytes
        case .snapshots: snapshotBytes
        }
    }
}

// MARK: - Result

/// One completed scan: the per-tier totals plus the per-blob sizes the
/// largest-items list joins against.
///
/// `blobSizes` is the CACHE the 016 brief asks for: sizes are measured once,
/// here, and every row afterwards reads this dictionary. Nothing `stat`s a file
/// per render.
public struct LibraryStorageScan: Sendable, Equatable {
    public var usage: LibraryStorageUsage
    /// Content hash → the logical size of that blob's file on disk. A hash
    /// absent from this map has no file (deleted, or never downloaded).
    public var blobSizes: [String: Int64]
    /// When the measurement was taken — so the UI can say how stale it is.
    public var scannedAt: Date

    public init(usage: LibraryStorageUsage, blobSizes: [String: Int64], scannedAt: Date) {
        self.usage = usage
        self.blobSizes = blobSizes
        self.scannedAt = scannedAt
    }
}

// MARK: - Scanner

/// Measures a Library's disk footprint. `Sendable` — it wraps only a
/// ``LibraryLayout`` and holds no mutable state — so a caller runs it off the
/// main actor without ceremony.
public struct LibraryStorageScanner: Sendable {
    /// The Library being measured. Every path is derived from here: nothing in
    /// this file reaches the container directly (016 · C, multi-library seam).
    public let layout: LibraryLayout

    /// The database file's name under the layout root. A parameter rather than a
    /// constant so a test — or a second library — can name its own.
    public let databaseFileName: String

    public init(layout: LibraryLayout, databaseFileName: String = "library.sqlite") {
        self.layout = layout
        self.databaseFileName = databaseFileName
    }

    /// Measure the Library.
    ///
    /// - Parameters:
    ///   - now: the scan timestamp (injected so results are deterministic).
    ///   - isCancelled: polled once per file in BOTH phases, so a Stop during a
    ///     large library takes effect within one `stat` rather than at the end.
    ///   - onProgress: `0…1` over the files this scan has to size. Reported at
    ///     most once per whole percent — a per-file callback on a 200k-file
    ///     library would spend more time hopping actors than measuring.
    /// - Throws: `CancellationError` when `isCancelled` trips. It throws rather
    ///   than returning a partial result on purpose: a half-measured library is
    ///   a wrong number, and a wrong number displayed confidently is the failure
    ///   mode this whole feature exists to fix.
    public func scan(
        now: Date = Date(),
        isCancelled: @Sendable () -> Bool = { false },
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) throws -> LibraryStorageScan {
        // Phase 1 — the denominator. Collect every regular file per tier.
        var work: [(tier: LibraryStorageTier, url: URL)] = []
        for tier in LibraryStorageTier.allCases {
            for url in try regularFiles(under: directory(for: tier), isCancelled: isCancelled) {
                work.append((tier, url))
            }
        }

        // Phase 2 — the measurement.
        var usage = LibraryStorageUsage()
        usage.databaseBytes = SQLiteFileSet(
            base: layout.root.appendingPathComponent(databaseFileName)).totalByteSize()

        var blobSizes: [String: Int64] = [:]
        var lastPercent = -1
        let total = work.count
        for (index, item) in work.enumerated() {
            if isCancelled() { throw CancellationError() }

            // A file the enumerator saw but that is gone now (the user emptied
            // the Trash mid-scan) yields no size. Skip it — its bytes are no
            // longer on disk, so excluding it is the CORRECT total, not a
            // degraded one.
            if let bytes = Self.logicalByteSize(of: item.url) {
                switch item.tier {
                case .blobs:
                    usage.blobBytes += bytes
                    usage.blobFileCount += 1
                    // The hash is the filename stem, mirroring how
                    // `MediaStore.enumerateBlobFiles` recovers it (and how
                    // `storeBlob` wrote it). A stem-less file is not a blob.
                    let hash = item.url.deletingPathExtension().lastPathComponent
                    if !hash.isEmpty { blobSizes[hash] = bytes }
                case .thumbnails:
                    usage.thumbnailBytes += bytes
                    usage.thumbnailFileCount += 1
                case .cache:
                    usage.cacheBytes += bytes
                case .snapshots:
                    usage.snapshotBytes += bytes
                }
            }

            if total > 0 {
                let percent = Int(Double(index + 1) / Double(total) * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    onProgress(Double(index + 1) / Double(total))
                }
            }
        }
        onProgress(1)

        return LibraryStorageScan(usage: usage, blobSizes: blobSizes, scannedAt: now)
    }

    /// The directory backing `tier` — always through ``layout``.
    private func directory(for tier: LibraryStorageTier) -> URL {
        switch tier {
        case .blobs: layout.blobs
        case .thumbnails: layout.thumbnails
        case .cache: layout.cache
        case .snapshots: layout.snapshots
        }
    }

    /// Every regular file under `directory`, recursing shard directories. An
    /// absent directory is empty, not an error — a library that has never
    /// ingested anything has no `blobs/`.
    private func regularFiles(
        under directory: URL, isCancelled: @Sendable () -> Bool
    ) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if isCancelled() { throw CancellationError() }
            let isRegular = (try? url.resourceValues(
                forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular { files.append(url) }
        }
        return files
    }

    /// The file's logical size, or `nil` when it can't be read (gone, or
    /// unreadable). A FRESH `URL` value is used deliberately: URLs handed out by
    /// a directory enumerator carry CACHED resource values, and a cached size
    /// would report bytes for a file that has since been trashed.
    static func logicalByteSize(of url: URL) -> Int64? {
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(
            forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else { return nil }
        if let size = values.fileSize { return Int64(size) }
        // A file with no logical size but a real allocation (a sparse or
        // resource-fork oddity) still occupies disk; report what we have rather
        // than pretending it is free.
        if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
        return nil
    }
}
