# 459 — the phone hands over its logic

[098](../.docs/098-ios-companion-completion-plan.md) · **P3**: the browse seam, and the
phone's logic put where tests reach it. Findings 9, 11 (the package half), 13, 14 and 15,
the bare-link title, and the code-quality batch that lives on this side of the graph.

The spine is [455](455-what-the-move-found.md)'s, run again on what was left. 455 moved one
`@MainActor @Observable` policy out of `AtelierRefsMobile` and found two bugs by testing
it; 098 · finding 9 counted what was still in there — *"every line of the phone app
target's logic is untested"* — and named four more types. All four moved. The app target's two
biggest controllers went from 241 and 261 lines to **55** and **129**, all of it wiring,
and `AtelierBrowse` went from 82 tests to **181**.

**What the tests found this time is smaller than 455's and stranger.** No live-lock, no
lost capture. What they found is that one of the plan's own findings is no longer true, and
that a test written three phases ago had a premise it never actually established.

## Finding 14 was fixed by the compiler, some time ago, with nobody watching

098 · finding 14, in its own words:

> `refreshCollections` / `refreshCovers` assign unconditionally after separate awaits, so
> `@Observable` fires even when nothing changed — roughly three grid evaluations per
> reload.

The fix is a `!=` guard, and it is here. The test written for it — `withObservationTracking`
over the store, assert nothing fired for a reload that changed nothing — passed with the
guard. It also passed **without** it, which is not what a test for a guard should do.

The reason, asked directly of the macro:

```swift
@Observable final class Box { var items: [Int] = [1, 2, 3] }
withObservationTracking { _ = b.items } onChange: { fired = true }
b.items = [1, 2, 3]     // fired: false
b.items = [9]           // fired: true
```

Since Swift 6.3 the setter `@Observable` generates compares an `Equatable` stored property
and does not notify when the value is unchanged. A non-`Equatable` one still fires. Both of
the store's guarded properties are `Equatable`, so the three grid evaluations per reload
the finding costed were already not being spent — and neither was any of the same class of
waste anywhere else in either app, on any `@Observable` property whose type happens to
conform.

**The guards land anyway**, and the reason is in the conditional above: the behaviour rests
on `[BrowseCollectionNode]` conforming to `Equatable`. Add a member to that node without
one and the finding is restored exactly, silently, with nothing to say so. So the tests
assert the property — *a reload that changes nothing invalidates nothing* — and are
indifferent to which of the two provides it, and one more test asks the macro directly so
the toolchain behaviour is pinned somewhere rather than assumed.

The partition it was protecting got measured on the way past: `MasonryColumns.distribute`
over 20,000 elements is **2.8 ms** per evaluation, and the same for 2 columns and 3. That
is the number 098 wanted before anyone considers memoising it, and it says nobody should.

## A test that had never established its own premise

`InboxDrainPolicyTests.twoExportsDoNotSpin` is 455's regression case for the two-export
live-lock, and its argument is *"what makes this reliable rather than lucky is that both
exports are genuinely queued (`exportsHolding == 2`) before either is allowed to finish"*.
It waited for the count and then asserted, on the next line, that the first export had
entered its body.

Those are not the same moment. `exclusively(_:)` increments `exportsHolding` **before** it
creates the work task — deliberately, so no activation can slip into the window — so a
count of 2 is reached while the first body may still be waiting to be scheduled. The
assertion was a race, and it had been green for two phases because the suite was small
enough that the runtime always got there first. Adding 99 tests to the package tipped it:
three runs in four failed, on a file this phase does not touch.

Both conditions are one wait now. The claim is unchanged and is now actually reached.

## One membership, by its own key

`ItemScreen` resolved a tapped tile with `store.items(in: collectionID).first { $0.item.id
== itemID }` — the whole P14 join, [450](450-the-read-was-never-the-problem.md) measured it
at 0.293 s for 5,000 rows, paid on every tap to keep one row and drop 4,999.

`AppServices.collectionItem(in:id:includeArchived:)` is the same join with a primary-key
predicate and no `ORDER BY`. On this machine, at 5,000 items:

