# 397 — nothing to guard

The fifth slice of the iOS companion ([092](../.docs/092-ios-companion-plan.md) ·
S4a). `AtelierCore` and `AtelierCapture` now compile for iOS 26, which is what the
share extension needs in order to link them at all.

The interesting part of this slice is how little of it there is. The plan budgeted
an audit — find the macOS-only API in `Services/` and `Persistence/`, guard it,
inventory what the phone loses. There was none. Both packages build clean for
`arm64-apple-ios26.0` with **zero source changes**, no `#if os(macOS)`, no
`@available`, and a public surface that is identical on both platforms. The whole
change is two lines of manifest and a CI job that keeps it that way.

## S4 was two slices wearing one number

092 · S4 bundled *make the packages compile for iOS* with *create the Xcode targets
that link them*. They share a slice number and nothing else. The first is pure
Swift, needs no provisioning, no simulator and no `project.pbxproj` change; the
second is entitlements, plists, and two new targets. And the first gates the second
completely — nothing links `AtelierCapture` on iOS until `AtelierCapture` builds on
iOS.

So S4a is this: the package-level audit, landed on its own terms the way S0–S3 did.
S4b is the target work, and it is not blocked on an unknown-size port any more,
because the port turned out to be nothing.

The division of labour in S4b is settled too: the user creates the two Xcode targets
by hand, and everything else — sources, Info.plist keys, entitlements, the
`ATELIER_APP_GROUP` per-configuration build setting — is written here. Five slices
have now gone by with no `project.pbxproj` diff; when that streak ends it should end
with a human holding the pen, not a tool.

## The blocker was a declaration, not a dependency

The symptom 395 and 396 both recorded was:

    error: the library 'AtelierCore' requires ios 12.0, but depends on the
    product 'GRDB' which requires ios 13.0

That reads like a version conflict and is not one. No package declared an
`.iOS(...)` platform, so SwiftPM assumed the language default of iOS 12 for
`AtelierCore` — a floor nobody chose, asserted against a dependency that had chosen
one. Adding the line resolves it in the only direction that was ever available.

**The floor is `26.0`, mirroring `.macOS("26.0")`, and it is not derived from the
APIs used.** Both packages only ever ship inside a macOS 26 app or an iOS 26 app,
built from the same sources by the same toolchain. Deriving a lower floor from what
the code happens to call today would buy `@available` guards for OS versions nothing
installs, and would make the next modern API a negotiation — the exact phantom
constraint `AtelierCore`'s manifest comment already describes talking itself out of
when the macOS pin read `.v14`. Same string form for the same reason: the
`SupportedPlatform` enum stops at `.v15` under swift-tools-version 6.0.

Scope is those two packages only. `AtelierIngestion` imports AppKit — `NSPasteboard`
in `Input/DirectInputReader.swift`, which reads a real pasteboard and real drag
providers — and is host-side by design. `AtelierServer`, `CanvasRenderer` and
`AtelierExport` are things the phone does not do. Declaring `.iOS(...)` on any of
them would be claiming a port that has not happened.

## Nothing to guard

The audit ran and came back empty, which is worth recording precisely because a
future reader will assume it was skipped.

`AtelierCore`'s 30-odd sources import exactly three things: Foundation, GRDB, and
`Accelerate` (in `Services/AppServices.swift`). All three are iOS frameworks.
`Persistence/` is GRDB and Foundation throughout. The single `NSFont` in the tree is
a word inside a doc comment on `SpaceItem.swift:55`. `AtelierCapture` adds
`CoreGraphics`, `ImageIO` and `UniformTypeIdentifiers` — in its *test-support*
target, and all of them cross-platform too.

That is not luck. It is S0's boundary holding: `AtelierCapture` was extracted with
"zero product dependencies beyond `AtelierCore`, and nothing about transport" as its
stated rule, and `AtelierCore` was built as a standalone package specifically so the
persistence layer had a hard edge. A package that already refuses AppKit for
architectural reasons does not need to be talked out of it for platform ones.

So there is **no public-surface divergence between macOS and iOS**. S5 sees the same
`AppServices`, the same domain types, the same errors, on both. Whatever S5 turns
out to be hard for, it will not be this.

The 218-task iOS build is also the real proof the earlier slices' stopgap could not
give: 395 and 396 both type-checked their new sources with `swiftc -typecheck
-target arm64-apple-ios26.0` and a *stubbed* capture contract, because a real build
was impossible. Those stubs are gone; the whole graph, GRDB included, compiles.

## `--triple` alone does not work

Worth writing down, because the plan recorded the command and the command is
incomplete. `swift build --triple arm64-apple-ios26.0` gets past dependency
resolution once the platform is declared, and then fails every single target with:

    <unknown>:0: error: unable to load standard library for target 'arm64-apple-ios13.0'

