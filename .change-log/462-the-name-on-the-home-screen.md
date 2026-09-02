# 462 — The name on the home screen

> **P6 of [098](../.docs/098-ios-companion-completion-plan.md), and the last of six.**
> Surfaces, the UI tests in CI, and the docs. This closes the pass: 098 is marked done
> with a changelog per phase, and its "Left to the user" list now carries everything the
> six phases found and could not finish.

For six phases this app has been correct and anonymous. It had no name, so the home
screen and the share-sheet row both read *AtelierRefsMobile*. It had an empty
`AppIcon.appiconset`, so it wore the system's grey placeholder. It had an empty
`AccentColor`, so every UIKit surface it does not draw itself — the export's
`UIActivityViewController` above all — tinted system blue inside a monochrome app whose
design doc argues for two pages about which tokens cross. And
`INFOPLIST_KEY_UILaunchScreen_Generation = YES` gave it a launch screen on
`systemBackground`, which under `UIUserInterfaceStyle = Dark` is `#000000` — one black
frame, every cold launch, before `canvasOuter` `#131313` painted over it.

Four settings, and none of them is a feature. They are what a person sees before they
have used anything.

## The four, read back out of the built product

Changelog 401 established that the only check worth anything here is reading the keys out
of the `.app`, because `INFOPLIST_KEY_*` accepts settings it then silently drops — which
is exactly how `AtelierAppGroupIdentifier` came to need its own `Info.plist` file. So:

```
CFBundleDisplayName  => AtelierRefs
CFBundleIconName     => AppIcon        (CFBundleIconFiles: AppIcon60x60)
NSAccentColorName    => AccentColor
UILaunchScreen       => { UIColorName => LaunchBackground }
UIUserInterfaceStyle => Dark
```

and in the compiled `Assets.car`, `AccentColor` at `(0.949, 0.945, 0.933)` — `inkPrimary`
`#F2F1EE` — and `LaunchBackground` at `(0.0745, 0.0745, 0.0745)`, which is `#131313`.

**One display name on both configurations**, not a *Dev* suffix: there is one
`PRODUCT_BUNDLE_IDENTIFIER`, so the two builds cannot coexist on a device and a suffix
would name nothing. **The Mac's 1024 as the universal iOS icon**, not a new mark: a
phone-specific icon is a design decision and it is the user's, where "there is no icon at
all" is a gap. And the launch dictionary lives in the target's real `Info.plist` rather
than in a `INFOPLIST_KEY_UILaunchScreen_UIColorName`, with `_Generation` **removed** —
the generated keys merge *over* the file, so leaving it on would have put the empty
dictionary back and the flash with it.

The launch colour was checked twice, because a build setting proves the plist and not the
pixel: a burst of screenshots during a cold launch caught the launch card, and its centre
pixel is `(19, 19, 19)`.

The last hand-spelled bundle id went the same day. `MobileLog.subsystem` was
`"sujenphea.AtelierRefsMobile"`, the other half of finding 7's pair; P5 adopted
`CompanionBundle` on the extension's side and could not edit this file. Both now prefer
`Bundle.main.bundleIdentifier` and fall back to the one constant that a test reads back
out of `project.pbxproj`.

## Five screens that were not designed

093 § 7 lists "empty and error states" among the things it deliberately does not design,
and flags one as worth closing early: 092 · S1 · decision 3 made a missing App Group a
typed FATAL error precisely so a provisioning bug fails where it is fixable, and nothing
rendered it. 098 brought the rest into scope. Five: an empty library, an empty
collection, a failed drain, a failed export, and that missing container.

Everything decidable went into a package with a test; only the drawing stayed.

**There were four kinds of nothing and the app drew one.** `EmptyNotice` said "Nothing
here yet / Anything you share arrives in Unsorted" for every empty grid. That is right
for Unsorted and wrong three ways elsewhere: on a phone nothing has ever been shared to
it describes a mechanism the user has not used yet as though they had; in a collection
reached off the switcher it answers a question about somewhere else; and in a collection
holding only subfolders it was *never reached at all*, because the condition was
`items.isEmpty && subcollections.isEmpty` — so that screen had no sentence and rendered a
panel of nothing under a row of chips containing exactly the pictures it would have said
were missing.

