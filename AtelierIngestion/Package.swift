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
        .package(path: "../AtelierLibraryPaths"),
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
                // `LibraryLocation` and `LibraryMediaPaths` left this package for the
                // same AppKit reason (092 · S4a, S5) and then left AtelierCapture too
                // (096 review 4A): three relocations into one package made *Capture*
                // mean four things, and 092 · S4b had already written the rule — "if a
                // third one appears, the boundary is the finding, not the type".
                // AtelierLibraryPaths is a zero-dependency leaf, so this arrow points
                // at filesystem knowledge rather than at a capture contract.
                .product(name: "AtelierLibraryPaths", package: "AtelierLibraryPaths"),
            ]
        ),
        .testTarget(
            name: "AtelierIngestionTests",
            dependencies: [
                "AtelierIngestion",
                // The inbox drain's tests (092 · S3) build fixture inboxes with the
                // real `InboxWriter` — the producer half of the handoff — rather than
                // hand-rolling the on-disk shape, which would let the two sides of a
                // contract drift while both suites stayed green. The fixtures come
                // from the shared test-only product for the same reason (092 · S0).
                .product(name: "AtelierCapture", package: "AtelierCapture"),
                .product(name: "AtelierLibraryPaths", package: "AtelierLibraryPaths"),
                .product(name: "AtelierCaptureTestSupport", package: "AtelierCapture"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
