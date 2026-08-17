// AtelierCapture — where a blob and a thumbnail sit inside a library (092 · S5)
//
// Pure, read-only path math over a library root: the `blobs/` and `thumbnails/`
// directory names, the two-level hash sharding, and the file names a blob and a
// thumbnail tier take. It creates nothing and reads nothing — it is arithmetic over
// strings and URLs.
//
// **Why it is here and not in AtelierIngestion**, which owns `MediaStore` and wrote
// every one of these paths first: the iOS companion's browse surface has to resolve a
// thumbnail for a row it just read out of the database, and it cannot link
// AtelierIngestion. That package imports AppKit (`Input/DirectInputReader.swift`) and
// does not build for iOS — and unlike the AppKit residue `LibraryLocation` left
// behind, this one does not come out with a single `#if`: `InboxDrain` and
// `RemoteImageFetcher` both call `DirectInputReader`, so excluding the file on iOS
// takes the drain with it. Porting the package is a separately-costed decision the CI
// job already says it is; this slice does not make it.
//
// So the same move `InboxLayout` made in S2 and `LibraryLocation` made in S4a happens
// a third time, for the same reason and with the same shape: the NAME lives in the
// package both processes can link, and `MediaStore` / `LibraryLayout` delegate to it
// rather than spelling it a second time. One authority, reached from both sides. The
// AppKit boundary has now pulled a type out of AtelierIngestion three times, which is
// worth saying out loud: it is a pattern, not a coincidence.
//
// **What is deliberately NOT here:** anything that writes. The store's atomic staging,
// its `cache/` volume rule, its Trash removals and its `StoreError` all stay in
// `MediaStore`, because the phone is a reader (091 · D1) and a writer's machinery
// carried across a process boundary is machinery that can be called by mistake.

import Foundation
import UniformTypeIdentifiers

/// The library's content-addressed media paths — a namespace, `static` only.
///
/// Addresses are derived purely from a content `hash`: the first two hex characters
/// form the first shard directory and the next two the second (`abcd…` →
/// `ab/cd/abcd….ext`), so identical bytes always resolve to the same file and no
/// single directory grows unbounded. `fileExtension` is an opaque caller-supplied
/// string; an empty one yields no dot suffix.
public enum LibraryMediaPaths {
    // MARK: - Directory names

    /// Content-addressed original media, under the library root.
    public static let blobsDirectoryName = "blobs"

    /// Derived, regenerable thumbnails, under the library root.
    public static let thumbnailsDirectoryName = "thumbnails"

    /// `<root>/blobs/`.
    public static func blobs(inLibraryAt root: URL) -> URL {
        root.appendingPathComponent(blobsDirectoryName, isDirectory: true)
    }

    /// `<root>/thumbnails/`.
    public static func thumbnails(inLibraryAt root: URL) -> URL {
        root.appendingPathComponent(thumbnailsDirectoryName, isDirectory: true)
    }

    // MARK: - Tiers the companion reads

    /// The tier the phone's grid draws — `ThumbnailTier.medium`'s raw value.
    ///
    /// Restated rather than imported, for the reason in this file's header, and
    /// therefore pinned: `ThumbnailTierAgreementTests` in AtelierIngestion — the one
    /// place that can see both — fails if the enum and this constant ever disagree.
    public static let gridThumbnailSize = 512

    /// The tier the phone's item detail draws — `ThumbnailTier.large`'s raw value, and
    /// pinned by the same test.
    ///
    /// **The detail screen reads a thumbnail, not the original blob**, and that is a
    /// decision rather than an oversight. 1280 px covers a phone screen at 3× with
    /// room to spare, the tier is already display-oriented (the EXIF transform is baked
    /// in at generation), and reading the original would mean decoding a 4000 px
    /// capture into a process that 091 · D2 spends its whole argument keeping under a
    /// memory ceiling. v1 browse never opens `blobs/`.
    public static let detailThumbnailSize = 1280

    // MARK: - Sharding

    /// The two shard directory components for `hash`: the first two characters, then
    /// the next two (`"abcdef…"` → `("ab", "cd")`). `nil` for a hash shorter than 4
    /// characters — a real content hash (a SHA-256 is 64 lowercased hex characters)
    /// always satisfies this, so `nil` means caller misuse.
    public static func shardComponents(for hash: String) -> (String, String)? {
        guard hash.count >= 4 else { return nil }
        let characters = Array(hash)
        return (String(characters[0 ..< 2]), String(characters[2 ..< 4]))
    }

