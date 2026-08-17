# 409 — the rhythm that decomposed

The phone can read the library now. This is **S5**, the last code slice of the v1
companion before sync: a `NavigationStack` rooted at Unsorted, a masonry grid, a
collection switcher and an item detail — read-only, dark only, and drawn to
[093](../.docs/093-ios-visual-design.md) rather than to whatever SwiftUI's defaults
would have decided.

The slice is small because of a decision made on a Mac in 011-B1 and written down at
`MasonryLayout.swift:96`. That grid is **round-robin fixed-column**: item `i` lives in
column `i % C`, chosen so feed order equals reading order. Column membership is
therefore a function of the index alone — not of how tall the cells above it turned
out — so the layout **decomposes**. Column `c` is exactly `stride(from: c, to: n, by:
C)`. An `HStack` of `C` `LazyVStack`s reproduces the desktop's frames with no solver
ported, no custom `Layout` written, and no `UICollectionView` bridge, which 092 · S5
forbids outright. Had the Mac packed shortest-column-first, the phone's only options
would have been a uniform grid or a re-run of the 037–039 bake-off. **The rhythm
survived because of how it was chosen**, and none of that was luck arranged after the
fact: 093 § 3 predicted this file would be three functions long, and it is.

## What is on screen

The grid is the root and its **title is the switcher** — 093 § 2 subtracts the Mac
sidebar down to one survivor, the collections tree, and a navigation container built
to hold one destination type is a picker. So: no tab bar, no collections list as root,
no split view. Tapping the title presents the tree as a sheet, Unsorted pinned first
in `CollectionTargets`' order. A subcollection pushes; an item pushes; the detail keeps
the Mac's three 041 sections (Data, Source, Details) in the same order, reflowed below
the media instead of beside it.

Two columns in portrait, three in landscape, as a phone constant — deliberately not
`GridDensity`, whose stored default of 4 puts ~95pt cells on a 390pt screen and whose
width floor `ceil(width / 512)` evaluates to 1 there and catches nothing.

Nothing is drawn **on** the artwork. 093 § 5's finding is that hover, on the Mac, is
*storage* for affordances that would otherwise be permanent chrome over the pictures —
the cell dim, the selection circle, the post badge, the context menu — and that a phone
cannot borrow that space. So those affordances do not exist yet rather than being
relocated onto the tile. The tile is the picture and the tap is its only event.

## The laziness gate, run

093 § 3 does not take on faith that `LazyVStack`s nested in an `HStack` inside a
`ScrollView` stay lazy. It names the check — scroll a large collection and confirm
offscreen cells are not built — and names the fallback if it fails: uniform
`LazyVGrid`, a rollback of a layout container rather than a measurement exercise.

`-atelier-log-tile-bodies` is that check, and it ran. A library seeded with **2,010
items in Unsorted**, launched on the simulator with the flag: **8 tile bodies**, held
at 8 across 25 seconds of idle. A non-lazy stack would have reported 2,010 before a
finger touched the glass. **The gate passes and the fallback is not taken.** The
instrument stays in the file, off unless the argument is present, because the next
person to doubt this should be able to re-run it in one command rather than re-derive
it.

## Where the code went, and the boundary that decided it

The rule S4b arrived at — logic in a package, the app target thin — needed a package to
put logic in, and the obvious one was wrong.

**AtelierIngestion does not build for iOS, and this slice did not make it.** 091 · D1
sizes it as "near-free" to port, on the strength of it having exactly one AppKit file
(`Input/DirectInputReader.swift`). That was tried and it is not true, at least not as
one `#if`: `InboxDrain` and `RemoteImageFetcher` both call `DirectInputReader`, so
excluding the file on iOS takes the drain with it. Porting the package means splitting
that file, which is a change to the drain's dependencies, which is a separately-costed
decision the CI job already says it is — **091 · D1's estimate should be read as
optimistic on this point**, and the comment in `ci.yml` now records why.

