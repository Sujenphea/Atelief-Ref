# 293 — one hex grammar

## Summary

The app reads one kind of stored string — a CSS hex colour — through **three**
parsers, and they accepted three different grammars:

| Parser | Module | Accepted | Emitted |
| --- | --- | --- | --- |
| `RGBA.init(hex:)` | AtelierExport | 3, 4, 6, 8 | — |
| `ElementRendering.rgba(fromHex:)` | app / canvas | 6, 8 | `#RRGGBB` **upper** |
| `Color.init?(hexString:)` | app / SwiftUI | 6 | `#rrggbb` **lower** |

`RGBA`'s own doc called itself "the one place `#rgb` / `#rrggbb` / `#rrggbbaa`
strings … are decoded". It was one of three.

So a stored `#f80` rendered correctly in an export, returned `nil` on the board, and
fell back to a placeholder swatch in the inspector — the same value, three outcomes.

## Why the duplication stays

The three live in three modules that cannot share an implementation: `AtelierExport`
has **zero product dependencies** by design (it is layout + CoreGraphics over a
package-local model, and never imports `AtelierCore` or AppKit), so it cannot reach
an app-side parser, and the app cannot reach into it for the canvas type.

The duplication is structural and correct. The *disagreement* was not. All three now
implement the identical grammar: optional leading `#`, surrounding whitespace
tolerated, case-insensitive digits, and 3 / 4 / 6 / 8 lengths with the short forms
expanding each nibble like CSS.

`ElementRendering.hex(from:)` now emits **lowercase**, matching
`Color.toHexString()` and `ColorPayload.canonicalHex`. It was the app's only
uppercase emitter, so the same colour was written two ways depending on which path
stored it. Nothing compares these as strings — the swatch chrome compares components
via `near(_:_:)` — so the case was pure inconsistency, not a latent bug.

## New: `HexGrammarTests`

The seam that keeps them honest. Every case asserts all three parsers channel-wise
against the same input, so a parser that gains or loses a length fails until the
other two move with it. Covers the four lengths, bare/`#`-prefixed, case, whitespace,
ten malformed inputs that must be rejected by all three, and the round trip through
`hex(from:)` — including that what the board stores as a text default reads back as
white everywhere.

## `ColorHexTests` changed a deliberate assertion

It asserted `Color(hexString: "#fff") == nil`, commented "shorthand is canonicalized
upstream, not here".

That is true for a `ColorPayload` — `AppServices` rewrites it to `#rrggbb` on write —
but **not** for an `ElementStyle` colour, which is stored exactly as given. The
comment described one of the two kinds of hex the app stores and the assertion locked
in the gap. It now expects shorthand to parse, with the reasoning written down.

## Files changed

- `ElementRendering.swift` — grammar; lowercase emit.
- `SharedThumbnail.swift` — `Color.init?(hexString:)` grammar, incl. 8-digit alpha.
- `HexGrammarTests.swift` — **new**.
- `ColorHexTests.swift` — the shorthand assertion.

## Migration notes

Values already stored keep working — the change only widens what parses and lowercases
what is newly written. Uppercase hex written by earlier builds still parses on every
surface.

## Verified

`-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`.

Run in a throwaway worktree at `HEAD` with only these four files applied: at the time,
concurrent work in the main checkout had `IngestionModel.swift` mid-edit (a call to a
`runPostRestoreBlobReconcile` that did not exist yet), so the shared tree would not
build. The isolation is why this result is about these changes and nothing else.
