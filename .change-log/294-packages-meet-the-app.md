# 294 — the packages meet the app

## Summary

All five local packages declared `.macOS(.v14)`. The app requires **macOS 26.0**.

Nothing was broken by this — a lower deployment target is always *buildable* — but it
was a 12-major-version phantom constraint on code that only ever ships inside a
macOS 26 app. Its cost is invisible until you hit it: any macOS 15+ API used inside
`AtelierCore`, `AtelierIngestion`, `AtelierServer`, `AtelierExport` or `CanvasRenderer`
would have needed an `@available` guard, for a floor no build ever runs on. There are
currently **zero** `@available(macOS …)` guards in the whole repo, which is what you
would expect from a codebase that has been quietly ignoring the declared floor.

All five now say `26.0`, matching `MACOSX_DEPLOYMENT_TARGET`.

## The string form is not a style choice

```swift
.macOS("26.0")   // not .macOS(.v26)
```

`SupportedPlatform`'s `.vNN` cases stop at `.v15` under `swift-tools-version: 6.0`, so
`.v26` fails the manifest with `error: 'v26' is unavailable`. Naming 26 through the
enum would mean moving every package's tools version too — a larger change with its
own fallout, for no gain over the string. `AtelierCore/Package.swift` carries the
explanation; the other four just carry the value.

## Files changed

- `AtelierCore/Package.swift`, `AtelierIngestion/Package.swift`,
  `AtelierServer/Package.swift`, `AtelierExport/Package.swift`,
  `CanvasRenderer/Package.swift`

## Migration notes

`swift test` in a package now requires a macOS 26 host. That was already true in
practice — the app has required it since the deployment target moved — but a package
could previously be built standalone against an older SDK, and no longer can.

## Verified

`swift build` + `swift test` in all five, and the app target builds against them:

| Package | Tests |
| --- | --- |
| AtelierCore | 559 in 83 suites |
| CanvasRenderer | 392 in 46 suites |
| AtelierIngestion | 192 in 24 suites |
| AtelierServer | 85 in 7 suites |
| AtelierExport | 31 in 3 suites |

`xcodebuild build` → `** BUILD SUCCEEDED **`.

## Still open from the same finding

The app and its two test targets build at `SWIFT_VERSION = 5.0` while every package
declares `swiftLanguageModes: [.v6]`, and the test targets lack the app's
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. That half is deliberately not in this
change: it will surface errors across the app target, and it wants a quiet tree.
