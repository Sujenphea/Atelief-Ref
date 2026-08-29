# 398 — a seam iOS could not reach

`LibraryLocation` moves from `AtelierIngestion` to `AtelierCapture`
([092](../.docs/092-ios-companion-plan.md) · S1, corrected during S4a). The type is
unchanged, its 14 tests are unchanged, and every macOS caller resolves the same root
it resolved yesterday. What changes is that the one process the type was written for
can now link it.

Nothing was broken. That is what made this worth finding on purpose rather than in
S4b's first hour: a seam with no caller compiles, tests green, and reads as finished.

## The defect

S1 built the App Group branch inside `defaultRoot()` — the `containerURL(for
SecurityApplicationGroupIdentifier:)` lookup, the typed `LibraryLocationError`, the
`completeUntilFirstUserAuthentication` data-protection class — **specifically so the
iOS share extension could find the library root it writes into**. Then it put the
file in `AtelierIngestion/Sources/AtelierIngestion/Media/`.

`AtelierIngestion` imports AppKit. One file, `Input/DirectInputReader.swift`, and
within it only the `NSPasteboard` paths — but that is enough: the package declares
`.macOS("26.0")` and nothing else, does not build for iOS, and 397 recorded that it
is not in scope to. So the share extension had no reachable way to call
`defaultRoot()`. The whole `#if os(iOS)` region was written for a caller that could
not exist.

397 spotted this while cross-building the packages and wrote it down as S4b's first
bullet. This is that bullet, discharged before S4b starts rather than during it,
because "where does the extension get its root" is not a question you want open while
also arguing with provisioning profiles.

## Why AtelierCapture

Because it is already the answer to this exact question, asked once before.

S2 needed the inbox's directory name in both the extension that appends to it and the
host that drains it, put `InboxLayout` in `AtelierCapture`, and had
`LibraryLayout.inbox` delegate rather than spell `"inbox"` twice. The reasoning in
that file's header transfers word for word: the package is transport-free and
platform-free by construction, it has no product dependency beyond `AtelierCore`, it
compiles for iOS 26 since S4a, and it is already on the extension's link line.

So this is **the second time the AppKit boundary has pulled a type out of
`AtelierIngestion`**, and both times for the same reason — the type belonged to the
handoff, not to the pipeline. Worth naming as a pattern: `AtelierIngestion` is where
the host processes captures, and anything both sides of the process boundary need to
agree on does not live there. If a third type makes this trip, the boundary is the
finding and not the type.

The macOS library's own arrangement is untouched, and the header still says why:
Application Support on macOS, App Group container on iOS, and **the macOS library
deliberately does not move into a macOS App Group** — it would cost a migration of
every existing library for zero gain, since macOS has no share extension to share
with. The divergence is the design.

## Two imports, not a re-export

`AtelierIngestion` has depended on `AtelierCapture` since S2, so the macOS callers
could have kept compiling untouched behind an `@_exported import` in
`AtelierIngestion`. They do not. There are exactly two call sites —
`IngestionModel.bootstrap()` and `BakeoffSeedTests`'s seeding rail — and each gained
one `import AtelierCapture` line.

Two lines is less churn than a re-export, and a re-export would actively mislead
here: it would let the app keep believing `LibraryLocation` is an ingestion type at
the precise moment the extension is about to link it directly from somewhere else.
The import that tells you where the type lives is the cheaper one to read in six
months.

No `project.pbxproj` change was needed for it. `AtelierCapture` was already on the
app's link line transitively through `AtelierIngestion`, which is the same
transitive-resolution property that has kept five slices out of the Xcode project
file. Adding an explicit product reference was written, tested green, and then
reverted: it is not required to build, and 397 was explicit that when the streak ends
it should end with a human holding the pen. S4b is that moment, not this.

## The tests moved with no edit, which is the proof

Both files landed as **git renames**, not delete-plus-add, so blame survives. The
test file's diff is a header paragraph and one import line:

    -@testable import AtelierIngestion
    +import AtelierCapture

`@testable` went with it — everything the suite touches is `public`, and the sibling
suites in `AtelierCaptureTests` import plainly. Not one assertion changed, and that
is the load-bearing fact rather than a tidiness note: the suite's first job is a
regression fence saying *the App Group work did not move the macOS root by a byte*,
and if a byte had moved here, an assertion would have had to.

