// swift-tools-version: 6.0
//
// AtelierTokens — the design tokens, once, for every target that draws (093 § 4).
//
// **Why this exists.** `Theme.swift` is a macOS app-target file: it imports AppKit,
// mirrors colours into `NSColor` twins and extends `CALayer`, so it cannot compile for
// iOS and an app extension cannot import its host's target either way. The values
// therefore crossed by HAND — first into `ShareTheme` (the share extension's card), then
// into `MobileTheme` (S5's phone UI) — each literal citing the `Theme.swift` line it came
// from so the copy was checkable rather than merely plausible.
//
// `ShareCard.swift`'s header called the ending: *"When S5 brings a real iOS UI, this
// stops being the right shape and a shared cross-platform token target becomes the
// question; one card is not enough reader to justify one now."* There are three readers
// now, and three hand-copied palettes is a drift waiting for the first `#212121` that
// gets adjusted in one of them.
//
// **What crosses is the VALUE, not the representation.** A colour is one hex here; the
// `Color` is derived, and the Mac builds its `NSColor` twin from the same number. That is
// what makes drift structurally impossible rather than merely watched — `Theme.NS` had
// already had three mirrors fall out of step with their originals before they were culled
// back to the ones with readers.
//
// No dependencies, and none wanted: tokens are values plus SwiftUI, and SwiftUI is on
// both platforms. `AtelierExport` keeps its own zero-dependency rule for the same
// reason this package has nothing to say about the domain.

import PackageDescription

let package = Package(
    name: "AtelierTokens",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "AtelierTokens", targets: ["AtelierTokens"])
    ],
    targets: [
        .target(name: "AtelierTokens"),
        .testTarget(name: "AtelierTokensTests", dependencies: ["AtelierTokens"]),
    ]
)
