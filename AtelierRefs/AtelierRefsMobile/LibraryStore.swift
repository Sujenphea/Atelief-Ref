// AtelierRefsMobile — the two things the store cannot know about itself (092 · S5,
// 098 · P3).
//
// Everything this file used to hold — the phase, the collection tree, the covers, the
// ingest counter, the feed and its generation guard, and the typed-error → sentence
// mapping — now lives in `AtelierBrowse/BrowseStore.swift` and `BrowseFailure.swift`,
// where `swift test` can reach it. The argument is 455's, applied to the second of the
// two `@MainActor @Observable` types this app was written with: neither imports SwiftUI,
// and what actually kept them here was two lines of environment.
//
// Those two lines are below.
//
//   · **Where the library is.** `LibraryLocation.resolvedRoot()` reads
//     `CommandLine.arguments` and an environment variable. A package cannot be handed a
//     process's launch arguments in a test, so the store takes a throwing closure and this
//     supplies it. `resolvedRoot()`, not `defaultRoot()`, for the reason the Mac uses it:
//     with no `-library-root` and no `ATELIER_LIBRARY_ROOT` it IS `defaultRoot()` byte for
//     byte, and with one it is the throwaway-library escape hatch the UI tests and seeded
//     verification runs depend on.
//
//   · **The debug fixture seed.** `FixtureLibrary` is `#if DEBUG`, launch-argument gated,
//     and refuses a non-throwaway root; it wipes and rewrites the library, so it has to
//     run BEFORE the pool is opened or the pool is reading a deleted inode. That ordering
//     is the store's `prepare:` hook and is asserted by a test there.
//
// The names `LibraryStore` and `CaptureExport` are kept as this app's spelling of the two
// controllers, the way `InboxDrainScheduler` is kept for the policy: they are what
// `ContentView` and `ExportControls` were written against, and an object in between would
// exist only to forward.

import AtelierBrowse
import AtelierLibraryPaths
import Foundation

/// The browse store as this app builds it.
typealias LibraryStore = BrowseStore

extension BrowseStore {
    /// The store this app runs: the App Group's library root, and the debug seed.
    convenience init() {
        self.init(root: { try LibraryLocation.resolvedRoot() }, prepare: Self.seedFixture)
    }

    /// The fixture seed, or nothing at all in a Release build — where the type it would
    /// call is not compiled in.
    private static var seedFixture: RootPreparation? {
        #if DEBUG
        { root in
            if FixtureLibrary.isRequested { try await FixtureLibrary.seed(at: root) }
        }
        #else
        nil
        #endif
    }
}
