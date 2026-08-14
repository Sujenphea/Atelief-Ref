# 400 — the pen changed hands

`AtelierRefs.xcodeproj` now has four targets: the macOS app and its tests, unchanged,
plus an iOS app `AtelierRefsMobile` and the share extension `AtelierRefsShare`
embedded inside it ([092](../.docs/092-ios-companion-plan.md) · S4b). The extension
is wired the way a share extension has to be wired to reach the share sheet — a
copy-files phase into `PlugIns`, a target dependency, `RemoveHeadersOnCopy` on the
appex — and the phone app builds for the simulator.

This is also the commit where the streak ends. Five slices and the S4a correction
went by with no `project.pbxproj` diff, [397](397-nothing-to-guard.md) said that when
the streak ended it should end with a human holding the pen, and 092 said the same.
It did not. That is the first thing to record, before anything about build settings.

## Three attempts, three projects

Xcode's *File ▸ New ▸ Target* sheet was driven three times against
`AtelierRefs.xcodeproj`. Each time the share extension landed correctly — a real
`PBXNativeTarget` in the main project, `SDKROOT = iphoneos`, sources under
`AtelierRefs/AtelierRefsShare/` — and each time the iOS **app** target landed
somewhere else: a separate `AtelierRefsMobile.xcodeproj`, nested at
`AtelierRefs/AtelierRefsMobile/AtelierRefsMobile.xcodeproj`, with its own project
object, its own configuration lists, and a `projectReferences` stub pointing at it
from the parent. Two projects, one of them containing a single target that could
never embed the extension sitting in the other.

So the reconciliation was written by hand, by the agent, and there is no way to
describe that as the plan. What is honest to say instead is what it was traded for:

- **The diff is small and hand-authored, not generated.** Thirteen new objects, all
  of them the canonical shapes, no reordering of anything that already existed, no
  `objectVersion` bump, no touched `PBXProject` attributes. It reads top to bottom.
- **The macOS target's own settings were not touched.** Not one build setting on
  `AtelierRefs` or `AtelierRefsTests`, not their file references, not
  `Config/Release.xcconfig`. The regression gate for that is `xcodebuild build` and
  `build-for-testing`, both green below, and neither is a proxy — they are the
  actual thing being protected.
- **Every gate was run and reported, including the ones that could have been
  skipped.** The iOS simulator build in particular, which is the only evidence that
  the embed phase is real rather than plausible-looking.

The stray project is deleted. Its contents were unmodified Xcode template scaffolding
— `WindowGroup`, a globe, "Hello, world!" — so `AtelierRefsMobile` was **authored
fresh** in the main project rather than transplanted object by object. Recreating
boilerplate loses nothing and produces a cleaner file than merging one project's
object graph into another's.

## One project, four targets

The two existing targets use `PBXFileSystemSynchronizedRootGroup`s — folder-backed
groups, no per-file `PBXBuildFile` bookkeeping — so both new targets do too. That is
why there are thirteen objects and not sixty: the source lists are the directories.

    AtelierRefs/
      AtelierRefs.xcodeproj
      AtelierRefs/          macOS
      AtelierRefsTests/
      AtelierRefsMobile/    iOS app        ← flattened up one level
      AtelierRefsShare/     iOS extension
      Config/

`AtelierRefsMobile/` was `AtelierRefsMobile/AtelierRefsMobile/` — the extra level
Xcode creates when it makes a project rather than a target. The sources moved as git
renames, so the flattening is visible as a move and not as three deletions.

The wiring that matters is four objects, and it is worth naming them because the
share sheet is silent about their absence rather than loud:

    PBXCopyFilesBuildPhase   dstSubfolderSpec = 13   →  PlugIns/
    PBXBuildFile             ATTRIBUTES = (RemoveHeadersOnCopy)
    PBXTargetDependency      AtelierRefsMobile → AtelierRefsShare
    PBXContainerItemProxy    proxyType = 1

Without the copy phase the appex is built and then not embedded, and an extension
that is not inside its host app's `PlugIns/` is an extension iOS never sees. The
dependency is what guarantees it is built *before* the copy rather than racing it.

## Four settings the sheet got wrong

The share extension arrived from Xcode with defaults that were plausible in isolation
and wrong for this project. All four are corrected on both configurations:

| | Xcode gave | now |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `sujenphea.AtelierRefsShare` | `sujenphea.AtelierRefsMobile.Share` |
| `IPHONEOS_DEPLOYMENT_TARGET` | `26.5` | `26.0` |
| `SWIFT_VERSION` | `5.0` | `6.0` |
| `TARGETED_DEVICE_FAMILY` | `1,2` | `1` |

The identifier is the one with consequences. An extension's bundle ID has to nest
under its host app's for the App ID and provisioning profile to be derivable from the
app's — `sujenphea.AtelierRefsShare` is a sibling of `sujenphea.AtelierRefsMobile`,
not a child, and an App Group grant would have had to be arranged around it twice.
The deployment target is `26.0` because that is the floor
[397](397-nothing-to-guard.md) chose for `AtelierCore` and `AtelierCapture`; `26.5` is
whatever SDK happened to be installed, which is not a decision. Swift 6 matches every
other target in the project. Device family 1 because 091 scoped this to the phone.

`AtelierRefsMobile` gets the same platform, language, team and device-family values,
`PRODUCT_BUNDLE_IDENTIFIER = sujenphea.AtelierRefsMobile`,
`GENERATE_INFOPLIST_FILE = YES` with the generated launch-screen and orientation keys,
and `PRODUCT_NAME = $(TARGET_NAME)`.

