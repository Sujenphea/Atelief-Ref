// AtelierCapture — content hashing (chunk 3, decision C5)
//
// **Why it is here and not in AtelierIngestion**, where it was written: the phone writes
// archives now (092 · S6), an archive's `blob_hash` IS this digest, and iOS cannot link
// that package. Hashing bytes is CryptoKit and Foundation — nothing about it was ever
// macOS — so it moves rather than being spelled a second time with its own chunk size and
// its own hex formatting, either of which could drift into producing a different address
// for the same bytes. `AtelierIngestion.ContentHasher` is now a typealias to this.
//
// That makes five types the AppKit boundary has pulled out of AtelierIngestion:
// `InboxLayout`, `LibraryLocation`, `LibraryMediaPaths`, the MIME→extension mapping, and
// this. The rule is stable: the ARITHMETIC lives where both processes can reach it.
//
// SHA-256 over the raw bytes of an asset, returned as a 64-char lowercased hex
// string — the `blob_hash` that content-addresses every blob and thumbnail.
// CryptoKit is a system framework (collision-safe, hardware-accelerated), and
// the URL variant streams the file through the incremental hasher in bounded
// chunks so a large input is never fully resident in memory (P13).
//
// The two entry points MUST agree bit-for-bit: hashing a `Data` value and
// streaming a file that holds those same bytes produce the identical digest.
// That is what lets the pipeline hash from either an in-memory paste or a
// dragged file and dedup them against each other.

import CryptoKit
import Foundation

/// SHA-256 content hashing for the ingestion pipeline (decision C5).
///
/// A stateless namespace: both members are `static`. Digests are formatted as
/// **lowercased** hex (`0-9a-f`), exactly 64 characters, matching the
/// `AppServices` "non-empty lowercased hex" validation and the ``MediaStore``
/// sharding scheme.
public enum ContentHasher {
    /// The chunk size for streamed hashing: 1 MiB. Large enough that syscall
    /// overhead is negligible, small enough that peak memory stays bounded
    /// regardless of file size.
    private static let streamChunkSize = 1 << 20  // 1 MiB

    /// SHA-256 of `data`, as a 64-char lowercased hex string.
    ///
    /// In-memory hash: the whole `Data` is already resident, so it is hashed in
    /// one shot. Produces the same digest as ``hash(contentsOf:)`` over a file
    /// holding identical bytes.
    public static func hash(_ data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// SHA-256 of the file at `url`, streamed in bounded chunks, as a 64-char
    /// lowercased hex string.
    ///
    /// The file is read through a `FileHandle` in ``streamChunkSize``-byte
    /// slices, each fed to an incremental `SHA256` hasher, so peak memory is a
    /// single chunk rather than the whole file. The handle is always closed,
    /// even on read failure. Throws any underlying file-IO error.
    ///
    /// Equivalent to `hash(_:)` of the file's bytes — streaming changes only the
    /// memory profile, never the digest.
    public static func hash(contentsOf url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: streamChunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    /// Format a finalized digest as a lowercased hex string (2 chars per byte).
    private static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