`BrowseEmptyState.resolve` decides which, from four numbers and no I/O. The discriminator
is **"is this Unsorted"**, not "is this the root screen": the root's collection is
whatever the switcher last chose, so `isRoot` answers a question about the navigation
stack, and "anything you share arrives here" is true of Unsorted and of nowhere else. And
"the library is empty" turns out to be free — every item lives in a collection, so if
Unsorted is empty and Unsorted is the only collection there is, there is nothing
anywhere.

**A pending count that throws is said out loud.** 459 pinned this rather than fixing it,
in a test whose comment said the fix was a screen and screens were P6's:
`pending = (try? pendingCount()) ?? 0`, and zero hides the send control, so a phone whose
inbox directory cannot be enumerated offered no way to send the captures sitting in it
and nothing anywhere reported the failure. `pending` is `nil` now — because 0 is a real
answer an empty inbox gives — and `pendingFailure` carries the sentence. Its card is the
only one that does **not** auto-dismiss: the other three report an event, this reports a
state, and a card that timed out would leave the phone looking exactly like a phone with
nothing to send. It clears itself on the next successful refresh, which is every
activation.

**A drain pass can now say one thing.** `DrainReport.swift`'s header said in bold that
nothing there reaches the user, on the ground that an unreadable inbox and a quarantined
capture are conditions a person has no lever for. Both halves are still true; the
conclusion is not. The test is not *can the user act* but **would the app otherwise
misrepresent itself** — and 093 § 1 had already named the case, in the paragraph
defending the word "Saved" on the share sheet's card:

> The only exception is host-side quarantine after three failures (092 · S3), which is a
> bug and belongs on the surface that can show it.

`DrainSummary.userNotice` says something for two of the six fields and nothing for four.
`inboxUnreadable`, because every surface says the opposite — the grid shows what is
already in the library, the send control reads the same directory and quietly
disappears, and the receipt said "Saved". `quarantined`, because the capture is in
`inbox/failed/`, which no export reads. And **`skippedExhausted` is deliberately silent**:
the drain has given up, but the record stays pending, the export still sends it and the
Mac still gets it — nothing was misrepresented. That fate is the whole reason
`.retainForExport` exists.

**And the number the export threw away.** 458 recorded it: `InboxArchive.Summary.skipped`
has always known how many records the funnel refused, and `CaptureExport` kept `exported`
and dropped the rest — so a send of four that carried three read "Sent 3" beside a count
that stayed at four, with nothing on screen connecting them. `.sent(count:skipped:)`, and
one extra line in `warning` when and only when it happened.

The four notice views are one file with two shapes. A screen with nothing else on it
takes the whole panel; a condition that arrives while the grid is still worth looking at
takes a card at the bottom. No fourth recipe: `cardChrome()`, `warning`, the same six
type roles.

## The item detail, finished

093 § 7 left the layout undecided and the file drew a partial one. Two of the nine facts
098 asks for were missing.

**The collection.** The Mac draws memberships as removable chips behind an Add / Move
popover — three verbs the phone does not have, and 098 closes 093's open question 1 as
*no*, so it never will. Take the verbs away and what is left is a fact, which belongs in
the same label / value row as the other eight. `BrowseLibrary.memberships(of:)` is a
second read keyed on the asset id, which only exists once the first has answered: it runs
*after* the picture is on screen, and a read that fails draws no row rather than replacing
the item with an error screen.

Its test found the rule worth pinning. Filing an item **moves** it out of Unsorted
(changelog 298, "unsorted means not filed"), so the row is singular on nearly every
screen — which is why one line of text can do here what a chip flow does on the Mac.

**The title.** `BrowseFormat.title` is nil for every tier-1 link on this phone, because
nothing enriches one; the detail spelled `title ?? ""` and drew a **bare navigation bar**,
while the tile that rendered `example.com` announced "Web" to VoiceOver.
`BrowseFormat.displayTitle` is one rule for both call sites: the user's name, the source's
title, then what the content knows about itself — a link's host, a post's author — then
the platform. A property test over every kind × every platform asserts it is never empty,
and caught a stored link URL of `""` returning `""`.

## The UI tests, and a gate for them

098 · finding 10: *"the UI tests never run anywhere, and the one that matters cannot
run."*

