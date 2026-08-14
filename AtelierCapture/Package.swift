// swift-tools-version: 6.0
import PackageDescription

// AtelierCapture — the INBOUND capture contract for ref-atelier (092 · S0).
//
// One wire shape for "something out there captured a reference", and the pure
// funnel that validates it into the domain types the ingestion pipeline accepts:
// `CaptureRequest` / `ProvenanceDTO` / `VideoCaptureHeader` in, a `DecodedInput`
// (image · content · content-with-image) or a typed `CaptureDecodeError` out.
//
// It was extracted from AtelierServer, which owns it no longer, because it has
// TWO producers now and only one of them is an HTTP server: the Chrome extension
// POSTs it to the loopback endpoint, and the iOS share extension writes it into
// the inbox (091 · D2). A second decoder over the same wire shape is how
// provenance quietly diverges between them — and provenance is precisely what
// `AppServices.ingest`'s 18A dedup keys on, so a drift here forks assets rather
// than merging them.
//
// The boundary that keeps this reusable: **zero product dependencies beyond
// AtelierCore, and nothing about transport.** No FlyingFox, no sockets, no
// AppKit/UIKit, no filesystem. It cannot know whether the capture arrived over a
// socket or was found in a directory, which is the property that lets iOS link
// it into a memory-capped share extension that must not link GRDB.
//
// What deliberately did NOT come with it: `CaptureResponse` — the HTTP reply.
// A capture written to the inbox has nobody to answer, so the reply is a
// property of the server transport, not of the contract. It stays in
// AtelierServer beside the routes that send it.
let package = Package(
    name: "AtelierCapture",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AtelierCapture", targets: ["AtelierCapture"]),
        // Test-only fixtures, exposed as a product because AtelierServer's test
        // target needs them and SPM test targets are not products — the same
        // constraint `ServerTestEnv.swift` records for AtelierIngestion. Nothing
        // ships this: only test targets depend on it.
        .library(name: "AtelierCaptureTestSupport", targets: ["AtelierCaptureTestSupport"]),
    ],
    dependencies: [
        .package(path: "../AtelierCore")
    ],
    targets: [
        .target(
            name: "AtelierCapture",
            dependencies: [
                .product(name: "AtelierCore", package: "AtelierCore")
            ]
        ),
        .target(
            name: "AtelierCaptureTestSupport",
            dependencies: [
                "AtelierCapture",
                .product(name: "AtelierCore", package: "AtelierCore"),
            ]
        ),
        .testTarget(
            name: "AtelierCaptureTests",
            dependencies: [
                "AtelierCapture",
                "AtelierCaptureTestSupport",
                .product(name: "AtelierCore", package: "AtelierCore"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