So the phone needed `MediaStore`'s path math without `MediaStore`. **`LibraryMediaPaths`
moved to AtelierCapture and `MediaStore` / `LibraryLayout` delegate to it**, which is
the third time the AppKit boundary has pulled a type out of AtelierIngestion — after
`InboxLayout` (S2) and `LibraryLocation` (S4a), for the same reason and with the same
shape. That is a pattern, not a coincidence, and it is now written down as one.

**AtelierBrowse is a new package**: the masonry decomposition, the collection tree
ordering, the detail's value formatting, and the read seam over `AppServices`. It
depends on AtelierCore and AtelierCapture, declares macOS **and** iOS, and is tested by
`swift test` on the host while being compiled for the phone by CI. The alternative —
these files in `AtelierRefsMobile` — puts them where nothing runs them: a SwiftPM test
bundle needs a simulator host, which is exactly why CI's iOS row is `swift build`.

### Three restatements, and what pins each

`MasonryColumns`, `BrowseCollectionTree` and `BrowseFormat` restate rules that already
exist in the macOS app target (`MasonryLayout`, `CollectionTargets`, `DetailFormat`).
Those files are pure and would compile for iOS; they cannot be linked from another
target, and moving them means editing the macOS app, which this slice is not chartered
to do. **So this is duplication, and it is named rather than glossed.** What limits it:

- Every restatement carries the file and line it came from, the arrangement `ShareCard`
  established for the tokens.
- The tests assert the **rule**, not a fixture's spelling — `i % C` for every `C`,
  reading the columns row by row replays the input, Unsorted pinned however it sorts on
  its own merits, `sortIndex` before name, a corrupt parent cycle terminates. A drift
  has to be a disagreement about the rule.
- The two tier constants (512 / 1280) are restated in AtelierCapture and **pinned by a
  test in AtelierIngestion**, the one place that can see both `ThumbnailTier` and
  `LibraryMediaPaths`. The failure that test exists to catch is quiet: the phone asks
  for `<hash>@512.jpg`, nothing generates that tier any more, and the grid shows blank
  tiles for a library that is perfectly healthy.
- `MediaStore`'s agreement with `LibraryMediaPaths` is **structural**, not asserted —
  it delegates — and there is a test saying so, which keeps passing only while that
  stays true.

`MobileTheme` is a fourth restatement, of `Theme.swift`'s crossing subset per 093 § 4.
It is hand-copied values with line citations, exactly as `ShareCard` did — and
`ShareCard`'s header predicted this moment: *"When S5 brings a real iOS UI … a shared
cross-platform token target becomes the question; one card is not enough reader to
justify one now."* There are two readers now. **The target was not built**, because
building it means editing the share extension, which is verified working through a real
share sheet and is not what this slice is about. Raised, not done.

## What did NOT run, and what is not there

- **No device.** Everything visual below is a booted iPhone 17 Pro simulator. The
  data-protection class, jetsam, and a real share are as untested as R6 left them.
- **No drain on iOS.** `InboxDrain` lives in AtelierIngestion, which does not build for
  this platform, so **a capture made on the phone is not visible on the phone** until
  the Mac has ingested it and it has come back. The empty state says so in as many
  words. This is S6's, and it means the seeded library below is the only way the grid
  had anything to draw.
- **The library was seeded, not captured.** 24 items across Unsorted / Textures /
  Textures→Concrete / Type, plus a media-less colour and a bare link, written into the
  simulator's real App Group container by a throwaway host-side tool through the real
  `IngestPipeline` — so the thumbnails on screen are the tiers the Mac would have
  written, at the paths the Mac would have written them to. It is a real library, made
  by a fake user.
- **No scroll test on a device, and no frame timing anywhere.** The gate above counts
  cell construction, which is the question 093 asked. It is not a performance
  measurement and this changelog does not imply one.