    /// The sharded directory under `parent` for `hash` (`parent/ab/cd`), or `nil` when
    /// the hash is too short to shard.
    public static func shardDirectory(under parent: URL, hash: String) -> URL? {
        guard let (first, second) = shardComponents(for: hash) else { return nil }
        return parent
            .appendingPathComponent(first, isDirectory: true)
            .appendingPathComponent(second, isDirectory: true)
    }

    // MARK: - File names

    /// The canonical file extension for a MIME type — `image/jpeg` → `jpeg` — or `""`
    /// for one the system cannot resolve.
    ///
    /// **The other half of every path above.** A blob is stored under the extension the
    /// ingest derived, and every later reader has to map the same MIME back to the same
    /// extension or it computes a path to a file that is not there. That made this
    /// mapping part of the path math, so it belongs beside it — and it has to be HERE
    /// rather than in `AtelierIngestion.ImageMetadata`, where it was, because iOS cannot
    /// link that package (`Input/DirectInputReader.swift` imports AppKit) and 092 · S6
    /// makes the phone a writer of archives, which resolve blob paths.
    ///
    /// `ImageMetadata.fileExtension(forMIMEType:)` now delegates here rather than being
    /// a second copy — the same arrangement `LibraryLayout.inbox` has with
    /// ``InboxLayout``, and for the same reason.
    ///
    /// Both directions resolve the one canonical `UTType`, so the round trip is exact.
    public static func fileExtension(forMIMEType mimeType: String) -> String {
        UTType(mimeType: mimeType)?.preferredFilenameExtension ?? ""
    }

    /// A blob's file name: `<hash>`, with `.<ext>` appended only for a non-empty
    /// `fileExtension`.
    public static func blobFileName(hash: String, fileExtension: String) -> String {
        appendingExtension(fileExtension, to: hash)
    }

    /// A thumbnail tier's file name: `<hash>@<size>`, with `.<ext>` appended only for a
    /// non-empty `fileExtension`.
    public static func thumbnailFileName(
        hash: String, size: Int, fileExtension: String
    ) -> String {
        appendingExtension(fileExtension, to: "\(hash)@\(size)")
    }

    /// Append `.ext` to `base`, or return `base` unchanged for an empty extension.
    private static func appendingExtension(_ fileExtension: String, to base: String) -> String {
        fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
    }

    // MARK: - Full paths

    /// `<blobs>/ab/cd/<hash>.<ext>`. An unshardable hash falls back to the flat
    /// directory rather than throwing, so a path is always produced — the caller finds
    /// out from the filesystem, which is where a missing file was going to be found out
    /// anyway.
    public static func blobURL(
        inBlobsDirectory blobs: URL, hash: String, fileExtension: String
    ) -> URL {
        (shardDirectory(under: blobs, hash: hash) ?? blobs)
            .appendingPathComponent(blobFileName(hash: hash, fileExtension: fileExtension))
    }

    /// `<thumbnails>/ab/cd/<hash>@<size>.<ext>`. Different `size` values are different
    /// files; same fallback rule as ``blobURL(inBlobsDirectory:hash:fileExtension:)``.
    public static func thumbnailURL(
        inThumbnailsDirectory thumbnails: URL, hash: String, size: Int, fileExtension: String
    ) -> URL {
        (shardDirectory(under: thumbnails, hash: hash) ?? thumbnails)
            .appendingPathComponent(
                thumbnailFileName(hash: hash, size: size, fileExtension: fileExtension))
    }

    /// ``blobURL(inBlobsDirectory:hash:fileExtension:)`` resolved from a library root.
    public static func blobURL(
        libraryRoot root: URL, hash: String, fileExtension: String
    ) -> URL {
        blobURL(
            inBlobsDirectory: blobs(inLibraryAt: root), hash: hash,
            fileExtension: fileExtension)
    }

    /// ``thumbnailURL(inThumbnailsDirectory:hash:size:fileExtension:)`` resolved from a
    /// library root.
    public static func thumbnailURL(
        libraryRoot root: URL, hash: String, size: Int, fileExtension: String
    ) -> URL {
        thumbnailURL(
            inThumbnailsDirectory: thumbnails(inLibraryAt: root), hash: hash, size: size,
            fileExtension: fileExtension)
    }
}
