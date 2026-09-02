// swift-tools-version: 6.0
import PackageDescription

// AtelierBrowse — the iOS companion's read-side logic (092 · S5, drawn to 093).
//
// Everything the phone's browse surface decides that is NOT a view: how a masonry
// column decomposes, how the collection tree is ordered, how a date and a platform
// are worded, and the read seam over `AppServices` + the on-disk thumbnail paths.
// The app target holds SwiftUI and nothing else — the arrangement S4b arrived at,
// where `AtelierCapture` carries the share extension's logic and `ShareViewController`
// carries only what needs `UIKit`.
//
// **Why a package and not files in the app target.** The companion's target has no
// test bundle and cannot get one cheaply: a SwiftPM test bundle needs a simulator
// host, which is why CI's iOS row is `swift build` and not `swift test`. Logic that
// lives in `AtelierRefsMobile` is logic nothing runs but a person with a phone. Here
// it is `swift test` on macOS, in the suite style the other five packages use.
//
// **Why it duplicates three things the macOS app already has.** `MasonryLayout`,
// `CollectionTargets` and `DetailFormat` are app-target files: they are pure, they
// import nothing that would not compile for iOS, and they cannot be linked from
// another target all the same. Moving them into a package would edit the macOS app,
// which 092 · S5 is not chartered to do, so what crosses is the RULE, restated with a
// citation to the line it came from — the same arrangement, and the same honesty
// requirement, as `ShareCard`'s hand-copied tokens. Where a copy could drift silently
// the tests here state the invariant rather than the value, so a divergence has to be
// argued for rather than merely allowed.
//
// **It is not only the read side any more (096 · 4, phase 4).** Phase 3 gave the phone a
// writer — a drain over its own inbox — and shipped the policy deciding WHEN that writer
// runs inside `AtelierRefsMobile`, untested, with its own changelog saying so. That policy
// is now `InboxDrainPolicy` here. "Browse" was an accurate name while the phone only read;
// the charter above — *companion-app logic that is not a view, put where `swift test` can
// reach it* — is what actually decided it, and a new package for one dependency-free type
// would have been a manifest, a CI row and a `Package.resolved` bought with nothing.
//
// **And it is not only the cadence either (098 · P3).** `BrowseStore`, `CollectionFeed`,
// `BrowseFailure`, `CaptureExportController` and `DecodeCache` were `AtelierRefsMobile`
// files until 098 · finding 9 counted what that cost: "every line of the phone app
// target's logic is untested". None of them imports SwiftUI or UIKit; what actually kept
// them in the app was `CommandLine.arguments`, a debug fixture seed, three calls into
// `InboxArchive`, and `UIImage`. All five are injected now — a root closure, a preparation
// hook, three I/O closures and a type parameter — and the app target holds the four
// adapters that supply them. The charter sentence above is what decided each one; the
// test count is what it bought.
//
// The dependency line is the boundary: AtelierCore for the domain types and the read
// surface, AtelierLibraryPaths for the library root and the media paths. **No
// AtelierCapture** on the library target since 457: the root and the paths moved out of
// it in 096 review 4A (`.change-log/448`), and no source file here used a Capture symbol
// after that — the dependency outlived its reason by nine changelogs. The TEST target
// links `AtelierCaptureTestSupport` for the shared temp-root maker and `Gate`, and that
// is all it takes from that package. **No AtelierIngestion** — it builds for iOS as of
// `.change-log/452`, so the old parenthetical here (that it imports AppKit) is no longer
// the reason; the reason is that `InboxDrainPolicy` is generic over what a pass returns
// precisely so this package never has to name `DrainSummary`, and linking an entire
// ingest pipeline to type one closure would undo that. No SwiftUI, no UIKit — so every
// decision below is testable without a device.
let package = Package(
    name: "AtelierBrowse",
    platforms: [
        // The floors mirror AtelierCore's and AtelierCapture's rather than being
        // derived downward — see the note in AtelierCore's manifest. This package
        // ships inside the companion app and is tested on the host.
        .macOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .library(name: "AtelierBrowse", targets: ["AtelierBrowse"])
    ],
    dependencies: [
        .package(path: "../AtelierCore"),
        .package(path: "../AtelierCapture"),
        .package(path: "../AtelierLibraryPaths"),
    ],
    targets: [
        .target(
            name: "AtelierBrowse",
            dependencies: [
                .product(name: "AtelierCore", package: "AtelierCore"),
                .product(name: "AtelierLibraryPaths", package: "AtelierLibraryPaths"),
            ]
        ),
        .testTarget(
            name: "AtelierBrowseTests",
            dependencies: [
                "AtelierBrowse",
                .product(name: "AtelierCore", package: "AtelierCore"),
                .product(name: "AtelierLibraryPaths", package: "AtelierLibraryPaths"),
                // The shared fixtures (457): the temp-root maker every suite's rig uses,
                // and the `Gate` the policy tests park a pass on.
                .product(name: "AtelierCaptureTestSupport", package: "AtelierCapture"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