| read | time |
|---|---:|
| the whole collection, `.manual` | 0.282 s |
| the whole collection, `.newest` | 0.279 s |
| **one membership** | **0.0008 s** |

Three things about that table. The `.newest` row is new: the existing scale test only ever
measured `.manual`, whose `manual_order, id` ordering an index covers, while `.newest`
sorts a joined column in a temporary B-tree — a different shape that nothing had timed. It
costs the same. The one-item row is asserted as a fraction of the collection read taken in
the same run rather than as an absolute, because an absolute number on an unknown runner
says nothing; there is a 50 ms absolute floor under it as well, so the ratio cannot pass by
the collection read also having got slow.

And the pair of ids is the key, not just the item id. A membership id is unique on its own,
so the predicate could have been the id alone — and then a route carrying a stale collection
would resolve an item that is no longer in the collection the screen says it is showing. An
absent collection throws `.notFound`; an absent membership is `nil`. They are different
sentences and the caller shows different screens.

**`AssetReadSurfaceTests` caught the new read before any of this ran.** That file pins every
function in `AppServices` that touches the `asset` table, each with a written answer to
"does this show archived items?", and it fails on an addition until someone writes the
answer down. It did exactly that. The canary is worth the paragraph because it is the only
thing in the program that would have noticed.

## One screen, one collection read

`CollectionFeed.load` asked three questions concurrently — `collection(id:)`, `items(in:)`,
`subcollections(of:)` — and `items(in:)` opened with a `getCollection` of its own to find
the sort mode. Every reload read the collection row twice, once for a name and once for an
enum, and the second read was invisible at the call site.

`BrowseLibrary.feed(for:)` reads it once. The shape is a dependency rather than a
preference: the order items come back in is a property OF the collection (007 · G4 — the
Mac writes it and the phone must not override it), so the sort mode has to be in hand before
the items request can be built. What can overlap still does. Three reads, two of them
concurrent, where there were four.

## Where each type went, and what stayed behind

Four moves, and in each case what stayed is exactly the environment the package cannot have.

**`LibraryStore` → `BrowseStore` + `CollectionFeed` + `BrowseFailure`.** What kept them in
the app was one call to `LibraryLocation.resolvedRoot()`, which reads `CommandLine.arguments`,
and one debug fixture seed that wipes and rewrites the root before the pool opens. Both are
injected — a throwing `root:` closure and an optional `prepare:` hook — and the app's file
is 55 lines: two closures and a typealias. The ordering that matters (seed strictly before
open) is a test rather than a comment, and it is a real assertion: the seeding closure
removes and recreates the root, so a store that had opened first would be reading a deleted
inode and would not see the seeded collection.

`BrowseFailure` is 093 § 7's ask, finally executed. The App Group failures are typed and
FATAL by design (092 · S1 · decision 3) precisely so a provisioning bug fails where it is
fixable, and the sentence a person sees is the whole user-facing consequence of that
decision. Every case it distinguishes has a test, including both `default` arms — a
`default` that quietly absorbs a case somebody meant to name is invisible until someone is
holding the broken phone.

**`CaptureExport` → `CaptureExportController`.** Five states, seven transitions, and one
invariant that matters more than any of them: **a "Clear" may only retire the ids that
reached the last manifest.** Most of the 23 tests are about keeping that true through a
failure, a cancelled share sheet, a second export and a `keep()`, because the failure mode
is a capture removed from the waiting set on the strength of a transfer that did not happen,
and the phone can never find out (091 · D4 — the Mac says nothing back).

Three closures stayed: the count, the write and the retire, each over `InboxArchive` or
`InboxRetirement`, and two of them hopping off the main actor. `AtelierBrowse` does not link
`AtelierArchive` and this does not change that — it is the argument `InboxDrainPolicy`
already makes about `DrainSummary`, that a package which types one closure's return value
has linked a whole subsystem to do it. The two failures worth their own sentence cross as
`CaptureExportFailure`; everything else falls through to the third sentence.

**Finding 11's package half comes free of that shape.** The policy's own suite proves the
export exclusion against a body that appends a string; the export controller is the real
body on the phone. Three of these tests drive the controller through a genuine
`InboxDrainPolicy`: an export waits out a running pass, an activation arriving during an
export is deferred and runs after it, and "Clear" takes the inbox too.

