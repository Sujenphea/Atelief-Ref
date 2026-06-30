// swift-tools-version: 6.0
import PackageDescription

// AtelierCore — the local metadata-store package for ref-atelier.
//
// Kept as a standalone local package so the persistence layer has a hard
// boundary: GRDB (the SQLite toolkit) is a dependency of *this* package only
// and never leaks into the app target. The app talks to AtelierCore's public
// surface; the compiler enforces that GRDB stays confined inside.
//
// This checkpoint is a skeleton: it only proves the package builds, GRDB
// links, and the test harness runs. The real schema, records, and store
// types land in later checkpoints.
let package = Package(
    name: "AtelierCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AtelierCore", targets: ["AtelierCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "AtelierCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "AtelierCoreTests",
            dependencies: [
                "AtelierCore",
                // The migration suite imports GRDB directly to assert on the
                // DatabaseMigrator / Database it operates over.
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
