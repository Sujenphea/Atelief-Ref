# 394 — only the base differs

The second slice of the iOS companion ([092](../.docs/092-ios-companion-plan.md) ·
S1). Nothing about the macOS build changes; what changes is that
`LibraryLocation.defaultRoot()` now has a shape that can answer the iOS question
without answering the macOS one differently.

`defaultRoot()` resolved Application Support and appended `ref-atelier`. On iOS that
directory is per-process: the app and the share extension are separate processes with
separate containers, so the record the extension writes lands somewhere the app will
never look. The root has to come from
`containerURL(forSecurityApplicationGroupIdentifier:)` instead ([091](../.docs/091-ios-companion-overview.md)
· D3).

The change is smaller than that makes it sound, because the difference between the two
platforms is exactly one URL. `defaultRoot()` is now *resolve a base, then
`libraryRoot(under:)`* — and `libraryRoot(under:)` is platform-free, so the naming and
creation behaviour cannot drift between an iPhone and a Mac. The `#if os(iOS)` region
is the container lookup and nothing else.

## A nil container is a bug, not a condition

The tempting shape is `container ?? applicationSupport`. It is wrong, and it is wrong
in a way that would take a long time to diagnose.

A missing container means the App Group is not provisioned — the entitlement is absent,
or the identifier is misspelled, or the profile is stale. With a fallback, the app
opens a library and works. The extension also opens a library and works. They are
different libraries, and the way that presents to the user is that shares vanish: the
share sheet reports success, the app shows nothing, and no error is logged anywhere
because nothing failed.

So `LibraryLocationError` has two cases — `appGroupIdentifierMissing(key:)` and
`appGroupContainerUnavailable(identifier:)` — each carrying what it looked for, and
both fatal to opening the library. A provisioning bug should fail at the place where it
is fixable.

## The identifier comes from Info.plist

The App Group name is neither a constant in this package nor a caller parameter. It is
an Info.plist key, `AtelierAppGroupIdentifier`, whose value in the project is
`$(ATELIER_APP_GROUP)` — a per-configuration build setting, so Debug resolves
`group.sujenphea.AtelierRefs.dev` and Release resolves `group.sujenphea.AtelierRefs`,
mirroring the bundle-ID split the app already has at
`AtelierRefs.xcodeproj/project.pbxproj:377,413`.

A constant would have to be a constant *pair* and would then have to know which build
it is in. A parameter would push the same question onto every call site, including the
extension's. The plist is the one place that is already next to the entitlement
granting the container, and both processes read their own.

The plist and build-setting wiring is S4. This slice builds the read side: the key
constant, and `appGroupIdentifier(rawValue:)`, which takes the raw string as a
parameter defaulted to the `Bundle.main` lookup — so its two failure paths (absent,
blank) are tested on macOS rather than waiting for a device.

## The macOS library stays where it is

Deliberately, and recorded in the file. Moving it into a macOS App Group would make one
rule cover both platforms and would cost a data migration of every existing library for
nothing: macOS has no share extension to share with. The divergence is the design.

The `-library-root` / `ATELIER_LIBRARY_ROOT` branch is likewise untouched, on both
platforms. A throwaway library is by definition not shared with an extension, and the
bake-off and scratch-library paths must resolve byte-identically — relative to a
sibling under Application Support, absolute verbatim, blank ignored.

## The data-protection gate

Creating the root on iOS now sets `.protectionKey` to
`completeUntilFirstUserAuthentication` explicitly. The inherited default can be
`completeUnlessOpen`, under which a background drain that starts while the phone is
locked cannot open the SQLite files at all — a failure that reproduces on a real locked
device and nowhere else, which is the worst kind to find late. This is iOS-only API and
sits in the second small `#if os(iOS)` region.

## Files

    AtelierIngestion/Sources/AtelierIngestion/Media/LibraryLocation.swift
                                                        `LibraryLocationError`;
                                                        `appGroupIdentifierKey`;
                                                        `appGroupIdentifier(rawValue:)`;
                                                        `libraryRoot(under:)`;
                                                        `defaultBase()` + `protectAtRest`
                                                        behind `#if os(iOS)`
    AtelierIngestion/Tests/AtelierIngestionTests/LibraryLocationTests.swift
                                                        new — 14 tests
    .docs/092-ios-companion-plan.md                      S1 "As built" note

427 ingestion tests in 45 suites before → 441 in 46 after. `AtelierServer` 62 and
`AtelierCapture` 23 unchanged, all passing; the app's `xcodebuild build` succeeds.

The iOS branch cannot be built by `swift test` — the package is macOS-only and stays
that way this slice — so it was type-checked directly against the iPhoneOS SDK
(`swiftc -typecheck -target arm64-apple-ios18.0`, which the file passes, importing only
Foundation).

## Migration notes

None for users, and none for the build. The macOS root, its creation behaviour and the
override branch are unchanged; no package gained a platform, a dependency, or a CI job.

No iOS code path exists yet. `defaultBase()`'s App Group branch is compiled out
everywhere this repo currently builds, and it will stay inert until S4 adds the iOS
targets, the `ATELIER_APP_GROUP` build setting, the `AtelierAppGroupIdentifier`
Info.plist entry and the App Group entitlement. Until all four are present, the branch
throws rather than resolving anything — which is the intended behaviour, not a gap.