**`ThumbnailCache` → `DecodeCache`.** Below.

## A cache that coalesces, cancels, and can be asserted

`ThumbnailCache` was an `NSCache` and a `Task.detached` per miss. 440 gave it a real byte
bound; what it never had was the other two properties a scroll needs.

**Coalescing.** Two views asking for one key decoded it twice, and that is not hypothetical
here: the grid tile and the switcher's collection row resolve to the *same* 512-tier path
by construction — `collectionCovers` returns `gridThumbnailURL(forHash:)`, and
`BrowseLibraryTests` pins it — and the detail screen re-asks for a tier the grid may still
be decoding. **Cancellation.** A tile scrolled off cancelled the SwiftUI task and not the
decode, which then inserted, evicting something still on screen.

`DecodeCache<Key, Value>` is an actor with an injected decode and an injected cost. One
decode per key however many callers arrive; cancellation observed twice, before a decode
starts and before an insert. The second check is the one with teeth and the reason a
cancelled caller gets `nil` and leaves nothing behind.

**It is an explicit LRU rather than an `NSCache`, and that is a trade with a stated loser.**
`NSCache` purges under memory pressure by itself, which is a real benefit on a phone; its
eviction rules are also unspecified, which makes 440's byte bound a claim no test can make.
The bound was the point of 440, so the store is assertable and the pressure response moved
to the app — one `didReceiveMemoryWarningNotification` observer in the target that already
has UIKit.

Two copies went with it. The old cache re-implemented `ImageDecoding.thumbnail`'s option
dictionary option for option, and `DecodedThumbnail`'s `bytesPerRow * height`. Both are
asked for by name now, so the phone and the Mac's thumbnail pipeline cannot decode
differently or charge differently for the same file.

`maxPixel`'s bucket rounding moved to `DecodeSize` and picked up guards on the way. It was:

```swift
let pixels = Int((width * displayScale).rounded(.up))
return max(128, ((pixels + 127) / 128) * 128)
```

`Int(Double.nan)` is a **trap**, not a wrong answer, and this ran on the render path with a
width that comes from a `GeometryReader`. Nobody has hit it; nothing said it could not be
hit. Zero, negative, non-finite and absurd all answer one bucket now, and there is a test
for each.

The decode counter behind `-atelier-log-tile-bodies` is the other half of finding 15, and
`TileBodyLog` went entirely behind `#if DEBUG` at the same time — it was a
`nonisolated(unsafe)` static, an `NSLock` and a `print` per tile in a shipping binary, for a
diagnostic nobody can turn on there.

## A bare link says where it came from

098's "also found": `ShareCapture.swift:58-60` and 092 · S4b both say the drain enriches a
link with og-tags. Neither is true — `InboxDrain.makeInput` routes a `link` to
`remoteContent`, and `PageResolver` is only ever called from the Mac's paste path. So
**every** tier-1 link on the phone has a nil title, and `GridTile` fell through to
`link.url` and drew a whole URL, query string and tracking parameters included, in a
two-line label at column width.

`BrowseFormat.linkTitle` falls back to the host. No network: the fix for the missing og-tags
is Mac-side enrichment after import and is outside this pass; what can be said without
asking anyone is where the link points, which is what a person recognises.

**Punycode, not the Unicode host.** `URLComponents.host` answers `例え.jp` and
`URL.host(percentEncoded: false)` answers `xn--r8jz45g.jp`. The pretty one is a homograph
surface, and a tile is exactly where a lookalike domain would want to be drawn as the site
it is imitating — on a capture whose provenance the user may be about to trust. Userinfo is
stripped by both, and there is a test with `https://example.com@evil.test/` in it saying
which of the two names the label gets.

## The batch

- `cardChrome()` and `fieldChrome()` in `AtelierTokens` beside `elevation(_:)`. They replace
  four copied recipes and, more usefully, they remove the reason `MobileTheme.Elevation`
  existed: it restated `Tokens.Elevation.floating`'s colour, radius and y as three separate
  constants because its call sites applied a shadow beside a background rather than to one,
  which `.elevation()` cannot do. `cardChrome()` is that composition. `ShareCard.swift` has
  the third copy of the card recipe and keeps it — P5 owns that file.