`Tier2ShareUITests` resolved the App Group through `LibraryLocation.defaultRoot()`, whose
default bundle is `Bundle.main` — in a UI test that is the XCTRunner, an Apple-signed
bundle with no `AtelierAppGroupIdentifier` — so it threw before Safari was ever launched
(461 watched it happen). P1 added `defaultRoot(bundle:)` for exactly this; it passes
`Bundle(for: Self.self)`. And it read only `pendingRecordURLs()`, which was right when it
was written and stopped being right at 454: the app drains at launch and `pendingCount()`
*launches the app*, twice, so the record it looks for has already moved to
`inbox/ingested/`. It reads the union now, deduped by id, exactly as
`InboxArchive.pending(in:)` does. Two failures by construction, in a test that had never
executed a line.

It is still opt-in behind `ATELIER_RUN_SAFARI_TESTS`, with an `XCTSkipUnless` that says
what to do about it, because the remaining blocker cannot be fixed from here: the runner
bundle needs `sujenphea.AtelierRefsMobileUITests` registered as an App ID with App Groups.

**`ExportUITests` gained Clear and Keep, and driving them found the identifiers did not
exist.** 098 said "the identifiers already exist (`export.clear`, `export.keep`,
`export.sent`)". They existed in the source and not at runtime: `export.sent` sat on the
enclosing `VStack`, and **an accessibility identifier on a container propagates down over
its children** — the element tree showed all four descendants reporting `export.sent`.
Every notice identifier sits on a leaf now, with the lesson written where the next one
would be added.

Two more cases: an empty collection says which nothing it is, and the item detail's nine
facts are asserted by name.

CI: the `ios-app` row is `build-for-testing` on the mobile scheme, so the UI-test bundle
compiles — `xcodebuild build` built the app and not its tests, which is how 700 lines of
UI test had no gate anywhere — and a new `ios-ui-tests` job runs the two runnable suites
on a pinned iPhone 17, with the reason tier 2 is excluded in a comment beside it.

## What looking at it found

Point `-library-root` at a corrupt library and the phone drew an orange sentence on
`#000000`. Both real screens paint `panel` for themselves; the loading and failure states
painted nothing, so the navigation controller's own opaque black showed through — a
colour this app does not have. The ground is `canvasOuter` now, painted **inside** the
`NavigationStack` rather than on it, because a background on the stack is painted over,
which is the same fact that caused the bug. `canvasOuter` and not `panel` so the first
frame the app draws is the tone the launch image already was.

Read back off the simulator: `(19, 19, 19)`.

## The docs

092 · "Where this stands" still said *"there is still no drain on iOS, so a capture made
on the phone is not visible on the phone until the Mac has ingested it"* — true when
written, retired by 454. 092 · S4b and `ShareCapture.swift`'s own `.link` doc both said
the drain resolves og-tags for a tier-1 link, and neither was ever true on either
platform: `InboxDrain.makeInput` routes a link to `remoteContent` and `PageResolver` is
only ever reached from the Mac's paste path. `feature-todo/013` still recorded the iOS
companion as considered and *not selected* (2026-07-13); it was reversed and built.
091's open question 3 (does the phone need the analysis stack) and 093's open question 1
(one write in browse) are closed by the user's decision, *no* in both cases.

All of them are amended in place with a dated note rather than rewritten — the repo's
habit, and the reason it is possible to read what a doc believed at the time. Two stale
line citations were fixed on the way past (`InboxDrain.swift:560-563` → `:708`–`:712`,
and `ShareCapture.swift:58-60`, which no longer needs a line number).

## Files changed

**The app as a thing on a home screen**

- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — `INFOPLIST_KEY_CFBundleDisplayName
  = AtelierRefs` on both `AtelierRefsMobile` configurations; `INFOPLIST_KEY_UILaunchScreen_Generation`
  removed from both.
- `AtelierRefsMobile/Info.plist` — a `UILaunchScreen` dictionary naming `LaunchBackground`.
- `AtelierRefsMobile/Assets.xcassets/AppIcon.appiconset/` — `icon_1024.png` (the Mac's
  `icon_512@2x.png`) and its `Contents.json`.
- `AtelierRefsMobile/Assets.xcassets/AccentColor.colorset/Contents.json` — `inkPrimary`.
- `AtelierRefsMobile/Assets.xcassets/LaunchBackground.colorset/Contents.json` — new,
  `canvasOuter`, in hex components so it is comparable by eye with `Palette.swift`.
- `AtelierRefsMobile/MobileIngest.swift` — `MobileLog.subsystem` through `CompanionBundle.app`.

**Empty and error states**

- `AtelierBrowse/Sources/AtelierBrowse/BrowseEmptyState.swift` — new; four cases, one
  resolver, the wording.
