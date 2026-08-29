# 448 — the boundary was the finding

092 · S4b wrote a tripwire into its own inheritance list:

> The second time the AppKit boundary has relocated a type; **if a third one appears, the
> boundary is the finding, not the type.**

The third appeared. S5 moved `LibraryMediaPaths` into `AtelierCapture` and recorded it as a
finding — *"that is the THIRD type the AppKit boundary has pulled out of that package"* —
without acting on the rule the previous slice had written. This acts on it, at the smaller of
the two available scales.

## What `AtelierCapture` had become

| responsibility | files | LOC |
|---|---|---:|
| the capture wire contract | `CaptureDTO` | 447 |
| the inbox handoff | `InboxRecord`, `InboxLayout`, `InboxWriter` | 788 |
| tier-2 page extraction | `PageHarvest`, `PageExtractor`, `ShareCapture` | 974 |
| **library filesystem knowledge** | `LibraryLocation`, `LibraryMediaPaths` | **440** |

Four jobs in a package named *Capture*, and the fourth has nothing to do with capturing
anything. Each arrival was individually correct — `InboxLayout` in S2, `LibraryLocation` in
S4a, `LibraryMediaPaths` in S5 — because `AtelierIngestion` imports AppKit
(`Input/DirectInputReader.swift`) and cannot build for iOS at all, so anything the phone
needs has to escape it one type at a time.

The visible cost was the dependency arrow. `AtelierIngestion` depended on `AtelierCapture`
purely to reach `LibraryLayout.inbox` and the library root: the **ingestion** package
depending on the **capture** package for path arithmetic.

## `AtelierLibraryPaths`, and one thing that confirmed the split

A new package holding the two path types and their 25 tests. Zero dependencies — neither
file imports `AtelierCore`, only Foundation and UniformTypeIdentifiers.

**And `AtelierCapture` does not depend on it.** Grepping its sources for real (non-comment)
uses of either type returned nothing: they were pure passengers, sharing a package with code
that never called them. That is a stronger argument for the split than the tidiness one, and
it was not the expected answer — the plan assumed `AtelierCapture` would keep a dependency.

A leaf that everything can reach and that reaches nothing is what makes it linkable from the
Mac app, the phone, the share extension and a UI-test runner alike.

## What this is NOT

Fixing the actual boundary — making `DirectInputReader`'s AppKit surface conditional so
`AtelierIngestion` builds for iOS — would also unblock the drain on the phone, which is S5's
second finding and the largest hole in the v1 story. S5 investigated with the code in hand
and declined: `InboxDrain` and `RemoteImageFetcher` both call that file, so dropping it on
iOS takes the drain with it. That remains true and remains a project measured in weeks,
sitting directly across the path of tier 3.

This is the smaller honest move: stop the relocation reflex, and let the arrow point
somewhere defensible. The manifests say so, in the places a fourth relocation would be typed.

## The part that needed real work

The imports were mechanical — 16 files across four packages and five app targets. The
`project.pbxproj` was not.

**Transitive resolution compiles but does not link.** 092 · S0 recorded that Xcode resolved
`AtelierCapture` transitively through a path dependency and *"the app target built
untouched"*, so the first attempt here was imports only. The Swift compiler found the module;
`AtelierRefsShare` then failed with `clang: error: linker command failed`. A module reachable
for `import` is not a library on the link line, and five targets needed the real wiring: an
`XCLocalSwiftPackageReference`, plus a distinct `XCSwiftPackageProductDependency` and
`PBXBuildFile` per target — Xcode requires the pair per target, which is why every existing
package in this project has one set for each of its consumers.

## Files changed

- `AtelierLibraryPaths/` — new package: `Package.swift`, the two moved sources, the two
  moved test files (`git mv`, so history follows).
- `AtelierCapture` — loses both files and their tests: **132 → 107 tests**, with the missing
  25 now green in the new package. Same total, as an extraction should be.
- `AtelierBrowse`, `AtelierArchive`, `AtelierIngestion` — manifest dependency plus imports.
- `AtelierRefs.xcodeproj/project.pbxproj` — the package reference and five targets' worth of
  link wiring.
- `.github/workflows/ci.yml` — added to both matrices (`swift-packages`, `ios-packages`);
  the `ios-packages` comment claiming the path math lives in AtelierCapture is corrected
  rather than left to mislead the next reader.
- `AtelierIngestion/Package.swift` — the comment explaining why the arrow points at
  AtelierCapture now explains what left it, and why.

## Verification

| | |
|---|---|
| `swift test` × 7 packages | 25 + 107 + 40 + 56 + 467 + 62 + 771 = **1,528 tests**, all passing |
| `swift build --triple arm64-apple-ios26.0` | AtelierLibraryPaths compiles for iOS |
| `xcodebuild build -scheme AtelierRefsMobile` | BUILD SUCCEEDED |
| `xcodebuild build-for-testing` | TEST BUILD SUCCEEDED |
| `xcodebuild test -only-testing:AtelierRefsTests` | TEST SUCCEEDED |

## Migration notes

Anything using `LibraryLocation` or `LibraryMediaPaths` needs `import AtelierLibraryPaths`
and the package on its link line. No API changed — the types, their members and their
behaviour are byte-identical to where they sat before.