- Five `MobileTheme` forwarders with zero readers each (`Radius.cover`, `Radius.panel`,
  `Motion.snappy`, `Colors.hairlineStrong`, `Typography.pageTitle`) and the dead
  `BrowseLibrary.init(root:)`, all grepped before deleting. That file's "absent, and absent
  deliberately" list is only information while every line in it is a decision.
- `MediaThumbnail` replaces the `ZStack { mediaBackdrop; ThumbnailImage }` recipe in four
  places, including the detail screen's measuring variant.
- `BrowseFormat.nonBlank` was a forwarder onto `TextRules.nonBlank` kept for the app's call
  sites ([457](457-one-spelling-of-each-rule.md) said P3 would repoint them). Repointed; the
  forwarder is gone.
- Named constants for `"CFBundleShortVersionString"` and `"-atelier-log-tile-bodies"`,
  following `FixtureLibrary.argument`.

## Files changed

**AtelierCore**

- `Sources/AtelierCore/Services/AppServices.swift` — `collectionItem(in:id:includeArchived:)`.
- `Tests/AtelierCoreTests/ServicesCollectionItemTests.swift` — new, 10 tests.
- `Tests/AtelierCoreTests/AssetReadSurfaceTests.swift` — the new read pinned with its reason.

**AtelierBrowse**

- `Sources/AtelierBrowse/BrowseLibrary.swift` — `Feed`, `feed(for:)`, `item(_:in:)`; the
  dead `init(root:)` gone.
- `Sources/AtelierBrowse/BrowseStore.swift` — new. `BrowseStore` (injectable root and
  preparation, the two `!=` guards) and `CollectionFeed` (the generation guard, plus the
  closure seam a test can park).
- `Sources/AtelierBrowse/BrowseFailure.swift` — new. The typed error → sentence mapping.
- `Sources/AtelierBrowse/CaptureExportController.swift` — new. The phase machine,
  `CaptureExportFailure`, `folderName(_:)`, `message(for:)`.
- `Sources/AtelierBrowse/DecodeCache.swift` — new. `DecodeCache`, `DecodeBudget`,
  `DecodeSize`.
- `Sources/AtelierBrowse/BrowseFormat.swift` — `linkTitle(_:url:)`, `hostName(of:)`; the
  `nonBlank` forwarder gone.
- `Package.swift` — header: what the package holds now, and what stayed in the app.
- `Tests/…/BrowseStoreTests.swift` (15), `CollectionFeedTests.swift` (8),
  `BrowseFailureTests.swift` (7), `CaptureExportControllerTests.swift` (23),
  `DecodeCacheTests.swift` (22) — all new.
- `Tests/…/BrowseLibraryTests.swift` — 12 new: the feed against the three reads it replaces,
  the sort mode, the empty and absent cases, subcollection order, and the five item cases.
- `Tests/…/BrowseScaleTests.swift` — 2 new: the `.newest` read, and one item against the
  collection read.
- `Tests/…/MasonryColumnsTests.swift` — 2 new: the partition at 20,000, and column-count
  independence.
- `Tests/…/BrowseFormatTests.swift` — 8 new: the link title and the host rule.
- `Tests/…/InboxDrainPolicyTests.swift` — the two-export premise, actually established.

**AtelierTokens**

- `Sources/AtelierTokens/Scale.swift` — `cardChrome(cornerRadius:)`, `fieldChrome(cornerRadius:)`.
- `Tests/AtelierTokensTests/TokensTests.swift` — 2 new: what the two modifiers rest on.

**AtelierRefsMobile**

- `LibraryStore.swift` — now 55 lines: a typealias and the two closures the store cannot
  supply itself.
- `CaptureExport.swift` — now the three I/O closures, the `WriteError` translation, and the
  exports directory.
- `ThumbnailImage.swift` — `ThumbnailKey`, the `DecodeCache` instantiation, the memory-warning
  observer, and `MediaThumbnail`.
