//
//  FontFamilyCatalog.swift
//  AtelierRefs
//
//  064 — the system's font families, enumerated ONCE per launch and off the main
//  thread, because enumerating them is expensive enough to be felt as a stalled click.
//
//  Both font pickers used to hold the list as a stored property on a SwiftUI `View`:
//
//      private let families = NSFontManager.shared.availableFontFamilies
//
//  A stored `let` on a `View` is re-evaluated every time the struct is constructed, and
//  `SpaceTextFontPanel` is constructed only when its open flag flips true — i.e. on
//  the click that opens it. So the first time a user opened the "Aa" panel, that click
//  paid the whole enumeration on the main thread.
//
//  Measured on a 402-family machine (see `.docs/064`), and the numbers are the reason
//  this file looks the way it does:
//
//      NSFontManager.availableFontFamilies          384 ms first call, 0.04 ms after
//      CTFontManagerCopyAvailableFontFamilyNames     58 ms EVERY call — it caches nothing
//      NSFontManager.font(withFamily:…)             6.5 ms cold, 1.7 ms warm
//
//  Two findings worth keeping, because both contradict the obvious guess:
//
//  1. Reaching for CoreText as a "faster API" would have made the warm path ~1400×
//     slower. It is only the right choice here because we cache the result ourselves,
//     which turns "58 ms every call" into "58 ms once, on a background thread".
//  2. `NSFontManager.font(withFamily:)` — what `CanvasFont.build` uses to resolve a
//     typeface — does NOT pay the enumeration cost. So this was never a font-rendering
//     problem; the cost is isolated to the *list*, which only the pickers need.
//
//  CoreText is used rather than `NSFontManager` for one reason beyond speed:
//  `CTFontManager` is not AppKit-bound, so warming it on a background thread is in
//  contract. `NSFontManager` off-main happens to work and is not documented to.
//  The two return identical family sets in identical order (verified).
//

import CoreText
import Foundation

/// The system font families, resolved once and shared.
///
/// `@unchecked Sendable` with an explicit lock rather than an actor: every caller is a
/// SwiftUI view body that needs the value *synchronously*, and an actor would force them
/// all async for a value that is computed once and never changes.
///
/// **`nonisolated` is load-bearing, not tidiness.** This target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this type would be
/// implicitly main-actor isolated — and ``warm()``'s detached task would hop straight
/// back to the main thread to read ``families``, running the 384 ms enumeration in
/// exactly the place this file exists to keep it out of. The lock is what makes that
/// safe; the compiler cannot see it, hence `@unchecked`.
nonisolated final class FontFamilyCatalog: @unchecked Sendable {
    static let shared = FontFamilyCatalog()

    /// The tag a picker uses for "no family set" — i.e. the system font. Empty rather
    /// than a name, because `ElementStyle.fontFamily` stores `nil` for the system font
    /// and a real family name otherwise (054 §1).
    static let systemFamily = ""

    private let lock = NSLock()
    private var cached: [String]?

    private init() {}

    /// Enumerate off the main thread so the first picker to open doesn't pay for it.
    ///
    /// Idempotent and cheap to over-call: once ``families`` is populated the detached
    /// task returns immediately. Called when a board opens — the only place a font
    /// picker is reachable from — rather than at launch, so a session that never opens a
    /// board never spends the time.
    func warm() {
        Task.detached(priority: .utility) { [self] in _ = families }
    }

    /// Every installed family, in the system's own order.
    ///
    /// Blocks the caller on the *first* call if ``warm()`` has not finished — correct
    /// beats fast, and the picker must never show an empty list. After that it is a
    /// dictionary-free array read behind an uncontended lock.
    var families: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let list = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        cached = list
        return list
    }
}
