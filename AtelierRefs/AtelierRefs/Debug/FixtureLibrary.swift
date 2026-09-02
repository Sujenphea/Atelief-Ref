// AtelierRefs — a library a macOS UI test can make assertions about (099 · P2).
//
// **The sibling of `AtelierRefsMobile/Debug/FixtureLibrary.swift`, deliberately.** 098
// built the phone's seeder first and argued its shape; this is that shape with the Mac's
// own fixture set. It is a sibling and not a shared file because the two libraries differ
// in what they have to contain: a Space and a saved search have no surface on the phone
// (092 · S6), and the phone's pending-capture inbox has none here — macOS has no share
// extension to fill one. What IS shared is the argument name, the three guards and the
// `Names` discipline, and those are the parts a second spelling would have cost us.
//
// **Why this is in the app rather than in the test.** A UI test runs in its own process
// with its own container; it cannot write into the app's. So something inside the app has
// to write the fixture, and this is the smallest thing that can: a debug-only seeding pass
// that runs inside `IngestionModel.bootstrap()` after the root is resolved and before the
// database is opened.
//
// **Three guards, and they are the point.** Seeding wipes a library, and a library is
// someone's collection of things they cannot get back:
//
//   1. `#if DEBUG` — the code is not in a Release build at all.
//   2. The launch argument has to be present.
//   3. **The library root must be an OVERRIDE** (`-library-root` / `ATELIER_LIBRARY_ROOT`,
//      `LibraryLocation.swift`). Against the default root this refuses and says so. That
//      is what makes "wipe the root first" safe: the only root it can ever wipe is a
//      throwaway one that a test named.
//
// On macOS the UI test names it through **`ATELIER_LIBRARY_ROOT`**, not `-library-root`:
// 099 · 8A left the argument arm DEBUG-only and the environment arm unconditional, and
// ``LibraryLocation/overrideEnvironmentKey``'s own doc comment names this target as the
// reason. The value is RELATIVE (`uitest-fixture`), so it resolves inside the sandboxed
// app's own Application Support container — an absolute path is not writable from there.
//
// It wipes rather than merges so a re-run asserts against the same library as the first
// run — a UI test that passes only on a clean machine is a UI test that fails on someone
// else's at the worst moment.

#if DEBUG

import AppKit
import AtelierCore
import AtelierLibraryPaths
import Foundation

enum FixtureLibrary {
    /// The launch argument that asks for a seeded library. **The same spelling the phone
    /// uses** (`AtelierRefsMobile/Debug/FixtureLibrary.swift`) — one job, one name.
    static let argument = "-seed-fixture-library"

    static var isRequested: Bool {
        CommandLine.arguments.contains(argument)
    }

    /// What the fixture contains — named here so the UI tests' expectations and the
    /// seeder cannot drift apart silently, and so a change to the fixture breaks
    /// compilation on this side rather than only an expectation on the other.
    ///
    /// The UI-test bundle is a separate module and cannot import these (it is a second
    /// process against a shipped app, not a `@testable import`), so `AtelierRefsUITests`
    /// re-spells them in its own `Fixture` enum and a comment on each side names the
    /// other. That is the same seam 098 lived with on the phone.
    enum Names {
        /// The protected root every library is born with (`Migrator`'s seed row). Named
        /// here because the sidebar-order assertion has to spell it: it is pinned FIRST,
        /// ahead of everything this fixture creates.
        static let unsorted = "Unsorted"
        /// A root collection, created first, so it sorts ahead of ``posters``.
        static let textures = "Textures"
        /// ``textures``' child — the nested one. Invisible until its parent is expanded,
        /// which is exactly the thing the sidebar flow has to drive.
        static let concrete = "Concrete"
        /// The second root collection, created after ``textures``.
        static let posters = "Posters"
        /// The one Space. It has no phone surface, which is why this seeder is a sibling
        /// rather than a shared file.
        static let space = "Moodboard"
        /// The one saved search. Nothing renders it yet — the sidebar's Smart section is
        /// 099 · P4 — so it is seeded and unasserted on purpose: P4 inherits a fixture
        /// that already contains the row it will have to draw.
        static let savedSearch = "Warm Tones"
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

        // One byte-backed capture, with real tier files so a card's fan and a grid tile
        // have something to decode. A capture rather than a colour swatch because the
        // Home card counts items and draws a pile, and an empty pile is the state the
        // fixture is meant to move past.
        @discardableResult
        func capture(into collection: UUID, label: String) async throws -> UUID {
            seed += 1
            let hash = String(format: "%064x", seed)
            let aspect = [0.72, 1.5, 1.0, 0.66][seed % 4]
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

        // Three collections, one nested. Creation ORDER is the fixture's ordering
        // contract: `createCollection` appends (`sortIndex = siblings.count`) and
        // `BrowseCollectionTree.roots` pins Unsorted and then sorts by that index — so
        // the sidebar reads Unsorted, Textures, (Concrete), Posters, and the test asserts
        // exactly that. Rename them and the order assertion is what tells you.
        let textures = try await services.createCollection(name: Names.textures)
        let concrete = try await services.createCollection(
            name: Names.concrete, parent: textures.id)
        let posters = try await services.createCollection(name: Names.posters)

        // Four assets, spread so that every seeded collection has a non-zero count and
        // Unsorted has one too — a Home card that says "0 items" everywhere cannot tell
        // an empty library from a library that failed to load.
        try await capture(into: Collection.unsortedID, label: "U1")
        try await capture(into: textures.id, label: "T1")
        try await capture(into: concrete.id, label: "C1")
        let cover = try await capture(into: posters.id, label: "P1")
        try await services.setCollectionCover(collectionID: posters.id, assetID: cover)

        // One Space. Empty: the flows this phase writes never open a board, and a board
        // with placements would make the fixture assert things nothing reads yet.
        _ = try await services.createSpace(name: Names.space)

        // One saved search. Seeded ahead of the surface that shows it (099 · P4).
        _ = try await services.createSavedSearch(
            name: Names.savedSearch, rules: SearchRules(text: "poster"))
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

    /// A flat coloured tile with its label drawn on it.
    ///
    /// Straight to an `NSBitmapImageRep` rather than through `NSImage.lockFocus()`: the
    /// focus-stack API is soft-deprecated, and a bitmap rep is what the JPEG encoder
    /// wants anyway. A hue per label so a human reading a failure screenshot can tell the
    /// tiles apart, and the label drawn on it so they can name the one that is wrong.
    private static func jpeg(size: CGSize, label: String) throws -> Data {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw FixtureRefusal.couldNotDrawTile }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let hue = CGFloat(abs(label.hashValue % 100)) / 100
        NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
        NSBezierPath.fill(CGRect(origin: .zero, size: size))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: min(size.width, size.height) * 0.34),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2),
            withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { throw FixtureRefusal.couldNotDrawTile }
        return data
    }

    enum FixtureRefusal: Error {
        /// The library root is the real one. Seeding would wipe it.
        case notAThrowawayRoot
        /// A fixture tile could not be rasterised — no bitmap context, or no JPEG out of
        /// it. Thrown rather than silently written as zero bytes, which would surface
        /// later as an unreadable thumbnail and read as an app bug.
        case couldNotDrawTile
    }
}

#endif
