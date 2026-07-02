// swift-tools-version: 6.0
import PackageDescription

// AtelierServer — the localhost capture endpoint for ref-atelier (build-order #6).
//
// A standalone local package so all networking lives behind a hard boundary and
// stays headlessly testable. It owns the FlyingFox HTTP server bound to loopback,
// the request/response DTOs, the auth+CORS gate, and the route that turns a
// captured image + provenance into an `IngestInput` and runs it through the
// existing `IngestCoordinator` (AtelierIngestion) — it never re-implements
// ingestion, and it never imports the app / view model.
//
// FlyingFox (swhitty/FlyingFox, MIT) is a lightweight pure-Swift async HTTP
// server; it is the app graph's 2nd remote SPM dependency after GRDB. The
// listener needs the `com.apple.security.network.server` sandbox entitlement,
// added on the app target.
let package = Package(
    name: "AtelierServer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AtelierServer", targets: ["AtelierServer"])
    ],
    dependencies: [
        .package(path: "../AtelierCore"),
        .package(path: "../AtelierIngestion"),
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.20.0"),
    ],
    targets: [
        .target(
            name: "AtelierServer",
            dependencies: [
                .product(name: "AtelierCore", package: "AtelierCore"),
                .product(name: "AtelierIngestion", package: "AtelierIngestion"),
                .product(name: "FlyingFox", package: "FlyingFox"),
            ]
        ),
        .testTarget(
            name: "AtelierServerTests",
            dependencies: [
                "AtelierServer"
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
