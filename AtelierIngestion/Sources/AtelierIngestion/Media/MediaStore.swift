// AtelierIngestion — the content-addressed media store (chunk 2, decisions C6 / A2)
//
// A pure file/bytes layer over a `LibraryLayout`: it turns a caller-supplied
// content hash + file extension into a deterministic, sharded path under
// `blobs/` (or `thumbnails/`), and reads/writes `Data` there with ATOMIC,
// IDEMPOTENT semantics.
//
// The A2 invariant this exists to uphold: **a blob file that exists is complete
// and valid**. That is what lets the pipeline treat "path exists" as "already
// ingested" and short-circuit. To guarantee it, every write stages bytes in a
// unique temp file in `cache/` (same volume) and atomically renames it into
// place — a crash mid-write leaves at most a stray temp file, never a partial
// blob.
//
// This layer knows NOTHING about images, mime types, or hashing. `hash` is an
// opaque lowercased-hex string and `fileExtension` is an opaque string the
// caller supplies; the store only does path math and byte IO.

import Foundation

/// A content-addressed, sharded, atomic + idempotent file store for blobs and
/// thumbnails.
///
/// Addresses are derived purely from a caller-supplied content `hash`: the
/// first two hex chars form the first shard directory, the next two the second
/// (`abcd…` → `ab/cd/abcd….ext`), keeping any single directory from growing
/// unbounded. Because paths are content-derived, identical bytes always map to
/// the same file, which is what makes stores idempotent and gives free dedup.
///
/// `struct … Sendable` — the only stored property is a `Sendable`
/// ``LibraryLayout``, and the store holds no mutable in-memory state; all
/// durability lives in the filesystem.
public struct MediaStore: Sendable {
    /// The directory layout this store reads and writes through.
    public let layout: LibraryLayout

    /// Build a store over an explicit ``LibraryLayout``.
    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    /// Build a store rooted at `root` (convenience over ``LibraryLayout``).
    public init(root: URL) {
        self.init(layout: LibraryLayout(root: root))
    }

    // MARK: - Backup hygiene (008 H2)

    /// Mark the derived directories (`thumbnails/`, `cache/`) excluded from
    /// backups — fulfilling the layout's long-standing doc-comment promise. They
    /// hold only regenerable data, so Time Machine / iCloud shouldn't copy them
    /// (smaller footprint, faster backups). The originals in `blobs/`, the
    /// database, and `snapshots/` are deliberately NOT excluded. Each directory
    /// is created first (the flag needs an existing URL); a per-directory failure
    /// is swallowed — this is hygiene, not correctness.
    public func excludeDerivedFromBackup() {
        for directory in [layout.thumbnails, layout.cache] {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    // MARK: - Errors

    /// A failure raised by the store itself (as opposed to an underlying
    /// `FileManager`/IO error, which is rethrown as-is).
    public enum StoreError: Error, Equatable {
        /// The content hash was too short to shard (needs ≥ 4 hex chars).
        case invalidHash(String)
    }

    // MARK: - Sharding

    /// The two shard directory components for `hash`: first two hex chars, then
    /// the next two (`"abcdef…"` → `("ab", "cd")`).
    ///
    /// Throws ``StoreError/invalidHash(_:)`` if `hash` has fewer than 4
    /// characters — a real content hash (a SHA-256 is 64 lowercased hex chars)
    /// always satisfies this; the guard only trips on caller misuse.
    func shardComponents(for hash: String) throws -> (String, String) {
        guard hash.count >= 4 else { throw StoreError.invalidHash(hash) }
        let chars = Array(hash)
        let first = String(chars[0 ..< 2])
        let second = String(chars[2 ..< 4])
        return (first, second)
    }

    /// The file name for a blob: `<hash>` with `.<ext>` appended only when
    /// `fileExtension` is non-empty (empty ⇒ no dot suffix).
    private func blobFileName(hash: String, fileExtension: String) -> String {
        appendingExtension(fileExtension, to: hash)
    }

    /// The file name for a thumbnail tier: `<hash>@<size>` with `.<ext>`
    /// appended only when `fileExtension` is non-empty.
    private func thumbnailFileName(hash: String, size: Int, fileExtension: String) -> String {
        appendingExtension(fileExtension, to: "\(hash)@\(size)")
    }

    /// Append `.ext` to `base`, or return `base` unchanged for an empty ext.
    private func appendingExtension(_ fileExtension: String, to base: String) -> String {
        fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
    }

    /// The sharded directory under `parent` for `hash` (`parent/ab/cd`).
    private func shardDirectory(under parent: URL, hash: String) throws -> URL {
        let (first, second) = try shardComponents(for: hash)
        return parent
            .appendingPathComponent(first, isDirectory: true)
            .appendingPathComponent(second, isDirectory: true)
    }

    // MARK: - Blobs

    /// The deterministic content-addressed path for a blob:
    /// `blobs/ab/cd/<hash>.<ext>` (no dot suffix for an empty `fileExtension`).
    ///
    /// Pure path math — computing the URL neither creates the file nor its shard
    /// directories, and does not require the hash to be a real content hash.
    public func blobURL(hash: String, fileExtension: String) -> URL {
        // A short/invalid hash cannot be sharded; fall back to a flat path under
        // `blobs/` so URL computation stays non-throwing. Store/read still guard.
        let dir = (try? shardDirectory(under: layout.blobs, hash: hash)) ?? layout.blobs
        return dir.appendingPathComponent(blobFileName(hash: hash, fileExtension: fileExtension))
    }

    /// Whether the blob for `(hash, fileExtension)` already exists on disk.
    ///
    /// This is the pipeline's hash-first short-circuit (P14): because a blob
    /// that exists is complete (A2), a `true` here means "already stored".
    public func hasBlob(hash: String, fileExtension: String) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(hash: hash, fileExtension: fileExtension).path)
    }

