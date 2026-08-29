# 420 — three palettes become one

`ShareCard.swift` predicted this in its own header, back when it was the only iOS surface:

> *"When S5 brings a real iOS UI, this stops being the right shape and a shared
> cross-platform token target becomes the question; one card is not enough reader to
> justify one now."*

S5 brought one, S6 gave it a second control, and the palette had been written by hand three
times: `Theme.swift` (macOS), `ShareTheme` (the extension), `MobileTheme` (the phone). Each
literal cited the `Theme.swift` line it came from, which made the copies *checkable* — it
never made them *derived*.

## What the package holds, and what it deliberately doesn't

**`AtelierTokens`**: the palette, the 4-pt scale, radii, motion, elevation, the nine type
roles, and the two lone constants. No dependencies — tokens are values plus SwiftUI, and
SwiftUI is on both platforms.

**A colour is one number.** `Tokens.Hex.panel` is `0x212121`; the `Color` is derived from
it, and the Mac's `NSColor` twin is derived from the same number. That is the property the
hand-copying could not have: drift is now structurally impossible rather than watched.
Which matters here specifically — [295](295-adopt-or-drop-every-token.md) records `field`
and `selection` drifting to within 14 points of each other unnoticed, and three `Theme.NS`
mirrors falling out of step with their originals.

What stayed behind is what only one platform has: the `NSColor` twins, `CALayer`'s shadow
(it flips the y sign for AppKit's unflipped axis; UIKit's is flipped),
`VisualEffectBackground`, and the popover container.

## Three curations, not one dumping ground

Each target keeps a forwarding surface — `Theme`, `MobileTheme`, `ShareTheme` — naming the
tokens it draws. That is not ceremony: 093 § 4's list of which tokens cross is information,
and it is what stops a phone call site reaching for `hoverRow` (no pointer, and it is
documented as a whisper precisely so it cannot be mistaken for selection — a press wants
the opposite) or `Radius.control` (it hugs a 15pt icon in a 30×28 hit area, a pointer
measurement).

**They forward by hand rather than by `typealias`, and the reason is a Swift 6 rule worth
recording:** the module that DEFINES a member must be imported at the site that USES it,
and a typealias does not move a definition. `typealias Colors = Tokens.Colors` compiled
fine and then asked 44 view files to `import AtelierTokens` in order to keep writing the
`Theme.Colors.panel` they already wrote. Re-declaring the names defines them in the app,
where the app already looks. Five files import the package anyway — the `.elevation(…)`
sites, where the leading dot resolves on the package's own type.

## The fourth parser

Scoping this turned up something else. `HexGrammarTests` pins THREE parsers of the stored
hex grammar to 3/4/6/8 digits, because they read the same strings and once disagreed —
`#f3a` drew in an export and vanished on the board. iOS had quietly added a **fourth**
(`GridTile.swift`), taking 3/6 only, pinned by nothing: a stored colour with an alpha
rendered on the Mac and fell back to a grey placeholder on the phone. Same divergence,
different road.

The SwiftUI parser is now one implementation in `AtelierTokens`, which both platforms link,
so the row `HexGrammarTests` already checks covers the phone too. The other two genuinely
cannot share code — `AtelierExport` has zero product dependencies by design — and that
duplication stays, pinned as before.

## Verification

`AtelierTokens` 7/2: the hex arithmetic, that every colour token resolves to its declared
number, that no two greys are the same value, that the scale is ordered and 4-divisible,
and the grammar including the 4- and 8-digit forms the iOS copy refused. Deliberately
absent: a test asserting `#212121` is the right grey. That is a design decision, and a test
restating it would be a fourth copy of the palette.

`scripts/verify.sh fast` — 10 stages now. The full `AtelierRefsTests` suite. Both apps and
the share extension build for their platforms; `AtelierTokens` is in both CI matrices,
including the iOS cross-build.

Net **−184 lines**.

## Files

    AtelierTokens/                               new package: Palette, Scale,
      Sources/AtelierTokens/                     Typography, and the shared parser
      Tests/AtelierTokensTests/                  7 tests
    AtelierRefs/AtelierRefs/Theme.swift          the Mac's view + the AppKit parts
    AtelierRefs/AtelierRefsMobile/               the phone's view
      MobileTheme.swift
    AtelierRefs/AtelierRefsShare/ShareCard.swift the extension's view
    AtelierRefs/AtelierRefsMobile/GridTile.swift the fourth parser, deleted
    AtelierRefs/AtelierRefs/SharedThumbnail.swift the macOS copy, deleted
    AtelierRefs/AtelierRefsTests/                the premise, updated
      HexGrammarTests.swift
    AtelierRefs/AtelierRefs.xcodeproj            three targets link the package
    .github/workflows/ci.yml                     both matrices

## Migration notes

**One behaviour change:** 4- and 8-digit stored hex colours now render on the phone instead
of falling back to `mediaBackdrop`. Latent until now — `ColorPayload` canonicalises to
`#rrggbb` on write — so no stored library is expected to contain one.

Nothing else moves: same values, same names at every call site. A file that draws chrome
still writes `Theme.` / `MobileTheme.` / `ShareTheme.` and does not import the package.
