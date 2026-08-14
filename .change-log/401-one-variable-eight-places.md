# 401 — one variable, eight places

`LibraryLocation.defaultRoot()` resolves on iOS. Launched on a simulator, the phone
app now prints a real App Group container path — `…/Containers/Shared/AppGroup/
4B816AA9-…/ref-atelier` — rather than the `appGroupContainerUnavailable` that
[398](398-a-seam-ios-could-not-reach.md) promised it would print loudly until this
slice landed. This is **S4b-i** ([092](../.docs/092-ios-companion-plan.md) · S4b):
the wiring only. The share extension still does nothing when you share to it; that is
S4b-ii.

The user added the App Groups capability through Signing & Capabilities, which is the
half no pbxproj edit can fake — it registers the group against the App ID. What that
produced was two entitlements files each naming a literal `group.sujenphea.AtelierRefs`.
Everything below is what turns those two literals into one variable.

## One variable, eight places

`ATELIER_APP_GROUP` is a user-defined build setting, defined four times — twice per
iOS target, once per configuration:

| | `AtelierRefsMobile` | `AtelierRefsShare` |
|---|---|---|
| Debug | `group.sujenphea.AtelierRefs.dev` | `group.sujenphea.AtelierRefs.dev` |
| Release | `group.sujenphea.AtelierRefs` | `group.sujenphea.AtelierRefs` |

The split by configuration is S1 · decision 1, and it mirrors the bundle-ID split the
app already had. One identifier across both would put a dev build and a release build
into the same library — which is not a tidiness question but a data question: the
throwaway captures you make while debugging the extension would land in the library
you actually keep.

From those four definitions the value fans out to eight consumers, four per
configuration:

    $(ATELIER_APP_GROUP)
      ├─ AtelierRefsMobile.entitlements  →  com.apple.security.application-groups
      ├─ AtelierRefsMobile/Info.plist    →  AtelierAppGroupIdentifier
      ├─ AtelierRefsShare.entitlements   →  com.apple.security.application-groups
      └─ AtelierRefsShare/Info.plist     →  AtelierAppGroupIdentifier

The two axes are not interchangeable. The **entitlement** is what the system grants a
process; the **plist key** is what the process asks for, since that is what
`LibraryLocation.appGroupIdentifier()` reads. A build where those two disagree
compiles, signs, installs and launches, and then hands the app and its extension
different containers — the exact failure S1 · decision 3 refused to paper over with a
`container ?? applicationSupport` fallback. Feeding both from one variable is the only
arrangement in which they cannot drift, and it is why the entitlements files no longer
contain a literal at all.

## Why two of everything is not duplication

`Bundle.main` inside an app extension is the **extension's own** bundle. An extension
gets no reading of its container app's Info.plist, so the share extension cannot
inherit the host's `AtelierAppGroupIdentifier` — it needs its own copy, and its own
entitlements file besides. 398 corrected a comment that implied otherwise; this is the
commit where the correction has consequences, and both plists carry a comment saying
so, because the shape invites exactly the simplification that would break it.

## The key Xcode would not generate

`AtelierRefsMobile` had `GENERATE_INFOPLIST_FILE = YES` and no plist on disk, so the
key was first written as `INFOPLIST_KEY_AtelierAppGroupIdentifier = "$(ATELIER_APP_GROUP)"`.
The build succeeded. No warning, no note, nothing in the log — and the key was **not
in the generated Info.plist**:

    plutil -extract AtelierAppGroupIdentifier raw …/AtelierRefsMobile.app/Info.plist
    → Could not extract value … No value at that key path

`INFOPLIST_KEY_*` covers the Info.plist keys Xcode knows about; an arbitrary name is
accepted by the build system and then silently dropped. Had this shipped, the symptom
would have surfaced only at runtime, as `appGroupIdentifierMissing` on the app while
the extension worked fine — which reads as an extension bug and is not one. It is
worth naming because the setting *looks* like it worked: a green build proves nothing
here, and only reading the key back out of the built product does.

The fix is the pattern this project already uses twice. `AtelierRefsMobile/Info.plist`
now exists, carrying that one key, with `GENERATE_INFOPLIST_FILE` left **YES** — Xcode
merges the generated keys over the file as a base, so the launch screen, scene manifest
and orientations still arrive as `INFOPLIST_KEY_*` settings and the built plist has all
of them plus ours. The macOS app has done this since it existed (`INFOPLIST_FILE =
Info.plist` beside `GENERATE_INFOPLIST_FILE = YES`) and so has `AtelierRefsShare`.

One thing that comes with it: the file sits inside a `PBXFileSystemSynchronizedRootGroup`,
which would otherwise copy it into the bundle as a resource on top of the real one, so
`AtelierRefsMobile` gains a `PBXFileSystemSynchronizedBuildFileExceptionSet` listing
`Info.plist` — the same object `AtelierRefsShare` already had, for the same reason.

## `AtelierCapture` on two link lines

The first Swift package linked into either iOS target. `AtelierCapture` becomes the
project's sixth `XCLocalSwiftPackageReference`, with a product dependency and a
frameworks build-file per target: the extension needs `LibraryLocation` now and
`InboxWriter` next slice, and the app needs `LibraryLocation` for the diagnostic below.
`AtelierCore` and GRDB arrive transitively, which 395 already established is not
reachable to avoid and is a footprint measurement rather than an assertion.

Nothing else is linked. `AtelierIngestion` imports AppKit, and `AtelierServer`,
`AtelierExport` and `CanvasRenderer` are things the phone does not do — none of the
four builds for iOS, and none is a candidate.

## A placeholder that says it is one

