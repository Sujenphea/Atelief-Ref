# 322 — the clipboard can feed the library (013 · K3)

An opt-in ambient mode: with it on, any image you copy anywhere on the Mac lands
in Unsorted by itself. It is **off by default**, it announces itself in the menu
bar for exactly as long as it is running, and it declines to look at three
categories of thing on purpose. `Platform.clipboard` joins the enum so those
items are addressable as what they are.

## Summary

- **`ClipboardWatch`** (new) — the decision core. Given a change counter, a type
  list, and a way to ask for bytes, it returns `capture(Data)` or a bare
  `skip(reason)`. No timer, no `NSPasteboard.general`, no ingest, so all five
  rules below are unit tests rather than claims.
- **`ClipboardWatcher`** (new) — the glue: a 1-second `Timer`, the
  `NSStatusItem`, and one persisted flag. Owned by `IngestionModel` (like
  `BackupController`) because it must outlive the Settings window that turns it
  on.
- **`DirectInputReader.clipboardInput`** — a fourth pure provenance factory
  beside `pasteInput` / `fileInput` / `browserImageInput`. Ambient capture is the
  **existing paste path with a different stamp**, not a second pipeline.
- **`Platform.clipboard`** — additive, no migration (see below).
- **Settings ▸ Clipboard Capture** — the toggle and the three limits, stated.

## Why polling, and why that is the whole mechanism

macOS has no pasteboard notification API. There is `NSPasteboard.changeCount`
and nothing else, so the watcher asks once a second whether it moved. Everything
interesting is therefore in what happens on the ticks where it *did*, and the
order of those checks is the design:

1. **counter unmoved** → stop. This is the branch that runs forever; nothing
   below it costs anything on an idle Mac.
2. **`org.nspasteboard.ConcealedType`** → skip. Password managers set it.
3. **`org.nspasteboard.TransientType`** → skip. "Don't persist me" is a request
   this feature is specifically in the business of honouring.
4. **`com.ref-atelier.asset-ids`** → skip; it's our own copy (below).
5. **no image representation** → skip. Images only, never text, never files.

Markers are checked **before any byte read**, and a test asserts the read count
is zero on a concealed board — that is what makes "skipped without logging the
content" a property rather than a promise. `ClipboardSkip` cases carry no
associated values for the same reason: a reason cannot leak what was on the
pasteboard, so logging one is safe by construction rather than by care at each
call site.

The counter advances on **every** outcome including skips. Without that, a
password sitting on the clipboard would be re-inspected once a second until it
was replaced.

Arming is its own rule: turning the watcher on adopts the *current* change count,
so whatever was on the clipboard beforehand is never taken. The user consented to
what they copy next.

**One item per copy** — no coalescing and no batch timer. The watcher also keeps
no memory of bytes between ticks: 18A content-hash dedup resolves a repeat to the
asset that already exists, and suppressing repeats here would mean this feature
holding on to image data, which is strictly the wrong direction for it.

## The own-copy trap, stated honestly

⌘C inside the app must not come back as an ambient capture. The marker for that
already exists — `AssetDragPayload.pasteboardType`
(`com.ref-atelier.asset-ids`) — and the watcher skips any board carrying it.

**It is not yet load-bearing on the grid path.** The sibling `019`
(`feat/clipboard-fidelity`) is what makes every in-app ⌘C write that type; until
it merges, a grid copy does not carry it, so an image copied out of the library
while the watcher is on can be re-noticed and will dedup to the asset it already
is. The skip is correct and stays; no second marker was invented to paper over
the interval.

## Provenance is never null, and never pretends to be certain

A captured item gets `platform: .clipboard`, `authorName` = the frontmost app's
localized name, `authorHandle` = its bundle id — which the detail sidebar already
renders as "Preview (com.apple.Preview)". An unresolvable app falls back to
`"Clipboard"`; the bundle id stays `nil`, because nothing sensible stands in for
it.

**This races a fast app switch.** The watcher polls, so the frontmost app is read
up to a second after ⌘C: copy in Safari, ⌘-tab to Mail inside that window, and
the item is attributed to Mail. There is no API that reports who owned the
pasteboard when it changed, so the choice is a good guess or no provenance at
all, and the second is worse. Recorded as the app it most likely came from, not
as a fact about it.

`.clipboard` is **not** in the originalURL-required group. `Validation.originalURL`
switches exhaustively with no `default`, so adding the case did not silently
inherit a rule — it failed to compile until it was placed, which is the intended
behaviour of that switch.

## Never silent