- `MasonryGridView.swift` — `TileBodyLog` entirely `#if DEBUG`, plus `recordDecode()` and
  the named launch argument.
- `ContentView.swift` — the one-row item read, `BrowseFailure`, `fieldChrome`, the named
  plist key.
- `ItemDetailScreen.swift`, `GridTile.swift`, `ExportControls.swift`, `MobileTheme.swift` —
  the chrome batch, `MediaThumbnail`, the link title, the dead forwarders.

`project.pbxproj` is **untouched** — every dependency this phase needed was already on the
target. The Mac app, `AtelierRefsTests`, the share extension and `AtelierRefsMobileUITests`
are untouched.

## Verification

`swift test --parallel`, before (after P2) → after:

| package | before | after |
|---|---:|---:|
| AtelierCore | 776 | **786** |
| AtelierCapture | 172 | **172** |
| AtelierLibraryPaths | 32 | **32** |
| AtelierBrowse | 82 | **181** |
| AtelierArchive | 82 | **82** |
| AtelierIngestion | 502 | **502** |
| AtelierTokens | 7 | **9** |
| AtelierServer | 62 | **62** |

All passing. Nothing was dropped; `BrowseFormat.nonBlank` had no test of its own and the
rule it forwarded to is tested in `AtelierCore`.

The scale suite's own output, on this machine:

```
  14A: read 5000 items in 0.282s
  13:  read 5000 items in .newest order in 0.279s
  13:  one item 0.0008s against 0.279s for 5000
  14A: one read 0.279s, two concurrent 0.320s
  14A: 5,000 thumbnail resolutions in 0.085s
  14:  10 partitions of 20,000 items in 0.0284s (0.0028s each)
```

`swift build --triple arm64-apple-ios26.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"`
in AtelierCore, AtelierCapture, AtelierLibraryPaths, AtelierBrowse, AtelierArchive,
AtelierTokens, AtelierIngestion → **Build complete**, all seven.

`xcodebuild build -scheme AtelierRefsMobile -destination 'generic/platform=iOS Simulator'
CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED** (Release, which is also what compiles the
`#else` arm of the fixture-seed hook).

`xcodebuild build-for-testing -scheme AtelierRefsMobile -destination 'platform=iOS
Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO` → **TEST BUILD SUCCEEDED** — the run that
compiles `AtelierRefsMobileUITests`.

`xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'
-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`, run alone as 457 recommends.

### It was run, on a simulator, and then driven

iPhone 17 (iOS 26), Debug, launched with the arguments the UI tests use —
`-library-root uitest-fixture -seed-fixture-library` — plus `-atelier-log-tile-bodies`.

The grid drew: Unsorted's nine tiles in two columns — the six the fixture seeds plus the
three the drain ingested out of the seeded inbox during the same launch — with "Unsorted ⌄"
in the title and the send control reading **3**, which is the union still owed to a Mac.
The flag printed

```
atelier.tile-body 1 … 8
atelier.tile-decode 1 … 8
```

— eight of the nine on screen, eight decodes, no coalescing. That is the correct answer for
this fixture rather than a disappointing one: every tile is a distinct blob hash, so there
is nothing to share. The case coalescing exists for needs the switcher sheet open over the grid
(the same cover path resolved twice) or a real fling, which is 098's device item.

Then the two runnable UI suites were run against that simulator — not because this phase
owns them (P6 does) but because they drive the two things it moved:

- `SwitcherUITests` — **4 / 4 passed**, including `testTileOpensTheItemDetail`, which is the
  new one-row read resolving a tapped tile and the detail screen drawing its three 041
  sections. The screenshot shows the media, Data / Saved + Dimensions, Source / Platform +
  Author + Title with the `fieldChrome()` Visit button, and Details / Note.
- `ExportUITests` — **2 / 2 passed**, which is the moved export controller writing a real
  archive under a real exclusion and presenting a real share sheet, and the captures still
  being there afterwards.

## What is still NOT covered, stated rather than implied