SwiftPM stays on the host's macOS SDK; there is no iOS standard library in it to
load. The `ios13.0` in the message is a second red herring on top of the first — it
is GRDB compiling at its own declared minimum, not a constraint on us. The working
invocation names the SDK:

    swift build --triple arm64-apple-ios26.0 \
                --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"

The output is genuinely iOS and not a mislabelled macOS build, which was checked
rather than assumed — `LC_BUILD_VERSION` on the emitted objects reads platform 2,
minos 26.0, sdk 26.5, and the artifacts land in `.build/arm64-apple-ios/` beside the
untouched `.build/arm64-apple-macosx/`.

## The CI job is the thing that lasts

Two manifest lines are trivially re-broken by one `import AppKit` in a file someone
adds to `Services/`. The `ios-packages` job cross-builds both packages on every push
and is build-only: SwiftPM cannot run a test bundle without a simulator host, so the
compile is the entire gate. That is enough — the failure mode being guarded against
is a platform-unavailable symbol, which is a compile error by construction. A
simulator *test* job arrives with S4b's XCUITest, when there is a host to run one in.

The job comments carry the scope decision too, since "why isn't `AtelierIngestion` in
this matrix" is the question the next person will have.

## One thing S4b inherits, found here

`LibraryLocation` — the App Group seam S1 built *specifically for iOS*, with the
container lookup, the typed `LibraryLocationError`, and the data-protection class —
lives in `AtelierIngestion/Sources/AtelierIngestion/Media/LibraryLocation.swift`.
`AtelierIngestion` does not build for iOS and is not in scope to. So the share
extension currently has no way to call `defaultRoot()` and find the library root it
is supposed to write into.

Nothing is broken; S1 shipped what it said it shipped, and its own note flagged that
the iOS half was unproven by build. But the seam has no reachable caller on the
platform it was written for, and S4b hits that on its first day. The cheapest fix is
to move the location seam into `AtelierCapture` — transport-free, already iOS,
already linked by the extension, and already the home of `InboxLayout` for exactly
this reason (S2 · decision 1) — with `AtelierIngestion` delegating. Recorded in 092 ·
S4b as its first bullet rather than left to be rediscovered.

## Files

    AtelierCore/Package.swift                            `.iOS("26.0")` beside the
                                                         macOS pin, with the reason
    AtelierCapture/Package.swift                         same, deferring to Core's
                                                         note
    .github/workflows/ci.yml                             new `ios-packages` job;
                                                         header comment updated for
                                                         the new job set
    .docs/092-ios-companion-plan.md                      S4 split into S4a (with an
                                                         "As built") and S4b; gate 4
                                                         discharged; "Where this
                                                         stands", test-strategy and
                                                         sizing rows updated

No source file changed. No test changed. No `project.pbxproj` change, for the fifth
slice running.

## Verification

| | |
|---|---|
| `AtelierCore` iOS build | 218 tasks, **Build complete** |
| `AtelierCapture` iOS build | 231 tasks, **Build complete** |
| `AtelierCore` | 760 tests / 105 suites — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| `AtelierIngestion` | 461 / 48 — unchanged |
| `AtelierCapture` | 43 / 2 — unchanged |
| `AtelierServer` | 62 / 6 — unchanged |
| extension | 524 node tests pass, drift check clean |
| app | `xcodebuild build` — **BUILD SUCCEEDED** |

Every macOS number is identical to the baseline, which is the point: this slice
changed nothing a Mac executes.

## Migration notes

None for users. No stored shape, wire shape, endpoint or public API changed on
either platform.

For the build: `AtelierCore` and `AtelierCapture` now declare an iOS 26 platform, so
a consumer that declares a *lower* iOS floor will fail to resolve them. Nothing in
this repo does — `AtelierIngestion`, `AtelierServer`, `CanvasRenderer` and
`AtelierExport` declare macOS only, and a package that names no iOS platform is never
checked against one. The macOS graph resolves exactly as before; `Package.resolved`
is untouched in every package.

If you want to reproduce the iOS build locally, the `--sdk` flag is required — see
above. It needs Xcode 26 for its iPhoneOS 26 SDK, the same requirement the `app` job
already has.

Two notes for S4b:

- `LibraryLocation` is not reachable from iOS. Move it before writing extension
  code, not during.
- `AtelierIngestion` is the only package with an AppKit dependency worth costing:
  one file, `Input/DirectInputReader.swift`, and within it only the `NSPasteboard`
  paths. The `NSItemProvider` drag paths are Foundation and already cross-platform.
  That is an inventory, not a plan — porting it is a separate decision nobody has
  made.