## A comment that was wrong about extensions

S1's doc comments called `Bundle.main` "the host bundle". In an app extension
`Bundle.main` is the **extension's own** bundle — an extension gets no reading of its
container app's Info.plist — so the extension needs its own copy of the
`AtelierAppGroupIdentifier` key, fed by the same `$(ATELIER_APP_GROUP)`
per-configuration build setting. The code was always right; only the prose implied
one plist would serve both. Corrected in place, and the plist wiring is still S4b's
job, now stated as two plists and one build setting rather than left to be inferred.

## Files

    AtelierCapture/Sources/AtelierCapture/           renamed from AtelierIngestion/
      LibraryLocation.swift                          Sources/AtelierIngestion/Media/;
                                                     header rewritten for its new
                                                     home and why it moved;
                                                     `Bundle.main` comments corrected;
                                                     S4 → S4b reference. No behaviour
                                                     change
    AtelierCapture/Tests/AtelierCaptureTests/        renamed from AtelierIngestion/
      LibraryLocationTests.swift                     Tests/AtelierIngestionTests/;
                                                     header + import only, zero
                                                     assertion edits
    AtelierIngestion/Package.swift                   dependency comment now names
                                                     both types the AppKit boundary
                                                     pushed across
    AtelierRefs/AtelierRefs/IngestionModel.swift     `import AtelierCapture`
    AtelierRefs/AtelierRefsTests/                    `import AtelierCapture`
      BakeoffSeedTests.swift
    .docs/092-ios-companion-plan.md                  amendment under S1; S4a note 4
                                                     marked resolved; S4b's first
                                                     bullet rewritten from open
                                                     problem to remaining plist work;
                                                     "Where this stands" updated

No `project.pbxproj` change, for the sixth time.

## Verification

| | |
|---|---|
| `AtelierCapture` | 43 / 2 → **57 / 3** — the 14 arrivals |
| `AtelierIngestion` | 461 / 48 → **447 / 47** — the 14 departures |
| combined | 504 tests / 50 suites, before and after |
| `AtelierCore` | 760 / 105 — unchanged |
| `AtelierServer` | 62 / 6 — unchanged |
| `AtelierCapture` iOS build | **Build complete**, `LibraryLocation.swift` among the compiled |
| `AtelierCore` iOS build | **Build complete** |
| app | `xcodebuild build` — **BUILD SUCCEEDED** |
| app tests | `xcodebuild build-for-testing` — **TEST BUILD SUCCEEDED** |

43 + 461 = 504 = 57 + 447. The arithmetic is the assertion: no test was added,
deleted, renamed or skipped, only relocated.

The iOS cross-build is the one that matters, and it is the first time the container
lookup and the `.protectionKey` call have been compiled by anything at all rather
than type-checked as a stopgap. Both need the `--sdk` flag; `--triple` alone leaves
SwiftPM on the host macOS SDK, as 397 recorded.

## Migration notes

None for users. No stored shape, no on-disk layout, no wire shape, no endpoint. The
macOS Library root is `<Application Support>/ref-atelier/` before and after, the
`-library-root` / `ATELIER_LIBRARY_ROOT` override branch is untouched, and the
throwaway libraries the bake-offs open resolve identically.

For anyone with a branch open: `LibraryLocation` and `LibraryLocationError` are now
`AtelierCapture` symbols. A file that uses either needs `import AtelierCapture`
alongside its existing `import AtelierIngestion` — there is no re-export, so the
failure is a plain "cannot find in scope" at compile time and not a silent one.
`AtelierIngestion` already depends on `AtelierCapture`, so no manifest edit is
involved; in the Xcode project the module resolves transitively and needs no link-line
change either.

One thing S4b still owns, sharpened rather than removed: the extension reads
`AtelierAppGroupIdentifier` from its **own** Info.plist, because `Bundle.main` in an
extension is the extension. Two plists, one `$(ATELIER_APP_GROUP)` build setting, one
identifier — and a mismatch between them is `appGroupContainerUnavailable`, loudly,
which is the failure mode S1 · decision 3 chose on purpose.
