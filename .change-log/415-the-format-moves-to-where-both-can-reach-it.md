# 415 — the format moves to where both can reach it

S6 says the phone writes an archive and the Mac absorbs it. The first thing you find on
opening that slice is that **there is no archive code the phone can link**: the manifest,
its writer, its reader and the export naming rule all lived in `AtelierRefs/`, the macOS
app target. A phone cannot import an app.

So S6a is not sync. It is moving a file format out of an application and into a package —
`AtelierArchive`, which builds for macOS *and* iOS, and which the Mac app now links instead
of owning.

## What moved, and the two things that could not

| moved to `AtelierArchive` | why it could |
|---|---|
| `LibraryArchive.swift` (the manifest, `ArchiveLayout`, `ArchiveRefusal`) | `AtelierCore` + `Foundation` only |
| `LibraryArchiveWriter.swift` | its own header already said it was AppKit-free, `nonisolated` and `Sendable` |
| `LibraryArchiveReader.swift` | same |
| `ImportPlan.swift` (the whole plan/skip/report model) | pure values the reader produces |
| `AssetExport.swift`'s naming rule | a pure function over a `Source` |

Two things stayed behind, and the split is the interesting part:

**`AssetExport.dragProvider` → `AssetExportDrag.swift`.** It builds an `NSItemProvider` and
registers the app-private `.assetIDs` pasteboard type for the internal-drag guard. None of
that means anything on a phone with no drag session. The *naming* is shared; the *dragging*
is macOS, and now they are two files that say which is which.

**The words a run reports.** `ArchiveCopy` and `ArchiveImportCopy` are the sentences an
export or import shows a person, and they live beside the controllers that show them. Their
tests came out of the moved test files into `ArchiveCopyTests` / `ArchiveImportCopyTests` —
the format's tests went with the format, and the copy's tests stayed with the copy. Two
different questions that happened to share a file.

## The one real blocker: a path join

`LibraryArchiveWriter` took a `MediaStore`, and used it for exactly one thing — resolving a
blob's path. `MediaStore` lives in `AtelierIngestion`, which does not build for iOS
(`Input/DirectInputReader.swift` imports AppKit). Depending on it would have made this
package macOS-only, **for a path join**.

It now takes a `libraryRoot: URL` and asks `AtelierCapture.LibraryMediaPaths`, which is
where that arithmetic already lives for both platforms. That needed one more piece:
`ImageMetadata.fileExtension(forMIMEType:)`, also in the macOS-only package, and also a
one-liner over `UTType`. It moved to `LibraryMediaPaths` beside the paths it completes —
the extension is not decoration on a path, it is *part* of one, and a reader that maps the
MIME differently computes a path to a file that is not there. `ImageMetadata` delegates
rather than keeping a second copy.

That makes **four** types the AppKit boundary has pulled out of `AtelierIngestion` —
`InboxLayout` (S2), `LibraryLocation` (S4a), `LibraryMediaPaths` (S5), and now the MIME
mapping. `LibraryMediaPaths`' header already called this a pattern rather than a
coincidence; it is now a pattern with four instances and a shape: *the name and the
arithmetic go to the package both processes can link, and the macOS type delegates.*

## Where the tests live now

2,571 lines of archive tests moved out of the app's test target, which needs an
`xcodebuild` and a simulator-less host app, into `swift test`, which does not:

    AtelierArchive   46 tests / 8 suites, 0.019s

The suites that stayed in `AtelierRefsTests` are the ones that test a *controller*:
`ArchiveExportControllerTests`, `ArchiveImportControllerTests`, the export→import round trip
through `ArchiveImportController`, and the two copy suites. They need `AtelierIngestion`, an
`ArchiveImportController`, and a `DirectFolderAccess` — all macOS.

`AtelierArchive` is in both CI matrices: the package-test one and the **iOS build** one,
which is the job that will fail the day someone adds an AppKit import to the format.

## Verification

| | |
|---|---|
| `AtelierArchive` | **46 / 8** — new; `swift build` for `arm64-apple-ios26.0` succeeds |
| `AtelierCapture` | 104 / 5 — unchanged; iOS build succeeds |
| `AtelierIngestion` | 467 / 48 — unchanged (`ImageMetadata` now delegates) |
| macOS app | `xcodebuild test`, `platform=macOS` — **TEST SUCCEEDED** |
| `scripts/verify.sh fast` | all **9** stages (was 8) |

No test assertion was edited in the move. The only changes inside the moved files are
access levels, two explicit `public init`s where a synthesized memberwise initializer would
have been internal, and the writer's `store:` → `libraryRoot:`.

## Files

    AtelierArchive/                            new package (macOS 26 + iOS 26), depending
      Package.swift                            on AtelierCore and AtelierCapture
      Sources/AtelierArchive/                  LibraryArchive, LibraryArchiveWriter,
                                               LibraryArchiveReader, ImportPlan,
                                               AssetExport
      Tests/AtelierArchiveTests/               the manifest + reader suites, 46 tests

    AtelierCapture/…/LibraryMediaPaths.swift   `fileExtension(forMIMEType:)`
    AtelierIngestion/…/ImageMetadata.swift     delegates to it

    AtelierRefs/AtelierRefs/                   `AssetExportDrag.swift` keeps the
                                               NSItemProvider half; 13 files gain
                                               `import AtelierArchive`;
                                               `ArchiveExportController` passes
                                               `store.layout.root`
    AtelierRefs/AtelierRefsTests/              `ArchiveCopyTests`,
                                               `ArchiveImportCopyTests` split out
    AtelierRefs/AtelierRefs.xcodeproj          the local package reference
    .github/workflows/ci.yml                   AtelierArchive in both matrices

## Migration notes

`LibraryArchiveWriter(services:store:appVersion:schemaVersion:)` is now
`LibraryArchiveWriter(services:libraryRoot:appVersion:schemaVersion:)`. Existing callers
pass `store.layout.root` — the same directory, one hop earlier.

Everything else is source-compatible behind an `import AtelierArchive`. No file format
changed: the manifest's fields, its version, its refusal matrix and its golden-file tests
are untouched, so an archive written before this commit reads identically after it.

**What this does NOT do:** the phone cannot yet write an archive. It can now *link* the
code that would — S6b is the surface that calls it, and S6c is the Mac absorbing the result.
