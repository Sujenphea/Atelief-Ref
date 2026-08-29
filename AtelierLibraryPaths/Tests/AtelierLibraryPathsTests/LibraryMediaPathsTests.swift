// AtelierCapture tests — the media path math the phone reads through (092 · S5).
//
// `MediaStore` delegates to every member here, so these assertions are the store's
// path contract stated in the package the companion can link. What they pin is the
// shape a reader depends on: two-character shards, `@size` on the tier, the empty
// extension case, and the fallback that keeps URL computation non-throwing.
//
// The two tier constants are pinned SOMEWHERE ELSE — `ThumbnailTierAgreementTests` in
// AtelierIngestion — because this package cannot see `ThumbnailTier`. Asserting
// `gridThumbnailSize == 512` here would only assert that a literal equals itself.

import Foundation
import Testing

import AtelierLibraryPaths

@Suite("LibraryMediaPaths (092 S5)")
struct LibraryMediaPathsTests {
    /// A SHA-256-length lowercased-hex hash. Shards as `ab/cd`.
    static let hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    static let root = URL(fileURLWithPath: "/tmp/atelier-library", isDirectory: true)

    // MARK: - Directories

    @Test("blobs/ and thumbnails/ hang directly off the library root")
    func directories() {
        #expect(LibraryMediaPaths.blobs(inLibraryAt: Self.root).path
            == "/tmp/atelier-library/blobs")
        #expect(LibraryMediaPaths.thumbnails(inLibraryAt: Self.root).path
            == "/tmp/atelier-library/thumbnails")
    }

    // MARK: - Sharding

    @Test("shardComponents takes the first two characters, then the next two")
    func shardComponents() {
        let components = LibraryMediaPaths.shardComponents(for: Self.hash)
        #expect(components?.0 == "ab")
        #expect(components?.1 == "cd")
    }

    @Test("a hash shorter than four characters cannot be sharded")
    func shardComponentsTooShort() {
        #expect(LibraryMediaPaths.shardComponents(for: "abc") == nil)
        #expect(LibraryMediaPaths.shardComponents(for: "") == nil)
        // Exactly four is the boundary, and it is INSIDE.
        #expect(LibraryMediaPaths.shardComponents(for: "abcd") != nil)
    }

    @Test("shardDirectory nests the two components under the parent")
    func shardDirectory() {
        let parent = URL(fileURLWithPath: "/tmp/blobs", isDirectory: true)
        #expect(LibraryMediaPaths.shardDirectory(under: parent, hash: Self.hash)?.path
            == "/tmp/blobs/ab/cd")
        #expect(LibraryMediaPaths.shardDirectory(under: parent, hash: "abc") == nil)
    }

    // MARK: - File names

    @Test("a blob's file name is the hash plus the extension")
    func blobFileName() {
        #expect(LibraryMediaPaths.blobFileName(hash: "abcd", fileExtension: "jpg")
            == "abcd.jpg")
    }

    @Test("an empty extension yields no dot suffix")
    func emptyExtension() {
        #expect(LibraryMediaPaths.blobFileName(hash: "abcd", fileExtension: "") == "abcd")
        #expect(LibraryMediaPaths.thumbnailFileName(hash: "abcd", size: 512, fileExtension: "")
            == "abcd@512")
    }

    @Test("a thumbnail's file name carries its tier, so tiers are different files")
    func thumbnailFileName() {
        let medium = LibraryMediaPaths.thumbnailFileName(
            hash: "abcd", size: 512, fileExtension: "jpg")
        let large = LibraryMediaPaths.thumbnailFileName(
            hash: "abcd", size: 1280, fileExtension: "jpg")
        #expect(medium == "abcd@512.jpg")
        #expect(large == "abcd@1280.jpg")
        #expect(medium != large)
    }

    // MARK: - Full paths

    @Test("a blob resolves to blobs/ab/cd/<hash>.<ext> under the root")
    func blobURL() {
        let url = LibraryMediaPaths.blobURL(
            libraryRoot: Self.root, hash: Self.hash, fileExtension: "png")
        #expect(url.path == "/tmp/atelier-library/blobs/ab/cd/\(Self.hash).png")
    }

    @Test("a thumbnail resolves to thumbnails/ab/cd/<hash>@<size>.<ext> under the root")
    func thumbnailURL() {
        let url = LibraryMediaPaths.thumbnailURL(
            libraryRoot: Self.root, hash: Self.hash, size: 512, fileExtension: "jpg")
        #expect(url.path == "/tmp/atelier-library/thumbnails/ab/cd/\(Self.hash)@512.jpg")
    }

    @Test("the root form and the directory form compose the same path")
    func rootAndDirectoryFormsAgree() {
        let viaRoot = LibraryMediaPaths.thumbnailURL(
            libraryRoot: Self.root, hash: Self.hash, size: 1280, fileExtension: "jpg")
        let viaDirectory = LibraryMediaPaths.thumbnailURL(
            inThumbnailsDirectory: LibraryMediaPaths.thumbnails(inLibraryAt: Self.root),
            hash: Self.hash, size: 1280, fileExtension: "jpg")
        #expect(viaRoot == viaDirectory)
    }

    @Test("an unshardable hash falls back to the flat directory rather than failing")
    func unshardableFallsBackFlat() {
        // The reader finds out from the filesystem, which is where a missing file was
        // going to be found out anyway — so this must produce a URL, not a crash.
        let url = LibraryMediaPaths.blobURL(
            libraryRoot: Self.root, hash: "ab", fileExtension: "jpg")
        #expect(url.path == "/tmp/atelier-library/blobs/ab.jpg")
    }
}