- `AtelierBrowse/Sources/AtelierBrowse/BrowseStore.swift` — `drainNotice`,
  `noteDrain(notice:)`, `dismissDrainNotice()`, `collectionCount`.
- `AtelierBrowse/Sources/AtelierBrowse/CaptureExportController.swift` — `pendingFailure`
  and `inboxUnreadableMessage`; `Written.skipped`; `.sent(count:skipped:)`.
- `AtelierIngestion/.../Input/DrainReport.swift` — `DrainSummary.userNotice`, and the
  header's rule restated as being about `reportLines`.
- `AtelierRefsMobile/Notices.swift` — new; `LoadingNotice`, `FailureNotice`,
  `EmptyNotice`, `WarningNotice`, `NoticeID`.
- `AtelierRefsMobile/ContentView.swift` — `bottomNotice`, the empty-state resolution, the
  drain-notice wiring, the app's opaque ground.
- `AtelierRefsMobile/ExportControls.swift` — `ExportFailureNotice` gone into
  `WarningNotice`; `ExportSentNotice` gains `skipped` and moves its identifier to a leaf.
- `AtelierRefsMobile/InboxDrainScheduler.swift` — `onNotice:` through the report.

**The item detail**

- `AtelierBrowse/Sources/AtelierBrowse/BrowseFormat.swift` — `displayTitle(for:source:)`,
  `collectionNames(_:)`.
- `AtelierBrowse/Sources/AtelierBrowse/BrowseLibrary.swift` + `BrowseStore.swift` —
  `memberships(of:)`.
- `AtelierRefsMobile/ItemDetailScreen.swift` — the collection row, the non-empty title.
- `AtelierRefsMobile/GridTile.swift` — one rule with the detail for the tile's label.

**The tests and CI**

- `AtelierRefsMobileUITests/Tier2ShareUITests.swift` — own bundle, pending ∪ ingested,
  `ATELIER_RUN_SAFARI_TESTS`.
- `AtelierRefsMobileUITests/ExportUITests.swift` — Clear, Keep, a shared share-sheet
  dismissal and a disappearance wait.
- `AtelierRefsMobileUITests/SwitcherUITests.swift` — the empty collection, the nine facts.
- `.github/workflows/ci.yml` — `ios-app` on `build-for-testing`; a new `ios-ui-tests` job.

**Tests added**, by `@Test` declaration — `BrowseEmptyStateTests` 10 (new),
`BrowseFormatTests` 16 → 25, `BrowseLibraryTests` 23 → 27, `BrowseStoreTests` 15 → 20,
`CaptureExportControllerTests` 23 → 28, `DrainReportTests` 15 → 22. One was replaced
rather than added: `unreadableInboxCountsZero`, the pin 459 left, is now
`unreadableInboxHasNoCount` and asserts the opposite.

**Docs** — `.docs/091`, `.docs/092`, `.docs/093`, `.docs/098`,
`.docs/feature-todo/013-capture-breadth.md`, and `AtelierCapture/.../ShareCapture.swift`'s
`.link` doc.

## Verification

| Suite | Before (P5) | After |
|---|---|---|
| `AtelierCore` | 786 | **786** |
| `AtelierCapture` | 190 | **190** |
| `AtelierLibraryPaths` | 32 | **32** |
| `AtelierBrowse` | 182 | **215** |
| `AtelierArchive` | 82 | **82** |
| `AtelierIngestion` | 517 | **524** |
| `AtelierTokens` | 9 | **9** |
| `AtelierServer` | 62 | **62** |
| `extension` (`node --test`) | 629 / 3 skip | **629 pass / 3 skip / 0 fail** |

- **iOS cross-build** at `arm64-apple-ios26.0` with `--sdk`: all seven packages build.
- **`xcodebuild build`** for `AtelierRefsMobile` and `AtelierRefsShare` on
  `generic/platform=iOS Simulator`: both **BUILD SUCCEEDED**.
- **`build-for-testing`** for `AtelierRefsMobile` on `platform=iOS Simulator,name=iPhone 17`:
  **TEST BUILD SUCCEEDED**.
- **`xcodebuild test -only-testing:AtelierRefsTests`** on macOS, run alone: **TEST
  SUCCEEDED**.
- **`xcodebuild -list`** parses after every `project.pbxproj` write.
- **The two UI suites on a booted iPhone 17**: `SwitcherUITests` **5/5**, `ExportUITests`
  **4/4** — **9 passed, 0 failed** in 87.6 s. `Tier2ShareUITests` **skips** with its
  reason.