- **The switcher's rows carry no thumbnail.** 093 § 2 asks for one, borrowing the Mac's
  cover-card idea, because a reference library's collections are recognised by their
  contents. It needs `collectionCovers` plus a per-row media load; it is a read this
  slice did not wire, and a bare-name list is the honest partial rather than a
  half-drawn cover.
- **`AtelierRefsMobile` still has no test target.** Its files are `@MainActor` state and
  SwiftUI; what could be tested was moved into `AtelierBrowse` precisely so this
  sentence could be short.

## A note qualifying D5 tier 1: the provider decides what "the original" is

Recorded here rather than in 092 because it is **observed behaviour of the share
provider**, not a plan.

Two shares of the same extension, same code, different outcomes. An image imported with
`simctl addmedia` arrived byte-identical: 7,347,619 bytes, md5
`408c7945664d76f3faa2b1a8fdc04a17`, with `com.apple.assetsd.*` xattrs intact and mtime
preserved from the asset's creation date — proving `copyItem` ran, not the `Data`
fallback. A stock simulator sample photo arrived instead as a 993,045-byte re-encoded
JPEG (1668×2500, Nikon D800E EXIF, Aperture 3.4.5); an unrestricted md5 sweep of the
whole simulator media directory found no file of that size and no file with those
bytes, so the derivative was generated at share time and no original was ever offered.

The extension faithfully copies whatever representation the provider hands it; **Photos
decides which**. Nothing extension-side can force the original. This is not a defect in
the writer — the two-phase commit, the 64 MiB cap and the file-backed payload path all
behaved exactly as designed in both cases — it is a qualification on 091 · D5 tier 1:
any future claim that the companion captures *original bytes* is a claim about the
provider's choice, and the provider will sometimes choose otherwise.

## Verification

| | |
|---|---|
| `AtelierCore` | 765 / 106 — unchanged |
| `AtelierCapture` | **104 / 5** — was 93 / 4 |
| `AtelierBrowse` | **37 / 4** — new package |
| `AtelierIngestion` | **467 / 48** — was 463 / 47 |
| `AtelierServer` | 62 / 6 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| `AtelierRefs` (macOS app) | `xcodebuild build`, `platform=macOS` — **BUILD SUCCEEDED** |
| `AtelierRefsMobile` | `xcodebuild build`, `platform=iOS Simulator,name=iPhone 17 Pro` — **BUILD SUCCEEDED** |
| iOS cross-build | `swift build --triple arm64-apple-ios26.0` — Core, Capture, **Browse**: Build complete |
| simulator, grid | 24 seeded items, Unsorted: masonry renders, 2 columns, variable heights, dark ground |
| simulator, switcher | Unsorted pinned first + checked, `Textures` discloses `Concrete`, `Type` a leaf; selecting switches the grid |
| simulator, subcollections | `Concrete` chip above the Textures grid, pushes to its own screen |
| simulator, detail | 1280-tier image, Data (Saved `17/08/2026`, Dimensions `1600px x 1200px`), Source (Pinterest, `Studio 1 (@studio1)`, title, Visit) |
| **laziness gate** | **2,010 items ⇒ 8 tile bodies at launch, stable over 25 s** — `LazyVStack`s stay lazy; the `LazyVGrid` fallback is NOT taken |

