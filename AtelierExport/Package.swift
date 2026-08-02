// swift-tools-version: 6.0
import PackageDescription

// AtelierExport — the pure moodboard / contact-sheet layout + render package
// for ref-atelier (052 · decision 3A).
//
// Kept as a standalone local package with ZERO product dependencies so the
// export logic has a hard boundary: everything here is layout arithmetic and
// CoreGraphics / CoreText / ImageIO drawing over a package-local input model.
// It never imports AtelierCore (and so never pulls GRDB), never imports AppKit,
// and never touches the persistence or capture stacks. The app target maps its
// domain types (`SpaceItem`, `AssetContent`, `ElementStyle`) into this package's
// `MoodboardElement` model and supplies decoded images through the
// ``MoodboardImageProvider`` seam — so the render loop can pull one image at a
// time (052 · 13A: peak memory ≈ one item, not the whole board) while this
// package stays host-free and fully unit-testable via `swift test`.
//
// The layout output (`LayoutPage` / `PlacedElement`) and the renderer are the
// shared engine (052 · scope decision): the moodboard layout is the first
// producer of `[LayoutPage]`; the contact sheet (B4) becomes a second producer
// feeding the same renderer, with no renderer rework.
let package = Package(
    name: "AtelierExport",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AtelierExport", targets: ["AtelierExport"])
    ],
    targets: [
        .target(
            name: "AtelierExport"
        ),
        .testTarget(
            name: "AtelierExportTests",
            dependencies: ["AtelierExport"],
            // The static-site template (014 · S3) is pinned by committed golden
            // files rather than by string literals in the test: a reviewer can
            // open `Fixtures/*.html` in a browser, and a template change shows
            // up as a readable diff instead of an escaped one-liner.
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
