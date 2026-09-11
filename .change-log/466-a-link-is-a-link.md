# 466 — a link is a link

A report, testing [465](465-on-the-pasteboard-is-not-reached.md): *"copy a link that's
from a board pastes an image instead."*

It does, and it was meant to.

## One question asked of every kind

`AssetExport.pasteboardEntry` decides what an asset copies as by asking a single
question — **are there bytes?** — and a link's og:image and a tweet's card image are
bytes. So a link card resolved to `.file(og:image)`, ⌘C put that picture on the
pasteboard, and every app pasted a JPEG for a page the user had saved.

052 · B1 made that deliberate, and wrote down why: *"including a link's og:image and a
tweet's card image, which render as image cards, so ⌘C must yield the image, not a URL."*
The reasoning is about how the tile RENDERS. That is what was wrong — how a thing looks is
not what it is:

- A **link asset is a page**. Its identity is the URL; the preview is decoration the app
  fetched. The user never chose that picture, never saw it as a file, could not name it.
- An **image asset is the opposite**. The picture IS what was saved.

Every app in the loop already agrees. A browser copies a URL. Notes, Slack and Messages
build their own card out of one. Nobody copies a link expecting a thumbnail.

And 465 had made it worse without noticing: Copy as Text derived its words from the same
rule, so ⌥⌘C on a link card was **greyed out**. A link card could not be copied as a link
by any route on a board — only by opening the detail page and taking Copy Source Link,
which copies the *provenance* URL rather than the link's own.

## The rule

```swift
static func copyEntry(asset:source:blobURL:) -> AssetPasteboardEntry? {
    textFallback(for: asset)                       // the kind's own words, if it has any
        ?? pasteboardEntry(asset:source:blobURL:)  // else its bytes
}
```

*A kind's own words beat bytes it merely acquired.* Link → URL, tweet → permalink, colour
→ hex, image / video → the file, exactly as before. One line, and it reads as the
sentence it is.

**Copy only.** The originals folder export and the share sheet keep the byte rule: an
"originals" export means the bytes on disk, og:images included. `exportSelection` takes
the per-asset rule as a parameter now, so each call site names the one it means rather
than reading a flag.

**Drag-out is untouched.** It is a different path entirely (file promises), so dragging a
link card into Figma still yields its picture — the one gesture that plausibly means "I
want that preview".

## What this re-opens, deliberately

052 · B1 was itself a fix, for the "viktoroddy" tweet: ⌘C a card, paste into Finder, get
nothing. That case comes back — ⌘C on a link card now puts a URL on the pasteboard and no
file, so a paste into Finder has no file to make. Its test survives, renamed to say it is
the EXPORT rule, and drag-out is the route for that intent. This was the user's call after
the trade was put to them.

## What it fixes beyond the report

- **⌥⌘C on a link card works**, and gives the URL.
- **⌘C's text flavour carries the URL too**, so a plain text field pasting a copied link
  card lands the link rather than nothing. Rich apps still take the file for images and
  the URL for links, each by the same preference order 465 measured.
- **465's one known disagreement is gone.** `mayHaveText` no longer guesses at bytes from
  `blobHash` — it reads `textFallback`, which is literally the first half of `copyEntry`,
  so the menu's enabled state and the copy it performs cannot differ. The row 465 had to
  concede (a claimed blob whose file is missing) now agrees, and its test asserts that
  rather than the old concession.

## Files changed

- `AtelierRefs/AtelierRefs/AssetPasteboard.swift`
  - `AssetExport.copyEntry(asset:source:blobURL:)` — **new**. The rule above, with 052 ·
    B1's reasoning and why it does not hold.
  - `exportSelection(assets:blobURL:entry:)` — new `entry` parameter, defaulting to the
    export rule. `@MainActor` on the parameter type: the app target's default isolation
    makes the two rules main-actor functions, and an un-annotated parameter drops it.
  - `copiedText(assets:blobURL:)` and `mayHaveText(_:)` — both on the copy rule now; the
    latter is a one-liner over `textFallback`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `copyToPasteboard` passes
  `AssetExport.copyEntry`. `exportSelection(from:assetIDs:)` (export + share) does not.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — the board's words use `copyEntry`.
- `AtelierRefs/AtelierRefsTests/AssetPasteboardTests.swift` — `CopyEntryTests`, **new**, 5
  tests; the two 052 · B1 tests renamed to EXPORT and re-pointed in prose; the board's
  link test inverted; `MayHaveTextTests` now checks agreement with `copyEntry` over an
  extra image-backed tweet row, and the old disagreement test asserts its own repair.

## Verification

- `xcodebuild test -scheme AtelierRefs -destination platform=macOS`: **1826 passed, 0
  failed**, with the app under test quit first (465 recorded the thumbnail suites timing
  out under that load).
- `linkCopiesAsItsURL` asserts BOTH halves of the split in one test — the copy rule gives
  the URL and the export rule still gives the file — so the two cannot silently converge.

## What is still NOT covered

**No paste into a real app.** That Notes builds a card from a pasted URL is the behaviour
the change is designed around, and it is not observed here.

**⌥⌘C of a link, pasted back into the app, re-imports it.** Copy as Text writes no private
types, so ⌘V takes the importer branch, `ImportPasteboard.firstWebURL` finds the URL in
the plain text, and the app captures a SECOND asset for a page it already holds. Reported
here rather than fixed: the same is true of any URL text, and the fix is a question about
what ⌘V of a URL should mean when the library already has it.

**No `public.url` flavour.** Copy as Text writes `public.utf8-plain-text` only. Apps that
autolink a pasted URL are unaffected; one that only accepts a typed URL will not see a
link. Adding it would also hand our own importer a stronger URL to re-capture.

## Migration notes

- **⌘C on a link or tweet no longer puts a file on the pasteboard.** Anything expecting a
  blob from a copied card — a paste into Finder, Preview, Figma — gets a URL now. Drag it
  instead.
- **`AssetExport.exportSelection` gained a parameter** with the old rule as its default,
  so every existing caller is unchanged. A new caller must decide which rule it means.
- **The share sheet and originals export are untouched**, and deliberately now differ from
  ⌘C for exactly two kinds.
