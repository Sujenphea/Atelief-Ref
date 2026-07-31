# 305 — the promise delegate runs off main

## Summary

Dragging a ref out to Finder crashed: `EXC_BREAKPOINT` on a background thread, every
time, on a build that compiled clean under Swift 6 and passed the whole unit suite.

`AssetFilePromiseDelegate` needed `nonisolated` and did not have it. It does now.

## Why it compiled and still trapped

302 marked `AssetFilePromiseProvider` `nonisolated` because its overrides implement
nonisolated `NSPasteboardWriting` requirements. It left the DELEGATE — the half that
does the actual copying — untouched, so under the target's MainActor-by-default it
inferred main-actor isolation.

`NSFilePromiseProviderDelegate` is an `@objc` protocol, and its requirements are
nonisolated. Swift does **not** reject a main-actor method satisfying one. It compiles
the mismatch and inserts a *runtime* isolation check instead.

Then AppKit calls `filePromiseProvider(_:writePromiseTo:completionHandler:)` on the
queue the delegate itself vends from `operationQueue(for:)` — a background thread, by
design, so a cross-volume copy never blocks the main thread. The check fires there and
traps.

The class's own doc comment had already argued the correct isolation:

> Stateless — everything is read from the provider — so the single `shared` instance
> safely serves every drag

`nonisolated` states that; `@unchecked Sendable` covers the `static let shared`, whose
only stored property is a thread-safe `OperationQueue`.

## The gap this exposes

A static isolation error fails the build. This one could only fire on a real drop into
Finder — no unit test drives an `NSFilePromiseProvider` through AppKit's drag
machinery, so 1,000+ passing tests said nothing about it. "Compiles under Swift 6" and
"runs under Swift 6" are different claims, and 302 only ever verified the first.

## Is there another one?

One site, checked rather than assumed. The pattern needs an `@objc` protocol
conformance whose callbacks arrive off-main; everywhere else the app leaves the main
actor it uses `Task.detached`, which Swift 6 checks statically — those either compiled
correctly or did not compile. This `OperationQueue` is the only place in the app target
where an `@objc` delegate hands work to a background queue.

The four other `NSObject` delegates — `QuickLookController`,
`CollectionsOutlineCoordinator`, `SpacesOutlineCoordinator`,
`MasonryGridCoordinator` — take main-thread callbacks and are correct as they are.

## Files changed

`AssetFilePromise.swift`.

## Verified

`-only-testing:AtelierRefsTests test` → `** TEST SUCCEEDED **`, which proves only that
nothing else broke — the suite could not have caught this and cannot confirm the fix.
The check that matters is a real drag out to Finder and to a second app.