The `NSStatusItem` is created when watching starts and removed when it stops, so
its presence *is* the running state rather than a label that could drift from it.
If the status bar cannot hand back a button to draw into, `start()` refuses to
run and turns the preference back off — "if the user cannot see that it is
running, it must not be running" is enforced, not merely intended. Clicking it
gives Pause, Turn Off, and a way to Settings.

Pause is session-scoped on purpose: a relaunch that came back silently paused
would leave someone believing capture was off while the toggle said on. The
indicator switches to an unfilled icon so the two states are told apart at a
glance.

An ambient capture also posts the ordinary import toast. Per-item confirmation of
something the user did not ask for, item by item, is the point.

## Why the toggle is unavailable until the library opens

The flag is stored as `library.<id>.clipboardCaptureEnabled` — the `library.<id>.`
prefix 016 §C asks new keys to adopt, and which names this exact toggle as its
reason. The id comes from `LibraryIdentity`, so the preference cannot be read
before the library is open, and the Settings row says so rather than lying. If
the id cannot be resolved at all, the watcher stays unavailable: a per-library
preference we can't read is not an invitation to guess.

A capture files into Unsorted through `importInputs`, deliberately **not**
`run(inputs:)` — that reloads the folder a batch landed in, which is right for a
paste and wrong here. An image copied in another app must not yank the grid over
to Unsorted; the tree refreshes, and the contents reload only if Unsorted is
what's on screen.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/Enums.swift` — `case clipboard`.
- `AtelierCore/Sources/AtelierCore/Services/Validation.swift` — `.clipboard`
  joins the local paths exempt from the originalURL rule.
- `AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputReader.swift` —
  `clipboardInput(...)` + `clipboardFallbackAppName`; the one place the frontmost
  app is normalized.
- `AtelierRefs/AtelierRefs/ClipboardWatch.swift` — new: the `ClipboardBoard`
  seam, `ClipboardSkip` / `ClipboardDecision`, the `ClipboardWatch` core,
  `SystemClipboardBoard`, `FrontmostApp`.
- `AtelierRefs/AtelierRefs/ClipboardWatcher.swift` — new: timer, status item,
  the persisted flag.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — owns the watcher;
  `activateClipboardWatcher(root:)`, `ingestClipboardCapture(_:)`, and an
  AppKit-side Settings opener for the menu-bar item.
- `AtelierRefs/AtelierRefs/SettingsView.swift`,
  `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — the Clipboard Capture section,
  observed separately from `model` for the reason `backup` is.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — the display name "Clipboard".
- Tests: `AtelierRefsTests/ClipboardWatchTests.swift` (new, 25 — the five rules,
  the arming rule, the counter-advance rule, dedup tolerance, the marker
  identifiers, the library-scoped key, off-by-default),
  `AtelierIngestionTests/DirectInputReaderTests.swift` (+6 — the provenance
  factory and its fallback), `AtelierCoreTests/EnumRawValueTests.swift` (the
  rawValue table and the `allCases` count, 8 → 9),
  `AtelierCoreTests/ServicesValidationTests.swift` (the local-paths argument
  list), `AtelierServerTests/CaptureDecoderTests.swift` (the accepted
  platform-string table).

Adding one `Platform` case forced a change in five of those files, four of them
tests — the same set the `rednote` case touched, minus the migration.

## Test results

- `swift test --package-path AtelierCore` — 588 tests passed.
- `swift test --package-path AtelierIngestion` — 263 tests passed.
- `swift test --package-path AtelierServer` — 85 tests passed.
- `AtelierRefs` scheme (`xcodebuild build-for-testing` +
  `test-without-building`, `platform=macOS`) — **TEST EXECUTE SUCCEEDED**, 1090
  passed, 1 skipped, 0 failed, including the 25 new clipboard cases. No
  `ThumbnailPipelineTests` / `ThumbnailWindowPrefetcherTests` flake in this run.

## Migration notes

**No schema migration, and none is possible to need.** `source.platform` is TEXT
with no `CHECK` constraint, so a new `Platform` case is purely additive: no
existing row's value changes meaning, no column is added, and no migration
identifier is consumed. Unlike `rednote`, there is no historical data to re-tag —
nothing in any library was ever captured this way, because the path did not
exist.

The one new stored value is a `UserDefaults` boolean,
`library.<library-id>.clipboardCaptureEnabled`. Absent until the user turns the
feature on, and absent is read as OFF explicitly (`object(forKey:) == nil`),
never inferred from `bool(forKey:)`'s zero. An existing library gains nothing and
behaves identically until someone opens Settings and says yes.
