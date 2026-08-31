# 452 — the factories were never the AppKit part

The companion app has a share extension that writes captures into `inbox/` and no way to
ingest them. `InboxDrain` — the host half of that handoff — lives in `AtelierIngestion`,
and that package did not build for iOS, because one file in it imported AppKit.

The reason it stayed that way is written down in three places, and it was a real reason:

> the AppKit file is not excludable with one `#if`, because `InboxDrain` and
> `RemoteImageFetcher` both call `DirectInputReader`, so dropping it on iOS takes the
> drain with it.

That is `ci.yml`'s `ios-packages` comment, echoing 092 · S5, echoed again by 448. Every
word of it is true **about the file**. It is wrong about the type.

## What the two callers actually call

`InboxDrain` reaches for `remoteInput`, `remoteContent`, `remoteContentWithImage`,
`remoteFile`, `remoteContentWithFile`. `RemoteImageFetcher` reaches for `browserImageInput`
and `isWebURL`. Not one of those touches AppKit — they take bytes or a URL plus a caller
`Date` and return an `IngestInput` with the right provenance stamp. The file's own header
had said so since chunk 5, and its own `// MARK:` drew the line at the exact place the
split needed to happen:

```
// MARK: - Provenance factories (pure, unit-testable without AppKit state)
```

The AppKit dependency was never in the factories. It was in the two readers — one that
inspects an `NSPasteboard`, one that decodes `NSItemProvider`s from a SwiftUI drop — that
happened to live in the same 430 lines.

## The split

`Input/DirectInputFactories.swift` (260 lines) **declares** `enum DirectInputReader` and
holds every pure member: the four local provenance factories, the five remote ones,
`clipboardFallbackAppName`, and `isWebURL`. It imports Foundation and AtelierCore.

`Input/DirectInputReader.swift` (245 lines) **extends** that namespace with the pasteboard
and drag readers, behind `#if os(macOS)`.

The declaration site is the load-bearing detail. Had the namespace stayed in the AppKit
half, the `#if` would have taken the type — and with it every factory — out of an iOS build
regardless of where the bodies lived. `#if os(macOS)` rather than `#if canImport(AppKit)`
because it is the only platform conditional this repo already uses (`LibraryLocation`'s
`#if os(iOS)`), and because a pasteboard is a Mac, not a framework that happens to be
present.

**No caller moved and no name changed.** Both halves extend one enum, so
`DirectInputReader.fileInput(…)`, `.inputs(from:into:now:)` and the rest resolve on macOS
exactly as before. The Mac app, `AtelierServer`, and both existing test files are untouched.

## What was rejected

**Excluding the file, with `exclude:` or an `#if` around the whole thing.** The objection
in the CI comment holds: it takes the drain. 399 already named this pattern — exclusions
are not a design.

**Guarding the Vision and NaturalLanguage adapters.** The plan for this slice assumed
`VisionImageClassifier`, `VisionTextRecognizer` and `NLSentenceEmbedder` were three more
blockers needing `#if`s. **They are not blockers at all.** Vision and NaturalLanguage are
iOS frameworks; all three cross-compile untouched, and the clean iOS build below compiles
every one of them. Guarding them would have removed working capability from the phone to
solve a problem that does not exist. AppKit was the only thing in the package that ever
stopped an iOS build.

**Moving anything into `AtelierLibraryPaths` or `AtelierCapture`.** That is the reflex 448
stopped, and it is not needed here: nothing had to leave the package, because the package
itself can go.

## What this does NOT do

**Nothing on iOS drains anything yet.** This is a compile boundary and nothing else — no
app target links the package, no view calls `drainOnce()`. The claims in `BrowseLibrary`,
`InboxArchive` and `InboxRetirement` that the phone never drains its inbox are still true;
what has changed is the reason, from "the code cannot be built there" to "nothing calls
it". Those comments are corrected to say the second thing rather than the first.

**No macOS behaviour changed.** No function body was edited — the moved code is byte-
identical to what it replaced, which is why 467 tests still pass without one of them being
touched.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputFactories.swift` — new; the
  namespace declaration and every pure member.
- `AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputReader.swift` — 430 → 245
  lines; the pasteboard and drag readers, now an extension behind `#if os(macOS)`.
- `AtelierIngestion/Package.swift` — `.iOS("26.0")` (string form: the enum stops at
  `.v15`), and the `AtelierCapture` dependency comment no longer says the share extension
  *cannot* link this package, because it now can — it says why it still should not.
- `.github/workflows/ci.yml` — `AtelierIngestion` added to the `ios-packages` matrix, and
  the paragraph declaring the port impossible rewritten into what was actually wrong with
  the argument.
- Nine stale "AtelierIngestion imports AppKit and does not build for iOS" claims corrected
  across `AtelierCapture` (`InboxLayout`, `InboxWriter`, `InboxRetirement`,
  `ContentHasher`), `AtelierArchive` (`Package.swift`, `InboxArchive`,
  `LibraryArchiveWriter`), `AtelierBrowse` (`BrowseLibrary`), `AtelierLibraryPaths`
  (`Package.swift`, `LibraryLocation`, `LibraryMediaPaths`) and `AtelierIngestion` itself
  (`LibraryLayout`, `MediaStore`). Each relocation those comments justify stays justified —
  a share extension still wants the handoff's shape without the pipeline — so the argument
  is preserved and only the false premise is put in the past tense.

`.docs/` and earlier `.change-log/` entries are left alone: they record what was true when
they were written, which is what they are for.

## Verification

| | |
|---|---|
| `swift build --triple arm64-apple-ios26.0 --sdk …iphoneos…` | **Build complete** — 288 tasks from a clean `.build`, including all three Vision / NaturalLanguage adapters |
| `swift test` (AtelierIngestion) | **467 tests in 48 suites**, all passing — unchanged from before |
| `swift build` × AtelierCapture, AtelierArchive, AtelierLibraryPaths, AtelierBrowse | Build complete (comment-only edits, confirmed anyway) |
| `xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` | **BUILD SUCCEEDED** |

Not verified here: the iOS app and share-extension schemes were not rebuilt, since nothing
they link changed — `AtelierIngestion` is still on no iOS target's link line. CI's `ios-app`
job covers them. The new `ios-packages` matrix row has not been run under GitHub Actions;
it runs the same two flags verified locally above.

## Migration notes

None. The API surface is identical on macOS, and on iOS the package now exposes
`DirectInputReader`'s factories where before it exposed nothing at all. `inputs(from:)` in
either overload remains macOS-only — a caller that wants it on iOS has no pasteboard to
hand it anyway.
