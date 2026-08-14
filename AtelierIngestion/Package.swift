// swift-tools-version: 6.0
import PackageDescription

// AtelierIngestion — the local capture-pipeline package for ref-atelier.
//
// Kept as a standalone local package so the ingestion machinery has a hard
// boundary: the content-addressed blob + thumbnail store, the hashing /
// metadata / thumbnail utilities, and the ingestion pipeline + coordinator all
// live in *this* package. It depends only on AtelierCore's public `AppServices`
// seam to persist metadata — it never reaches past that surface.
//
// System frameworks used by later chunks (CryptoKit for content hashing,
// ImageIO for decode/thumbnailing, UniformTypeIdentifiers for type sniffing)
// are platform-provided; they are imported directly in source and need no SPM
// dependency here.
//
// This checkpoint is a skeleton: it only proves the package builds, the
// AtelierCore path dependency links, and the test harness runs. The real store,
// utilities, and pipeline land in later checkpoints.
let package = Package(
    name: "AtelierIngestion",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AtelierIngestion", targets: ["AtelierIngestion"])
    ],
    dependencies: [
        .package(path: "../AtelierCore"),
        .package(path: "../AtelierCapture"),
    ],
    targets: [
        .target(
            name: "AtelierIngestion",
            dependencies: [
                .product(name: "AtelierCore", package: "AtelierCore"),
                // The inbox's directory name (092 · S2). `InboxLayout` lives in
                // AtelierCapture because the iOS share extension writes the inbox and
                // cannot link THIS package — `Input/DirectInputReader.swift` imports
                // AppKit. So the arrow points this way and `LibraryLayout.inbox`
                // delegates, rather than the name being spelled twice.
                .product(name: "AtelierCapture", package: "AtelierCapture"),
            ]
        ),
        .testTarget(
            name: "AtelierIngestionTests",
            dependencies: [
                "AtelierIngestion"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
