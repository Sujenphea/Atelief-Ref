# 464 — the words a board never said

⌘C on a text box put no text on the pasteboard. ⌘V in Notes, a message box, any text
field: nothing. The board's own ⌘V worked, so the copy looked fine from inside the app —
the only place it was never tested from.

## What ⌘C actually wrote

`SpaceView.onCopyTiles` wrote two representations, and neither is words:

- the asset one (`copyToPasteboard` → `AssetPasteboardWriter.write`) — blob file URLs,
  plus one `NSImage` for a single image. **Elements are skipped**: a text box is not an
  asset, so it contributed nothing;
- the board one (`SpaceElementPayload`) — every row including frames and text boxes, with
  its layout. App-private, and read by nothing but this app's own paste.

A selection of only text boxes took a third path: `NSPasteboard.general.clearContents()`
by hand, then the private payload. Externally the board was **empty**, and
`lastCopyReport` was never set at all — the "N copied" feedback never fired for a copy
that had in fact succeeded.

`pasteOntoBoard` has documented the missing flavour as though it existed since 065 — *"a
copied text box also puts its string on the pasteboard as plain text"* — and ordered its
paste chain around it. The chain was right. The write was not there.

## Two measurements that changed the design

The first shape of this fix joined the words and **overrode item 0's `.string`**, on the
belief that a receiver reads item 0 and stops, and that a file item would otherwise hand a
text field a blob path. Both halves are false, and a scratch pasteboard says so:

| | |
| --- | --- |
| `writeObjects([url as NSURL])` | item 0 declares `public.file-url` **and nothing else** — `string(forType:)` is `nil` |
| `writeObjects(["a", "b"])` then `setString("A", …)` | `string(forType:)` is `"A\nb"` |

So **media were already cut out of the text**, for free: a picture has no string rep to
leak. And `string(forType:)` returns the **concatenation** of every item's string, joined
by a `\n` of AppKit's choosing — which made the override a duplicator, not a replacement.
Two tests caught it before it left the machine.

The rule that survives is simpler than the one it replaced: **the words go on once, as one
string item, last.** Nothing to override, nothing to duplicate, and the separator is ours.

## What the words are

In the selection's own z-order:

- a **text box** — its string;
- a **frame** — nothing. `style.text` is a frame's *label*: furniture that names a region,
  not content anybody copied;
- an **asset** — whatever `AssetExport.pasteboardEntry` calls text (a colour's hex, a
  link's URL, a tweet's permalink) and nothing for anything byte-backed. The same rule the
  byte write uses, so the two can never disagree about a link that *has* an og:image: it
  is a picture, it copies as the picture, and it says no words.

Pieces are trimmed, empty ones drop out, and a selection with no words writes no string at
all — "nil, not empty" (065 §2.4), so a blank text box does not paste as a blank line.

## The grid got the same fix, and needed it

`AssetPasteboardWriter.write` used to append one `NSString` **per** `.text` entry. Three
copied colours were three items, and what a receiver made of that was the pasteboard's
decision, not this code's. They are now one item with our separator. Grid → grid,
grid → board and every drag are untouched: those route on `AssetDragPayload`, which is
written exactly as before.

## A board copy can no longer import itself

Words on the pasteboard have a consequence: ⌘V in a **collection grid** falls through to
`DirectInputReader`, and a text box reading `https://…` would import as a fresh link — from
a keystroke that did nothing at all the day before. `resolvePaste` now takes
`hasBoardElements` and answers `.nothing`: silent, because ⌘V of a text box into a grid is
a mistake, not an error. A **mixed** board copy is unaffected — its asset payload is
present and non-empty, so it never reaches that guard and its assets still add.

## The report counts elements

`copyToPasteboard` takes `alsoCopied`, and the board passes its element count. Every
element counts as copied, **empty text boxes included**: the element payload carries them
faithfully and they paste back intact, so calling one skipped would name a row that did
not fail. This only ever shows through the partial-copy toast, which fires on
`skipped > 0` — a text box beside an image whose blob is missing now reads
*"Copied 1 — 1 item had no image"* instead of *"Nothing to copy"*.