`ContentView.swift` loses the template globe and gains a `VStack` that calls
`defaultRoot()` once and shows the path or the thrown `LibraryLocationError`. It is marked in
its first line as temporary, and [093](../.docs/093-ios-visual-design.md) replaces the
whole file in S5. No `Theme`, no styling beyond a monospaced footnote — the point is
that the wiring is observable on a simulator without attaching a debugger, not that the
app has a screen.

## Files

    AtelierRefs/AtelierRefsMobile/                new, from Signing & Capabilities;
      AtelierRefsMobile.entitlements              literal group replaced by
                                                  $(ATELIER_APP_GROUP), with the
                                                  indirection explained in a comment
    AtelierRefs/AtelierRefsMobile/Info.plist      new — one key, `AtelierAppGroupIdentifier`,
                                                  because INFOPLIST_KEY_<arbitrary>
                                                  does not reach a generated plist
    AtelierRefs/AtelierRefsMobile/                template globe/"Hello, world!"
      ContentView.swift                           replaced by the `defaultRoot()`
                                                  diagnostic; temporary, 093 · S5
                                                  replaces it
    AtelierRefs/AtelierRefsShare/                 new, from Signing & Capabilities;
      AtelierRefsShare.entitlements               same substitution
    AtelierRefs/AtelierRefsShare/Info.plist       `AtelierAppGroupIdentifier` added —
                                                  the extension reads its OWN bundle
    AtelierRefs/AtelierRefs.xcodeproj/            ATELIER_APP_GROUP on all four iOS
      project.pbxproj                             configurations; INFOPLIST_FILE on
                                                  AtelierRefsMobile; the exception set
                                                  for its Info.plist; AtelierCapture as
                                                  a local package reference, two product
                                                  dependencies and two frameworks build
                                                  files. Nothing macOS touched
    .docs/092-ios-companion-plan.md               S4b amended — this is S4b-i, and what
                                                  S4b-ii still owns; "Where this stands"
                                                  updated

## Verification

| | |
|---|---|
| macOS app | `xcodebuild build` — **BUILD SUCCEEDED** |
| macOS tests | `xcodebuild build-for-testing` — **TEST BUILD SUCCEEDED** |
| iOS Debug | `xcodebuild build`, `generic/platform=iOS Simulator` — **BUILD SUCCEEDED** |
| iOS Release | same — **BUILD SUCCEEDED** |
| `AtelierCore` | 760 / 105 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| `AtelierIngestion` | 447 / 47 — unchanged, and no tie-break flake this time |
| `AtelierCapture` | 57 / 3 — unchanged |
| `AtelierServer` | 62 / 6 — unchanged |

The builds are the gate; the deliverable is what is inside the products. Both
configurations were built signed for the simulator and all four values read back out:

| | Debug | Release |
|---|---|---|
| app Info.plist | `group.sujenphea.AtelierRefs.dev` | `group.sujenphea.AtelierRefs` |
| appex Info.plist | `group.sujenphea.AtelierRefs.dev` | `group.sujenphea.AtelierRefs` |
| app entitlements | `group.sujenphea.AtelierRefs.dev` | `group.sujenphea.AtelierRefs` |
| appex entitlements | `group.sujenphea.AtelierRefs.dev` | `group.sujenphea.AtelierRefs` |

Eight strings, four agreements. A disagreement in any column is the bug, not a
cosmetic mismatch.

Then the thing none of that quite proves. `AtelierRefsMobile` installed and launched on
an iPhone 17 simulator shows

    Library root
    /Users/…/Devices/F17252BB-…/data/Containers/Shared/AppGroup/4B816AA9-…/ref-atelier
    App Group: group.sujenphea.AtelierRefs.dev

and `ref-atelier/` exists on disk under that shared-container UUID afterwards, which
means `defaultRoot()` created it — the container lookup, the directory creation and the
`completeUntilFirstUserAuthentication` attribute all ran, in that order, in a real
process. That is the first time S1's `#if os(iOS)` branch has *executed* rather than
merely compiled.

Two traps for whoever repeats this. The simulator's entitlements live in
`…-Simulated.xcent`; the plain `.xcent` beside it is an empty dict and `codesign -d
--entitlements -` on a simulator bundle reports nothing, so both look like failures and
neither is. And `plutil -extract <key> json <file>` **overwrites the file** when `-o` is
omitted — it will happily reduce a built Info.plist to the one value you asked about.
Use `raw`, or `-o -`.

## Migration notes

None for users; nothing ships on iOS yet. The macOS app is untouched — no macOS build
setting, entitlement or plist key changed, and `Config/Release.xcconfig` was not opened.

For anyone with a branch open: `AtelierRefs/AtelierRefsMobile/Info.plist` is new and
`INFOPLIST_FILE` is now set on that target, so a merge that keeps the old
`GENERATE_INFOPLIST_FILE`-only configuration will build green and silently lose the App
Group key. The check is one command against the built app, not a look at the diff:

    plutil -extract AtelierAppGroupIdentifier raw \
      "$(xcodebuild -project AtelierRefs/AtelierRefs.xcodeproj -scheme AtelierRefsMobile \
         -configuration Debug -showBuildSettings 2>/dev/null \
         | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2}')/AtelierRefsMobile.app/Info.plist"

Never define `ATELIER_APP_GROUP` at the project level or in an xcconfig shared with
macOS. It is deliberately per-target and per-configuration: a project-level default
would be inherited by the two macOS targets, which have no App Group and must not
acquire one (S1 is explicit that the Mac library stays in Application Support).

Adding a third iOS target later — a widget, an action extension — means all four
things, not one: the build setting on both its configurations, an entitlements file,
`AtelierAppGroupIdentifier` in whatever plist it actually has, and a link to
`AtelierCapture`. Three of the four are silent when omitted.