- **The built product's `Info.plist` and `Assets.car`**, read back — the five keys and
  the two colour sets above.

**And it was run and looked at.** On a booted iPhone 17, with screenshots: the icon and
the name *AtelierRefs* on the home screen; the launch card at `#131313`, sampled; the
masonry grid under an *Unsorted ⌄* title with a **3** on the send control; an item's
detail with all three 041 sections and all nine facts (Saved `02/09/2026`, Dimensions
`1600px x 1066px`, Platform `Web`, Author `Ada Lovelace`, Title, Visit ↗, Note,
Collection `Unsorted`); the sent offer over the grid with Keep and Clear; an empty
collection saying *"This collection is empty / Collections are filled on your Mac."*; the
empty library saying *"Nothing saved yet"*; and — against a deliberately corrupted
library — the failure screen that the missing App Group also renders.

## What is still NOT covered

**The missing App Group was rendered, not reproduced.** The failure screen above was
reached by corrupting a library file, which lands on `BrowseFailure`'s default sentence.
The two App Group sentences are unit-tested in `BrowseFailureTests` and have never been
seen on a screen, because neither error is reachable on a simulator whose bundle carries
the key.

**The drain notice has never been triggered by a real drain.** `DrainSummary.userNotice`
is tested over every field combination and `BrowseStore.drainNotice` round-trips in its
own test, but nothing has made a real pass return `inboxUnreadable` or a quarantine on a
device, so the card itself has been reasoned about and not watched. The same is true of
`pendingFailure`'s card and of the `skipped` line in the sent offer: all three are
conditions no fixture produces.

**`BrowseEmptyState.emptyUnsorted` and `.onlySubcollections` are untested on screen.**
The fixture has neither shape — Unsorted always has items, and every collection with
children also has some of its own. The resolver's tests cover both; the screens have not
been seen.

**Nothing about the icon is a design.** It is the Mac's mark at 1024, and iOS renders it
for the dark and tinted appearances by deriving them. Whether a 1024 drawn for a desktop
reads at 60pt on a home screen is a judgement nobody has made.

**Two accessibility identifiers are still unqueried** — `notice.loading` and
`export.unreadable`. The lesson of this phase is precisely that an identifier no test
queries is an identifier that may not exist; these two are in that state by construction,
since neither condition can be produced from a launch argument.

**The simulator pin is a liability, stated.** `ios-ui-tests` and the `build-for-testing`
row both name iPhone 17. The day the runner image drops it, both go red for a reason that
is not the code. A generic destination is not available for either.

**The UI suites have run on one simulator, once each, on one machine.** Nine cases, all
green, but the share-sheet anchors in `ExportUITests` are the kind of thing that is fine
until an iOS release moves them — which is what the multi-anchor predicate and the 90 s
budget already exist for.

**Nothing has run on a device**, as in every changelog since 454. The full list of what
that costs is 098's "Left to the user", which this phase extended: the timing
measurement, the fling, the jetsam claim, the 64 MP cap against a real photograph, the
export folder lifecycle, the `URLSession` glue, the memory-warning purge, tier 2 on an
auth-walled page, T0, and the App ID that would let the tier-2 test run at all.

## Migration notes

**None for the library, the archive format or the inbox.** Nothing here changes a schema,
a file layout or a wire contract. The four Info.plist / asset-catalog changes are
identity, and an app already installed simply renames itself and grows an icon on the
next install.

Three source-compatible breaks, all inside this repository and all already updated:

- `CaptureExportController.Phase.sent(Int)` → `.sent(count: Int, skipped: Int)`.
- `CaptureExportController.Written.init` gains `skipped:`, **defaulted to 0** — and the
  default is a claim: a caller that omits it is saying its write left nothing behind.
- `InboxDrainScheduler.init(pass:onIngest:)` gains `onNotice:`, and
  `InboxDrainPolicy.report(_:onIngest:)` gains it too.

`ExportFailureNotice` is gone; `WarningNotice(message:identifier:)` replaces it and the
identifier `export.failure` is unchanged.

**One thing to know before adding an accessibility identifier:** put it on a leaf. A
`.accessibilityIdentifier` on a `VStack` renames every element inside it, which is how
`export.clear` and `export.keep` came to be spelled in the source and absent from the
element tree.
