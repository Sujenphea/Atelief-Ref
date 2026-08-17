// AtelierIngestion — the two tiers the phone reads, pinned (092 · S5).
//
// `LibraryMediaPaths.gridThumbnailSize` and `.detailThumbnailSize` are integer
// literals in AtelierCapture, restated there because the companion cannot link this
// package and therefore cannot see ``ThumbnailTier``. A restated constant is a copy,
// and a copy with nothing checking it is the drift `Theme.NS` warns about — so this
// file, the ONE place that can see both, is the check.
//
// The failure it exists to catch is quiet: the phone asks for `<hash>@512.jpg`,
// nothing generates that tier any more, and the grid shows blank tiles for a library
// that is perfectly healthy. The generator and the reader must name the same integer,
// and a build is where that should be found out.

import Testing

import AtelierCapture
@testable import AtelierIngestion

@Suite("Thumbnail tier agreement (092 S5)")
struct ThumbnailTierAgreementTests {
    @Test("the phone's grid tier is ThumbnailTier.medium")
    func gridTier() {
        #expect(LibraryMediaPaths.gridThumbnailSize == ThumbnailTier.medium.rawValue)
    }

    @Test("the phone's detail tier is ThumbnailTier.large")
    func detailTier() {
        #expect(LibraryMediaPaths.detailThumbnailSize == ThumbnailTier.large.rawValue)
    }

    @Test("both tiers are actually generated at ingest")
    func tiersAreGenerated() {
        // A tier the phone reads but nothing writes resolves to a path that will never
        // exist. `allCases` is what the pipeline walks, so membership here is the
        // claim that the file gets made.
        let generated = Set(ThumbnailTier.allCases.map(\.rawValue))
        #expect(generated.contains(LibraryMediaPaths.gridThumbnailSize))
        #expect(generated.contains(LibraryMediaPaths.detailThumbnailSize))
    }

    @Test("MediaStore's paths are LibraryMediaPaths' paths")
    func storeDelegates() throws {
        // Delegation makes agreement structural rather than asserted, and this is the
        // line that says so: if someone re-inlines the path math into `MediaStore`,
        // this keeps passing only while the two stay identical.
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }
        let hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

        #expect(lib.store.blobURL(hash: hash, fileExtension: "jpg")
            == LibraryMediaPaths.blobURL(
                libraryRoot: lib.root, hash: hash, fileExtension: "jpg"))
        #expect(lib.store.thumbnailURL(
            hash: hash, size: LibraryMediaPaths.gridThumbnailSize, fileExtension: "jpg")
            == LibraryMediaPaths.thumbnailURL(
                libraryRoot: lib.root, hash: hash,
                size: LibraryMediaPaths.gridThumbnailSize, fileExtension: "jpg"))
    }
}
