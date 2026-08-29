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
// `MediaStore` for one thing — resolving a blob's path — and that package is macOS-only
// (`Input/DirectInputReader.swift` imports AppKit), so depending on it would have made
// this package macOS-only too, for a path join. `AtelierCapture.LibraryMediaPaths`
// already computes that path on both platforms; it is the same move S4a made when the
// drain needed the phone to know where blobs live.

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
            ]),
    ]
)
