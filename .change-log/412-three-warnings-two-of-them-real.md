# 412 — three warnings, two of them real

The iOS build was not warning-clean, and one of the three was a Swift 6 isolation error
wearing a warning's clothes: the share extension compiles under `SWIFT_VERSION = 6.0` and
the two concurrency diagnostics are the kind that stop being advisory the moment strict
checking is turned all the way up. Fixed at the isolation, not with an `@MainActor` hop or
a `nonisolated(unsafe)`.

## `ShareViewController`: two statics that were never main-actor's business

`UIViewController` is `@MainActor`, so a `static` on a subclass inherits that isolation —
including `logger` and `adopt(_:)`, both of which are called from inside
`NSItemProvider`'s completion handler, on whatever thread the system chose. Both are now
`nonisolated`.

For `adopt(_:)` this is not a compiler appeasement, it is the file's existing argument
restated: the provider's temporary file is deleted the moment the handler returns, which is
why 406 moved the copy INSIDE the handler and said so in the doc comment. A `@MainActor`
copy would have to be awaited — the exact deferral that slice removed, reintroduced by an
isolation nobody chose. The warning was pointing at a real hazard.

For `logger` it is smaller and still worth the word: `Logger` is `Sendable`, os_log is
thread-safe, and main-actor isolation on it bought nothing except making the diagnostic
unreachable from the completion handler that most needs to emit one.

## `ThumbnailImage`: the scale, found through context

`UIScreen.main.scale` is deprecated in iOS 26, in favour of a scale reached through the
view's own context. In SwiftUI that context is `@Environment(\.displayScale)`, which is
also the more correct answer: `main` is the device's built-in screen even when the window
is somewhere else, and a decode wants the pixels the picture will actually be drawn at.

It feeds `maxPixel`, which feeds `taskKey`, so a scale change re-decodes at the new bucket
rather than upscaling the old one — behaviour the `UIScreen.main` version could not have
had, since it was reading a constant.

## What was left alone

`appintentsmetadataprocessor: Metadata extraction skipped. No AppIntents.framework
dependency found.` — emitted by a build tool about a framework this app deliberately does
not link. Not a source diagnostic and not fixable in source.

The other static loaders on `ShareViewController` (`loadImage`, `loadFile`, `loadData`,
`loadURL`) keep their inherited isolation. They hold no controller state either and could
follow, but nothing warns about them, they are `async` so the isolation costs a hop rather
than correctness, and this is a file verified through a real share sheet — the two changes
above are the ones with an argument behind them.

## Verification

`xcodebuild build`, `AtelierRefsMobile`, `generic/platform=iOS Simulator`, with every
source in both iOS targets forced to recompile: **BUILD SUCCEEDED**, and `grep warning:`
over the whole log returns nothing but the AppIntents tool line.
`./scripts/verify.sh fast` — all 8 stages pass.

## Files

    AtelierRefs/AtelierRefsShare/              `logger` and `adopt(_:)` are `nonisolated`,
      ShareViewController.swift                each with the reason at its doc comment

    AtelierRefs/AtelierRefsMobile/             `@Environment(\.displayScale)` replaces
      ThumbnailImage.swift                     `UIScreen.main.scale`

## Migration notes

None. No API, no behaviour change beyond a decode that now follows the screen it is on.