It also lets the hand-rolled `clearContents()` branch go: `copyToPasteboard` with no
assets clears, writes the words, and reports honestly, so a text-only ⌘C is the same call
as every other one.

## Files changed

- `AtelierRefs/AtelierRefs/AssetPasteboard.swift`
  - `AssetPasteboardEntry.text` — **new**. The words an entry contributes; `nil` for
    `.file`.
  - `CopyText` — **new**. `separator` (a blank line) and `joined(_:)`. The joining rule
    and the measurements behind it, in one place.
  - `AssetPasteboardWriter.write(_:to:text:)` — `.text` entries are no longer written per
    entry; they are joined into ONE trailing string item. `text:` overrides that join for
    a caller holding pieces the selection cannot see. A selection with words but no
    entries now writes, and still returns `0` — the return is the byte-side count the
    report is about.
- `AtelierRefs/AtelierRefs/IngestionModel.swift`
  - `copyToPasteboard(assets:sourceCollectionID:alsoCopied:text:)` — two new defaulted
    parameters. `alsoCopied` joins the report's `copied`; `text` is forwarded to the
    writer. An empty `assets` is now a legitimate call.
- `AtelierRefs/AtelierRefs/SpaceView.swift`
  - `copiedText(_:blobURL:)` — **new**, `static`, pure. The board's words.
  - `onCopyTiles` — one call instead of a two-branch if/else; passes `alsoCopied` and
    `text`. `import AtelierArchive` for `AssetExport`.
  - The 065 paste-chain comment now names the write that makes its claim true.
- `AtelierRefs/AtelierRefs/CollectionView.swift`
  - `PasteRoute.nothing` — **new** case.
  - `resolvePaste(payload:target:hasBoardElements:)` — new defaulted parameter; existing
    call sites and tests compile unchanged.
  - `pasteIntoCollection()` passes `SpaceElementPayload.decode(from:) != nil`.
- `AtelierRefs/AtelierRefsTests/AssetPasteboardTests.swift` — `CopyTextTests` (6),
  `AssetPasteboardWriterTextTests` (5), `SpaceCopiedTextTests` (7), and 3 added to
  `GridPasteRoutingTests`.

## Verification

- `xcodebuild test -scheme AtelierRefs -destination platform=macOS`: **1813 passed, 0
  failed** — the whole app target, not only the new suites.
- Both pasteboard measurements above are asserted as tests
  (`fileItemHasNoString`, `pasteboardConcatenatesItems`), so the day AppKit changes either
  one it is a red test rather than a silently different paste.

## What is still NOT covered

**No real ⌘C or ⌘V was pressed.** Every assertion is against a named scratch
`NSPasteboard`; `onCopyTiles` itself — the three calls and their order — is covered only
by the fact that its one moving part, `copiedText`, is pure and tested.

**No receiving app was tried.** That Notes, Slack or a `TextField` reads
`public.utf8-plain-text` the way `string(forType:)` does is the assumption the whole
flavour rests on, and it was measured against AppKit's own reader, not against any app.

**The collection block is routing-only.** `resolvePaste` is asserted; that
`SpaceElementPayload.decode` finds the type on a real general pasteboard after a real
board copy is not.

## Migration notes

- **`AssetPasteboardWriter.write` no longer writes one string item per `.text` entry.**
  Anything reading `readObjects(forClasses: [NSString.self])` off an Atelier copy now gets
  ONE string, not N. `string(forType:)` callers see the same words with a blank line
  between them instead of a single newline.
- **The words are the LAST item.** File URLs stay ahead of them, so an external receiver
  still meets the file first.
- **`copyToPasteboard` accepts an empty `assets`.** It clears and reports, rather than
  being a caller error to avoid.
- **`PasteRoute` has a fourth case.** Any exhaustive switch over it outside
  `CollectionView` needs `.nothing`; there is none today.