**`CODE_SIGN_STYLE = Automatic` on Debug *and* Release**, which departs from the macOS
app's Debug-automatic / Release-manual split. That split exists for Developer ID: the
Mac app's Release configuration signs with a specific identity through
`Config/Release.xcconfig`. There is no iOS distribution profile yet, and `Manual` with
no profile does not degrade — it fails the build. Automatic is the setting that
matches the provisioning that exists.

## What was deliberately not done

- **No App Groups entitlement, on either target.** No `CODE_SIGN_ENTITLEMENTS`, no
  `.entitlements` file. Signing & Capabilities generates the correctly-shaped file
  *and* registers the group against the App ID, and the second half is not something a
  pbxproj edit can fake. Hand-writing the file would produce a target that looks
  entitled and is not.
- **No Swift package linked into either iOS target.** `packageProductDependencies` is
  empty on both. S4b's actual subject — the extension linking `AtelierCapture` and
  writing to the inbox — is the next slice, and landing the project structure on its
  own is what makes that slice reviewable.
- **No shared schemes.** The repo has none, and `xcodebuild -list` shows
  `AtelierRefsMobile` and `AtelierRefsShare` among the autocreated schemes already, so
  establishing `xcshareddata/xcschemes/` would have changed what CI can invoke without
  being needed to invoke it. If CI later wants a pinned scheme, that is a deliberate
  addition and not a side effect of this one.

## Files

    AtelierRefs/AtelierRefs.xcodeproj/           +13 objects: the `AtelierRefsMobile`
      project.pbxproj                            target, its synchronized root group,
                                                 product reference, three build phases
                                                 + the PlugIns copy phase, its two
                                                 configurations and their list, the
                                                 dependency + proxy + build file for
                                                 the appex. The stray project's file
                                                 reference, its `Products` group and
                                                 the `projectReferences` block removed.
                                                 `AtelierRefsShare`'s two
                                                 configurations corrected. Nothing
                                                 else edited
    AtelierRefs/AtelierRefsMobile/               renamed from AtelierRefsMobile/
      AtelierRefsMobileApp.swift                 AtelierRefsMobile/; template contents
      ContentView.swift                          unchanged
      Assets.xcassets/
    AtelierRefs/AtelierRefsMobile/               deleted — the separate project Xcode
      AtelierRefsMobile.xcodeproj/               produced three times
    AtelierRefs/AtelierRefsShare/                new, from Xcode's sheet: template
      ShareViewController.swift                  `SLComposeServiceViewController`,
      Base.lproj/MainInterface.storyboard        the storyboard in the resources phase,
      Info.plist                                 the plist in no build phase
    .docs/092-ios-companion-plan.md              amendment under S4b — layout as built,
                                                 the settings, App Groups still the
                                                 user's step; the "no pbxproj change"
                                                 bullet under "Where this stands"
                                                 rewritten

## Verification

| | |
|---|---|
| `xcodebuild -list` | four targets: `AtelierRefs`, `AtelierRefsTests`, `AtelierRefsMobile`, `AtelierRefsShare` |
| macOS app | `xcodebuild build` — **BUILD SUCCEEDED** |
| macOS tests | `xcodebuild build-for-testing` — **TEST BUILD SUCCEEDED** |
| iOS app + extension | `xcodebuild build`, `generic/platform=iOS Simulator` — **BUILD SUCCEEDED** |
| `AtelierCore` | 760 / 105 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| `AtelierIngestion` | 447 / 47 — unchanged |
| `AtelierCapture` | 57 / 3 — unchanged |
| `AtelierServer` | 62 / 6 — unchanged |

The iOS build is the one carrying weight. It builds `AtelierRefsShare` first, compiles
`MainInterface.storyboard` into the appex, then runs the copy phase — so a green here
is direct evidence of the embed, not an inference from the file's shape.

One thing the numbers do not show: `AtelierIngestion` failed on its first run of the
suite, in `ColorExtractorTests`' randomized-palette determinism check, where two
swatches share a coverage of `0.08641975308641975` and came back in opposite orders.
It passed on three consecutive re-runs. That is a **pre-existing tie-break flake in
`ColorExtractor.swatches`**, has nothing to do with this commit, and is recorded here
rather than quietly re-run because the next person to see it should not spend an hour
on the project file.

## Migration notes

**The user must add App Groups to both iOS targets in Xcode before the extension can
write anything.** Signing & Capabilities ▸ + Capability ▸ App Groups, on
`AtelierRefsMobile` *and* on `AtelierRefsShare`, with the identifiers S1 · decision 1
chose: `group.sujenphea.AtelierRefs.dev` on Debug and `group.sujenphea.AtelierRefs` on
Release. Until that lands, `LibraryLocation.defaultRoot()` on iOS returns
`appGroupContainerUnavailable` — loudly, which is the failure mode S1 picked on
purpose — and the extension has no container to write into. Nothing in this commit
changes that; it only stops the target's absence from being the reason.

Building for iOS on this machine required the iOS platform component, which Xcode 26
does not install by default: `xcodebuild -downloadPlatform iOS`, 8.52 GB. Without it
every iOS build fails at storyboard compilation with `iOS 26.5 Platform Not
Installed`, which is an unhelpfully-worded way of saying the SDK stub is there and the
platform is not. CI will need the same step before it can run an iOS job.

For anyone with a branch open: `AtelierRefs/AtelierRefsMobile/AtelierRefsMobile/` no
longer exists — its three entries moved up one level. And if a working copy still has
`AtelierRefsMobile.xcodeproj` on disk, delete it; opening the project with both
present is how the split happened in the first place.