**A pending count that throws still becomes zero, and zero hides the send control.** This is
pinned by a test that says so out loud, not fixed. A phone whose inbox directory cannot be
enumerated offers no way to send the captures sitting in it, and nothing anywhere reports
the failure. Surfacing it is a screen and screens are P6's; what the pin buys is that the
next person has to argue with a sentence rather than rediscover the swallow.

**Coalescing has never been observed doing anything on a device.** Its tests are
deterministic and its machinery is real, and the only evidence about whether a real scroll
ever hits it is eight decodes for eight tiles on a nine-item fixture. 098 lists the fling
over the 2,010-item fixture as a device item and it stays there; the counter it needs now
exists.

**The memory-warning purge has not been triggered.** `NSCache`'s pressure eviction was
traded for an assertable bound plus an observer, and the observer is registered and never
fired — a simulator's memory warning is a menu item nobody has picked. `DecodeCache.purge()`
itself is tested.

**`cardChrome()` and `fieldChrome()` have no test of their own.** A view modifier's output is
a `some View`; what can be asserted is what it rests on, and that is what
`ChromeTokenTests` does — that chip and field still round the same number, which is what
lets one modifier serve both call sites, and that `floating` is one value rather than three.
The chrome itself was verified by the two simulator screenshots.

**`BrowseStore` and `CollectionFeed` are still driven by SwiftUI in production and by tests
in isolation.** The `.task(id: FeedReload(collection:ingest:))` keying, the `ScenePhase`
mapping and the two `@State` lifetimes are exactly what 098's "no phone-hosted unit-test
target" decision leaves to the UI tests, and the four that ran above are all of it.

**The plan's finding 14 is now false and the doc still says it.** That is P6's, along with
the two link-enrichment corrections; this changelog is the record until then.

**Nothing has run on a device**, as in every changelog since 454.

## Migration notes

**API additions**, all source-compatible:

- `AppServices.collectionItem(in:id:includeArchived:)` — `includeArchived` is NOT defaulted,
  for the reason `collectionItems` gives at length. Returns `CollectionItemDetail?`; throws
  `.notFound` for an absent collection.
- `BrowseLibrary.Feed`, `BrowseLibrary.feed(for:)`, `BrowseLibrary.item(_:in:)`.
- `BrowseStore`, `CollectionFeed`, `BrowseFailure`, `CaptureExportController`,
  `CaptureExportFailure`, `DecodeCache`, `DecodeBudget`, `DecodeSize` — all new and public
  in `AtelierBrowse`.
- `BrowseFormat.linkTitle(_:url:)`, `BrowseFormat.hostName(of:)`.
- `Tokens`: `View.cardChrome(cornerRadius:)`, `View.fieldChrome(cornerRadius:)`.

**API removals**, all with zero readers, each grepped first:

- `BrowseLibrary.init(root:)` — the throwing convenience that opened its own pool. Callers
  compose `AppServices.open(libraryRoot:)` and `init(root:services:)`, which is what every
  caller already did.
- `BrowseFormat.nonBlank(_:)` — call `TextRules.nonBlank(_:)`.
- `MobileTheme.Radius.cover`, `.Radius.panel`, `.Motion.snappy`, `.Colors.hairlineStrong`,
  `.Typography.pageTitle`, and the whole `MobileTheme.Elevation` enum.

**Behaviour**, on the phone only:

- Opening an item reads one row instead of the collection. Same row, same order-independent
  result; an archived item is no longer reachable by a route pushed before it was archived,
  which the grid already hid.
- A link with no title shows its host instead of its URL. Nothing stored changes.
- A thumbnail decode is shared between simultaneous viewers of one key, and a decode whose
  only caller was cancelled is not inserted. The bytes held are bounded by the same 96 MB and
  240 as before, now by an LRU whose victim is the least recently USED.
- The cache is dropped entirely on a memory warning, where `NSCache` previously trimmed it
  by its own rules.
- `-atelier-log-tile-bodies` also prints `atelier.tile-decode N`, and the whole flag is
  Debug-only. A Release build no longer carries the counter, the lock or the `print`.

**On-disk**: nothing. No format, no schema, no layout, and no export folder name changed —
`folderName(_:)` moved packages and produces the same string from the same `en_US_POSIX`
formatter, which is pinned by a test.