## Files

    AtelierCapture/Sources/AtelierCapture/     NEW. The blobs/ + thumbnails/ names, the
      LibraryMediaPaths.swift                  two-level hash shard, blob and tier file
                                               names, and the two tiers the phone reads.
                                               Read-only: nothing that writes came with
                                               it
    AtelierCapture/Tests/…/                    NEW. 11 tests: shards, the 4-character
      LibraryMediaPathsTests.swift             boundary, the empty-extension case, tiers
                                               as different files, the flat fallback
    AtelierIngestion/Sources/…/                delegates every path member to
      Media/MediaStore.swift                   `LibraryMediaPaths`; `StoreError` and all
                                               the writing machinery stay
    AtelierIngestion/Sources/…/                `blobs` / `thumbnails` delegate; the
      Media/LibraryLayout.swift                header's "one subdirectory" note becomes
                                               three, with the reason
    AtelierIngestion/Tests/…/                  NEW. 4 tests pinning 512/1280 to
      ThumbnailTierAgreementTests.swift        `ThumbnailTier`, that both tiers are
                                               actually generated, and that the store
                                               still delegates
    AtelierBrowse/                             NEW PACKAGE (macOS 26 + iOS 26 → Core,
      Package.swift                            Capture). `MasonryColumns` (round-robin
      Sources/AtelierBrowse/*.swift            decomposition, clamped aspect, 2/3
      Tests/AtelierBrowseTests/*.swift         columns), `BrowseCollectionTree`
                                               (Unsorted-pinned, cycle-safe),
                                               `BrowseFormat` (041's wording),
                                               `BrowseLibrary` (the read seam). 37 tests
    AtelierRefs/AtelierRefsMobile/             REPLACED. The S4b-i placeholder becomes
      ContentView.swift                        the `NavigationStack`, the routes, the
                                               empty / loading / failure notices
    AtelierRefs/AtelierRefsMobile/             NEW. `LibraryStore` (the library) +
      LibraryStore.swift                       `CollectionFeed` (one screen's contents —
                                               one per grid, so Back does not find the
                                               root showing a child's items)
    AtelierRefs/AtelierRefsMobile/             NEW. `HStack` of C `LazyVStack`s, and the
      MasonryGridView.swift                    laziness gate's instrument
    AtelierRefs/AtelierRefsMobile/             NEW. One cell, total over `AssetContent`;
      GridTile.swift                           nothing drawn over the artwork
    AtelierRefs/AtelierRefsMobile/             NEW. Decode-to-size + `NSCache`; not
      ThumbnailImage.swift                     `AsyncImage`, which is a `URLSession`
    AtelierRefs/AtelierRefsMobile/             NEW. `List(_:children:)` over the tree
      CollectionSwitcher.swift
    AtelierRefs/AtelierRefsMobile/             NEW. Media + the three 041 sections,
      ItemDetailScreen.swift                   read-only, Visit the only action
    AtelierRefs/AtelierRefsMobile/             NEW. 093 § 4's crossing subset, hand
      MobileTheme.swift                        copied with line citations
    AtelierRefs/AtelierRefsMobile/Info.plist   `UIUserInterfaceStyle = Dark` (093 § 6) —
                                               the extension had it, the app did not
    AtelierRefs/AtelierRefs.xcodeproj/         AtelierBrowse as a local package; Browse +
      project.pbxproj                          Core on the MOBILE target only
    .github/workflows/ci.yml                   AtelierBrowse in both matrices; the
                                               iOS-packages comment records why
                                               AtelierIngestion still is not there
    .docs/092-ios-companion-plan.md            dated note: S5 landed, what it did not do

## Migration notes

**No on-disk format moved and no behaviour changed on macOS.** `MediaStore` and
`LibraryLayout` compute exactly the paths they computed before — the members delegate,
and `ThumbnailTierAgreementTests` asserts the store's output equals the delegate's.
`MediaStore.StoreError.invalidHash` is still thrown for the same inputs.

**One new package.** `AtelierBrowse` is a local path dependency; a checkout needs
nothing but `swift build`. It is in `verify.sh` automatically, since that script parses
the package list out of `ci.yml` rather than keeping a second copy.

**`AtelierCapture` gained a public type and no existing one changed.**

**The mobile app now links AtelierCore and AtelierBrowse** in addition to
AtelierCapture. The macOS app target's link line, entitlements and Info.plist are
untouched, as is `Config/Release.xcconfig`.

**The phone's library is still the App Group container**, resolved by
`LibraryLocation.resolvedRoot()` — which with no `-library-root` and no
`ATELIER_LIBRARY_ROOT` is `defaultRoot()` byte for byte. The override branch is
untouched.
