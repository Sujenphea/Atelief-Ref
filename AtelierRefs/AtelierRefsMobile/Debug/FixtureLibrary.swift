// AtelierRefsMobile — a library a UI test can make assertions about.
//
// **Why this exists in the app rather than in the test.** A UI test runs in its own
// process with its own container; it cannot write into the app's. Browse is read-only by
// design (091 · D1) and has no verb it could call to make content. So something inside
// the app has to write the fixture, and this is the smallest thing that can: a debug-only
// seeding pass, gated by a launch argument, that runs before the library is opened.
//
// The precedent is two files over. `-atelier-log-tile-bodies` (`MasonryGridView.swift:86`)
// is already a launch argument this app reads to make a property observable from outside,
// and the Mac has a whole `Debug/` folder of the same kind (`BakeoffAutorun.swift`). This
// is that pattern with a stricter guard.
//
// **Three guards, and they are the point.** Seeding writes to a library, and a library is
// someone's collection of things they cannot get back:
//
//   1. `#if DEBUG` — the code is not in a Release build at all.
//   2. The launch argument has to be present.
//   3. **The library root must be an OVERRIDE** (`-library-root` / `ATELIER_LIBRARY_ROOT`,
//      `LibraryLocation.swift:194`). Against the default root this refuses and says so.
//      That is what makes "wipe the root first" safe: the only root it can ever wipe is a
//      throwaway one that a test named on the command line.
//
// It wipes rather than merges so a re-run asserts against the same library as the first
// run — a UI test that passes only on a clean simulator is a UI test that fails on
// someone's machine at the worst moment.

#if DEBUG

import AtelierCapture
import AtelierCore
import Foundation
import UIKit

enum FixtureLibrary {
    /// The launch argument that asks for a seeded library.
    static let argument = "-seed-fixture-library"

    static var isRequested: Bool {
        CommandLine.arguments.contains(argument)
    }

    /// What the fixture contains — named here so the UI tests can assert against these
    /// strings instead of re-spelling them, and so a change to the fixture breaks
    /// compilation rather than a test's expectations.
    enum Names {
        static let textures = "Textures"
        static let concrete = "Concrete"
        static let fabric = "Fabric"
        static let posters = "Posters"
        static let type = "Type"
        static let swatches = "Swatches"
        /// The item whose explicit cover must beat the recent-member fallback.
        static let posterCover = "P1"
        /// The newest member of Posters, which must therefore NOT be its row's picture.
        static let posterNewest = "P2"
    }

    /// Wipe `root` and write the fixture into it. Throws rather than seeding if the root
    /// is not an override — see the header's third guard.
    static func seed(at root: URL) async throws {
        guard LibraryLocation.overrideValue() != nil else {
            throw FixtureRefusal.notAThrowawayRoot
        }
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let services = try AppServices(
            databasePath: root.appendingPathComponent(AtelierCore.databaseFileName).path)
        var seed = 0

        // One byte-backed capture, with real tier files so the tile and the switcher row
        // have something to decode. The provenance title is what a tile's accessibility
        // label resolves to (`GridTile.swift:88`), which is how a test taps a KNOWN tile
        // rather than "the first one".
        @discardableResult
        func capture(into collection: UUID, label: String) async throws -> UUID {
            seed += 1
            let hash = String(format: "%064x", seed)
            let aspect = [0.72, 1.5, 1.0, 0.66, 1.33][seed % 5]
            try writeTiers(root: root, hash: hash, aspect: aspect, label: label)
            let width = aspect >= 1 ? 1600 : Int(1600 * aspect)
            let height = aspect >= 1 ? Int(1600 / aspect) : 1600
            let result = try await services.ingest(
                AssetDraft(
                    kind: .image, blobHash: hash, mimeType: "image/jpeg",
                    width: width, height: height, fileSize: 240_000,
                    downloadState: .downloaded),
                from: SourceDraft(
                    platform: .web, originalURL: "https://example.com/\(seed)",
                    authorName: "Ada Lovelace", title: label,
                    capturedAt: Date().addingTimeInterval(Double(seed) * -3600)),
                into: collection)
            return result.asset.id
        }

        let textures = try await services.createCollection(name: Names.textures)
        let concrete = try await services.createCollection(
            name: Names.concrete, parent: textures.id)
        // Deliberately empty and deliberately nested: a child row with no picture is the
        // one that proves the folder glyph keeps the indentation legible.
        _ = try await services.createCollection(name: Names.fabric, parent: textures.id)
        let posters = try await services.createCollection(name: Names.posters)
        _ = try await services.createCollection(name: Names.type)
        let swatches = try await services.createCollection(name: Names.swatches)

        var unsorted: [UUID] = []
        for index in 1...6 {
            unsorted.append(try await capture(into: Collection.unsortedID, label: "U\(index)"))
        }
        // A note on the first item, so its detail screen has a "Details" section at all —
        // that section is omitted when there is nothing in it
        // (`ItemDetailScreen.swift:109`), which would otherwise make "the three 041
        // sections are there, in order" untestable on a freshly captured asset. A NOTE
        // and not a name: a name would replace the tile's accessibility label, which is
        // how the UI test finds a known tile to tap.
        if let first = unsorted.first {
            try await services.setNote("A note the detail screen has to show", for: first)
        }
        for index in 1...3 { try await capture(into: textures.id, label: "T\(index)") }
        for index in 1...2 { try await capture(into: concrete.id, label: "C\(index)") }

        // Posters: an explicit cover that is NOT the newest member, so a row showing P2
        // means the fallback has overtaken a cover the user chose.
        let cover = try await capture(into: posters.id, label: Names.posterCover)
        try await capture(into: posters.id, label: Names.posterNewest)
        try await services.setCollectionCover(collectionID: posters.id, assetID: cover)

        // A member with no bytes: the row must still draw a folder.
        _ = try await services.ingestContent(
            AssetContentDraft.color(hex: "#B4472A"),
            from: SourceDraft(platform: .localPaste, capturedAt: Date()),
            into: swatches.id)
    }

    /// Both display tiers for one fixture asset, drawn rather than shipped — a bundled
    /// JPEG would be a resource to keep in sync with a hash computed here.
    private static func writeTiers(
        root: URL, hash: String, aspect: Double, label: String
    ) throws {
        for tier in [LibraryMediaPaths.gridThumbnailSize, LibraryMediaPaths.detailThumbnailSize] {
            let size = CGSize(
                width: aspect >= 1 ? tier : Int(Double(tier) * aspect),
                height: aspect >= 1 ? Int(Double(tier) / aspect) : tier)
            let url = LibraryMediaPaths.thumbnailURL(
                libraryRoot: root, hash: hash, size: tier, fileExtension: "jpg")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg(size: size, label: label).write(to: url)
        }
    }

    private static func jpeg(size: CGSize, label: String) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.jpegData(withCompressionQuality: 0.85) { context in
            // A hue per label so a human reading a failure screenshot can tell the tiles
            // apart, and the label drawn on the tile so they can name the one that is
            // wrong.
            let hue = CGFloat(abs(label.hashValue % 100)) / 100
            UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: min(size.width, size.height) * 0.34),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
            let text = label as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(
                    x: (size.width - textSize.width) / 2,
                    y: (size.height - textSize.height) / 2),
                withAttributes: attributes)
        }
    }

    enum FixtureRefusal: Error {
        /// The library root is the real one. Seeding would wipe it.
        case notAThrowawayRoot
    }
}

#endif