    /// Atomically and idempotently store `data` as the blob for `(hash, ext)`,
    /// returning the final content-addressed URL.
    ///
    /// Idempotent: if the destination already exists it is returned unchanged
    /// (content-addressing ⇒ identical bytes), without rewriting. See
    /// ``atomicWrite(_:to:)`` for the atomicity + concurrent-race guarantees.
    @discardableResult
    public func storeBlob(_ data: Data, hash: String, fileExtension: String) throws -> URL {
        let destination = blobURL(hash: hash, fileExtension: fileExtension)
        let directory = try shardDirectory(under: layout.blobs, hash: hash)
        return try atomicWrite(data, to: destination, shardDirectory: directory)
    }

    /// Read the bytes of the blob for `(hash, fileExtension)`. Throws if absent.
    public func readBlob(hash: String, fileExtension: String) throws -> Data {
        try Data(contentsOf: blobURL(hash: hash, fileExtension: fileExtension))
    }

    /// Every stored blob as `(hash, fileExtension)`, by walking
    /// `blobs/ab/cd/<hash>.<ext>` (010 · delete-undo launch GC). The hash is the
    /// filename stem (everything before the extension); directories and any file
    /// without a stem are skipped. Pure filesystem read — creates nothing.
    public func enumerateBlobFiles() -> [(hash: String, fileExtension: String)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: layout.blobs, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [(hash: String, fileExtension: String)] = []
        for case let url as URL in walker {
            let isRegular = (try? url.resourceValues(
                forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            let ext = url.pathExtension
            let name = url.lastPathComponent
            let hash = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            guard !hash.isEmpty else { continue }
            result.append((hash: hash, fileExtension: ext))
        }
        return result
    }

    // MARK: - Thumbnails

    /// The deterministic content-addressed path for a thumbnail tier:
    /// `thumbnails/ab/cd/<hash>@<size>.<ext>`. Different `size` values yield
    /// different paths. Pure path math — creates nothing.
    public func thumbnailURL(hash: String, size: Int, fileExtension: String) -> URL {
        let dir = (try? shardDirectory(under: layout.thumbnails, hash: hash)) ?? layout.thumbnails
        return dir.appendingPathComponent(
            thumbnailFileName(hash: hash, size: size, fileExtension: fileExtension))
    }

    /// Whether the thumbnail for `(hash, size, fileExtension)` already exists.
    public func hasThumbnail(hash: String, size: Int, fileExtension: String) -> Bool {
        FileManager.default.fileExists(
            atPath: thumbnailURL(hash: hash, size: size, fileExtension: fileExtension).path)
    }

    /// Atomically and idempotently store `data` as the thumbnail tier for
    /// `(hash, size, ext)`, returning the final URL. Same semantics as
    /// ``storeBlob(_:hash:fileExtension:)``.
    @discardableResult
    public func storeThumbnail(
        _ data: Data, hash: String, size: Int, fileExtension: String
    ) throws -> URL {
        let destination = thumbnailURL(hash: hash, size: size, fileExtension: fileExtension)
        let directory = try shardDirectory(under: layout.thumbnails, hash: hash)
        return try atomicWrite(data, to: destination, shardDirectory: directory)
    }

    /// Read the bytes of the thumbnail for `(hash, size, ext)`. Throws if absent.
    public func readThumbnail(hash: String, size: Int, fileExtension: String) throws -> Data {
        try Data(contentsOf: thumbnailURL(hash: hash, size: size, fileExtension: fileExtension))
    }

    // MARK: - Removal (move to Trash)

    /// Move the blob for `(hash, fileExtension)` to the user's Trash, returning
    /// its new Trash location (or `nil` if the file didn't exist). IDEMPOTENT:
    /// an already-absent blob is a no-op, not an error. Trash (not a hard delete)
    /// so the media stays recoverable after a delete. Path math mirrors
    /// ``blobURL(hash:fileExtension:)`` exactly, so it reclaims the same file
    /// ``storeBlob(_:hash:fileExtension:)`` wrote.
    @discardableResult
    public func removeBlob(hash: String, fileExtension: String) throws -> URL? {
        try trash(blobURL(hash: hash, fileExtension: fileExtension))
    }

    /// Move the thumbnail tier for `(hash, size, fileExtension)` to the Trash,
    /// returning its new Trash location (or `nil` if absent). Idempotent — same
    /// semantics as ``removeBlob(hash:fileExtension:)``.
    @discardableResult
    public func removeThumbnail(
        hash: String, size: Int, fileExtension: String
    ) throws -> URL? {
        try trash(thumbnailURL(hash: hash, size: size, fileExtension: fileExtension))
    }

    /// Move `url` to the Trash, returning the resulting Trash URL, or `nil` when
    /// the file is already absent (idempotent no-op). Any real IO failure is
    /// rethrown. Uses `trashItem` rather than `removeItem` so the bytes remain
    /// recoverable; the file lives under the app's own Library root, which the
    /// app can always move.
    private func trash(_ url: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        var resultingURL: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    // MARK: - Atomic + idempotent write

    /// Write `data` to `destination` atomically and idempotently.
    ///
    /// The sequence, and why each step matters for the A2 invariant:
    /// 1. **Idempotent no-op.** If `destination` already exists, return it
    ///    immediately without rewriting — content-addressing guarantees the
    ///    bytes on disk are the bytes we would write.
    /// 2. **Stage on the same volume.** Ensure `shardDirectory` exists, then
    ///    write `data` to a UNIQUE temp file (a `UUID` name) inside `cache/`.
    ///    `cache/` lives under the same Library root as the destination, so the
    ///    following move is a metadata-only rename, not a copy — the rename is
    ///    what makes the appearance of `destination` atomic (readers never see a
    ///    half-written file).
    /// 3. **Atomic rename into place** via `FileManager.moveItem(at:to:)`.
    /// 4. **Concurrent-race catch.** If the move fails only because
    ///    `destination` now exists — a concurrent writer of the same bytes won
    ///    the race — delete our temp file and treat it as success (return
    ///    `destination`); the winner's bytes are, by content-addressing, ours.
    ///    Any OTHER error: delete the temp file (never leak it), then rethrow.
    ///
    /// Net guarantee: the content-addressed path only ever holds COMPLETE bytes;
    /// a crash mid-write leaves at most a harmless stray temp file in `cache/`.
    private func atomicWrite(_ data: Data, to destination: URL, shardDirectory directory: URL) throws -> URL {
        let fm = FileManager.default

        // 1. Idempotent no-op: an existing content-addressed file is complete.
        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        // 2. Ensure the shard dir and the cache staging dir exist, then write to
        //    a unique temp file on the same volume as `destination`.
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.cache, withIntermediateDirectories: true)
        let tempURL = layout.cache.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL, options: .atomic)

        // 3. Atomic rename into place, with the 4. concurrent-race catch.
        do {
            try fm.moveItem(at: tempURL, to: destination)
            return destination
        } catch {
            // A concurrent writer of identical bytes may have created the
            // destination between our step-1 check and this move. That is
            // success, not failure: clean up our temp file and return the path.
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: tempURL)
                return destination
            }
            // Any other failure: never leak the temp file, then surface it.
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }
}
