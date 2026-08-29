// swift-tools-version: 6.0

import PackageDescription

// AtelierLibraryPaths — where a library lives, and what the files in it are called.
//
// **Why this is a package and not two files in AtelierCapture** (096 review 4A). Both types
// arrived there by the same route, and 092 · S4b wrote the rule that this package is the
// answer to:
//
//   > The second time the AppKit boundary has relocated a type; if a third one appears,
//   > the boundary is the finding, not the type.
//
// `InboxLayout` moved out of `AtelierIngestion` in S2, `LibraryLocation` in S4a, and
// `LibraryMediaPaths` in S5 — the third — because `AtelierIngestion` imports AppKit
// (`Input/DirectInputReader.swift`) and so cannot build for iOS at all. Each move was
// individually correct. The result was a package called *Capture* holding four unrelated
// jobs: the capture wire contract, the inbox handoff, tier-2 page extraction, and this —
// filesystem knowledge that has nothing to do with capturing anything.
//
// The visible cost was the dependency arrow: `AtelierIngestion` depended on
// `AtelierCapture` purely to reach `LibraryLayout.inbox` and the library root, so the
// INGESTION package depended on the CAPTURE package for path arithmetic.
//
// **Fixing the actual boundary is a different, larger job.** Making `DirectInputReader`'s
// AppKit surface conditional would let `AtelierIngestion` build for iOS and would unblock
// the drain on the phone; S5 investigated it with the code in hand and declined, because
// `InboxDrain` and `RemoteImageFetcher` both call that file and dropping it on iOS takes
// the drain with it. That remains true and remains a project. This is the smaller,
// honest move: stop the relocation reflex, and let the arrow point somewhere defensible.
//
// **Zero dependencies, and that is checked rather than hoped.** Neither file imports
// `AtelierCore` — only Foundation and UniformTypeIdentifiers — and nothing in
// `AtelierCapture` uses either type, which is why that package does not depend on this one.
// A leaf that everything can reach and that reaches nothing is what makes it linkable from
// a share extension, a UI-test runner, and the Mac app alike.
let package = Package(
    name: "AtelierLibraryPaths",
    platforms: [
        // The floors mirror AtelierCore's rather than being derived downward — see the
        // note in that manifest. This package ships inside the Mac app, the companion app
        // and the share extension.
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "AtelierLibraryPaths", targets: ["AtelierLibraryPaths"])
    ],
    dependencies: [],
    targets: [
        .target(name: "AtelierLibraryPaths"),
        .testTarget(
            name: "AtelierLibraryPathsTests",
            dependencies: ["AtelierLibraryPaths"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
