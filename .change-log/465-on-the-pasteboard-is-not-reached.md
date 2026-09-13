# 465 — on the pasteboard is not the same as reached

A report against [464](464-the-words-a-board-never-said.md), the change that put a
board's words on the pasteboard: *"once there are videos involved in the copy, the text
fields don't get copied, only the links to the videos. same with images."*

The words were there. Nothing asked for them.

## The measurement

⌘C on a video + a text box, reconstructed on a scratch pasteboard and read back:

```
board-level types, in order:
   public.file-url
   NSFilenamesPboardType           ┐ flavors NSURL adds on its own
   Apple URL pasteboard type       ┘
   public.utf8-plain-text          ← 464's words, last

string(forType:.string)           = "the caption on the board"
availableType [.fileURL, .string] = public.file-url
availableType [.string, .fileURL] = public.utf8-plain-text
```

`string(forType:)` returns the caption. `readObjects([NSString])` returns the caption.
The text copied perfectly — and **`availableType(from:)` answers in the order the
RECEIVER asks**. Notes, Messages, Mail, Slack, every rich editor asks for a file before
it asks for text, matches `public.file-url` (or `Apple URL pasteboard type`, which is why
a *link* appears rather than an attachment), and never asks for the string at all.

So 464's rule — *media cut out of the text, file reps kept* — cannot deliver what it
promised in any app that can hold a file. The destination picks the representation, and
the richest one always wins. Item order is irrelevant: putting the words first would
change nothing, because nothing is reading items in order.

Two details that make it worse than it first looks:

- `includeImageData` keys off the count of **assets**, not rows, so one image plus any
  number of text boxes also puts `public.tiff` pixels on the board — a second rep that
  outranks text.
- The only place 464's words are reachable is an app with no richer reader at all: a
  plain `NSTextField`, a terminal. Which is not where anybody pastes a caption.

## The fix is a second command, not a different rule

⌘C is unchanged: every flavour, destination decides. **Edit ▸ Copy as Text (⌥⌘C)** is the
other half of that choice, moved to where the user can make it — one string item, no file
URL, no pixels, and no app-private types either.

Leaving the private types off is deliberate. A text copy pasted back onto a board makes
ONE TEXT BOX out of the words (the paste chain's last branch), rather than silently
rebuilding the layout; ⌘V into a collection does nothing. "Copy as Text" copied text, and
nothing came along with it.

**Disabled, not silent, when there is nothing to copy.** A selection of pure media greys
the menu item out and ⌥⌘C leaves the clipboard alone — the rule `DeleteVerbs` already
applies to Remove: an item you can click that then does nothing is worse than a greyed one.

## The cheap predicate, and the one row it is wrong about

Enablement cannot use the real rule. `AssetExport.pasteboardEntry` settles "has bytes" with
a `FileManager.fileExists` probe, and a menu item's `disabled` is evaluated on every body
pass — so ⌘A over a large collection would mean a `stat` per selected asset on every
keystroke that moves the selection.

`AssetExport.mayHaveText` answers from `blobHash` alone. It agrees with the exact rule on
every ordinary row — asserted over all six kinds plus a link WITH an og:image — and
disagrees on exactly one: a row that CLAIMS a blob whose file is gone. There the exact rule
falls back to the link's URL and this one greys the item out. That is a broken library, it
is named in both doc comments, and it has its own test.

## Files changed

- `AtelierRefs/AtelierRefs/AssetPasteboard.swift`
  - `CopyText.write(only:to:)` — **new**. Clears, writes one string item, nothing else.
  - `AssetExport.copiedText(assets:blobURL:)` — **new**. The words of an ordered asset
    selection, on the same per-asset rule ⌘C's text flavour uses.
  - `AssetExport.mayHaveText(_:)` — **new**. The cheap predicate above.
  - `CopyText`'s header now records that being on the pasteboard is not being reached.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift`
  - `CopyAsTextVerb` + `FocusedValues.copyAsText` — **new**, the `DeleteVerbs` shape.
  - `CopyAsTextCommand` — **new**, in `CommandGroup(after: .pasteboard)`. ⌥⌘C is safe as a
    menu key equivalent (unlike the bare ⌫ beside it): it is nobody's text-entry key.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `selectedRows(from:)`, **new**. Takes the
  rows so a caller picks its truth: `items` is cheap, `placedItems` carries live z.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — publishes the board's verb. `canCopy` reads
  `items` (words need no geometry); the copy reads `placedItems`, z-sorted.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `gridCopyAsText` over the same widened
  selection ⌘C uses, published on the same route gate as the grid's delete verbs; and
  `pageCopyAsText` for the item the detail page is showing.
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — the hits' verb, same shape.
- `AtelierRefs/AtelierRefsTests/AssetPasteboardTests.swift` — `CopyTextOnlyTests` (2),
  `AssetCopiedTextTests` (3), `MayHaveTextTests` (3).

## Verification

- `xcodebuild test -scheme AtelierRefs -destination platform=macOS`: **1822 passed, 0
  failed** (the whole app target).
- A run mid-way reported 15 failures, all in `ThumbnailPipelineTests` /
  `ThumbnailWindowPrefetcherTests`, all at ~10s — decode-timing assertions timing out while
  the app under test was running beside the suite. All 38 pass in isolation and the full
  suite is green on a re-run. Nothing in those suites touches this change.
- `CopyTextOnlyTests.clearsTheRichCopyFirst` pins the failure that would defeat the whole
  command: ⌘C then ⌥⌘C leaving the file URL behind.

## What is still NOT covered

**No menu item was clicked and no ⌥⌘C was pressed.** The verbs are published from four
view bodies and nothing drives SwiftUI's focused-value plumbing in a test; what is asserted
is the pasteboard each `copy` closure would write and the predicate each `canCopy` uses.

**Receiver preference is measured against AppKit, not against Notes.** That
`availableType(from:)` answers in the caller's order is demonstrated; that Notes asks for a
file first is inferred from the reported behaviour, not observed in Notes' code.

**Which surface publishes while two could.** The grid and the detail page are gated on
`nav.presentedItemID` exactly as their delete verbs are, so one answers at a time. Search
and the board publish unconditionally, as their delete verbs do. Untested, and untested for
`DeleteVerbs` too.

**The shelf, Home and the gallery publish nothing**, so ⌥⌘C greys out there. Deliberate for
now — the archived shelf is the only one with a plausible claim to it.

## Migration notes

- **⌘C is unchanged.** Every flavour still goes on, in the same order, with the same
  private types. 464's joined words are still written and still reachable by anything that
  asks for text first.
- **⌥⌘C is new and app-wide.** Any surface that wants it must publish
  `FocusedValues.copyAsText`; one that does not gets a greyed menu item, not a crash.
- **Copy as Text writes no private types**, so a ⌥⌘C followed by ⌘V inside the app is NOT
  equivalent to ⌘C ⌘V. That is the point, not an oversight.
