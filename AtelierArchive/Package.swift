// swift-tools-version: 6.0
//
// AtelierArchive — the portable library archive (008 · H6/H7, 092 · S6).
//
// **Why this is a package and not app-target code any more.** The archive format was
// written for the Mac's backup and export lanes and lived in `AtelierRefs/`, which the
// phone cannot link. 092 · S6 makes the phone a PRODUCER of archives — it writes what it
// captured, the Mac absorbs it — and a format with two producers is exactly the situation
// `AtelierCapture` was extracted for in S0. So the manifest, its writer, its reader and
// the export naming rule move here, once, rather than being spelled a second time on iOS
// where the two copies would drift and nothing would notice.
//
// **What it deliberately does NOT depend on: `AtelierIngestion`.** The writer took a
// `MediaStore` for one thing — resolving a blob's path — and that package was macOS-only
// when this was written (`Input/DirectInputReader.swift` imported AppKit), so depending
// on it would have made this package macOS-only too, for a path join. It is no longer
// macOS-only (`.change-log/452`), and the dependency is still not worth taking: this is
// a leaf that joins strings, and it should not pull in an ingest pipeline to do it.
// `AtelierLibraryPaths.LibraryMediaPaths` already computes that path on both platforms
// (it lived in AtelierCapture until 096 review 4A); it is the same move S4a made when
// the drain needed the phone to know where blobs live. AtelierCapture is still linked,
// for the inbox half: `InboxArchive` reads `InboxRecord`s through `InboxLayout` and
// decodes them through `CaptureDecoder`.

import PackageDescription

let package = Package(
    name: "AtelierArchive",
    // Both platforms, and that is the entire point of the package existing.
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "AtelierArchive", targets: ["AtelierArchive"])
    ],
    dependencies: [
        .package(path: "../AtelierCore"),
        .package(path: "../AtelierCapture"),
        .package(path: "../AtelierLibraryPaths"),
    ],
    targets: [
        .target(
            name: "AtelierArchive",
            dependencies: [
                .product(name: "AtelierCore", package: "AtelierCore"),
                .product(name: "AtelierCapture", package: "AtelierCapture"),
                .product(name: "AtelierLibraryPaths", package: "AtelierLibraryPaths"),
            ]),
        .testTarget(
            name: "AtelierArchiveTests",
            dependencies: [
                "AtelierArchive",
                .product(name: "AtelierCore", package: "AtelierCore"),
                .product(name: "AtelierCapture", package: "AtelierCapture"),
                .product(name: "AtelierLibraryPaths", package: "AtelierLibraryPaths"),
                // The shared fixtures (457): the JPEG builder the inbox-archive suite
                // had copied verbatim, the temp-root maker, and the retention fixture
                // that executes the drain's own move order.
                .product(name: "AtelierCaptureTestSupport", package: "AtelierCapture"),
            ],
            // 12A. The importers this package will grow (Eagle, Raindrop,
            // Pinterest) parse files written by OTHER programs, and a parser
            // tested only against JSON the test itself composed is a parser
            // tested against the author's belief about the format. Committed
            // fixtures are how a real export gets into the suite. `.copy` (not
            // `.process`) so the bytes reach the bundle unchanged — a fixture
            // whose whitespace or key order a resource pipeline "helpfully"
            // rewrote would no longer be the file the exporter produced.
            //
            // The whole directory is copied, so adding a fixture needs no edit
            // here. `TestSupport/Fixture.swift` is the only reader.
            resources: [.copy("Fixtures")]),
    ]
)
