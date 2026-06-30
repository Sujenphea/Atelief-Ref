// swift-tools-version: 6.0
import PackageDescription

// CanvasRenderer — the infinite-canvas rendering spike for ref-atelier.
//
// Kept as a standalone local package (decision A3) so the renderer has zero
// dependency on the app: the compiler enforces the "view-agnostic" boundary,
// and the spike's benchmark + tests run independently via `swift test`.
//
// The pure logic (CanvasTransform, TileCuller, LODPolicy, Tile, TileProvider)
// has no AppKit import and is exercised headlessly; the AppKit/Core Animation
// host is exercised by the benchmark and the layer-pool invariant tests.
let package = Package(
    name: "CanvasRenderer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CanvasRenderer", targets: ["CanvasRenderer"])
    ],
    targets: [
        .target(
            name: "CanvasRenderer"
        ),
        .testTarget(
            name: "CanvasRendererTests",
            dependencies: ["CanvasRenderer"]
        )
    ],
    swiftLanguageModes: [.v6]
)
