# 416 — the inbox is what the phone has to send

S6 says "the phone writes an archive of what it captured". Opening that sentence turns up a
fact the plan states everywhere except in S6: **the phone has no assets.** iOS never drains
its inbox — `InboxDrain` lives in AtelierIngestion and does not build there — so a capture
made on a phone is a record plus a payload file in `inbox/`, and never becomes a row on the
device that captured it. The library the phone browses holds only what has come back to it.

So "export what the phone captured" reads the **inbox**, not the library, and `InboxArchive`
is the only writer in the program that starts from records rather than from a database.

## Why an archive and not the inbox folder

Shipping `inbox/` and pointing the Mac's drain at it would be less code. 091 · D4 chose the
archive manifest for a property that code does not have: **import idempotency**. Provenance
crosses verbatim, so 18A blob-hash dedup collapses a re-import onto the existing asset
rather than forking a second one over the same bytes.

That is what makes the transport boring — AirDrop it twice, leave a copy in iCloud Drive,
re-import last month's folder — and, more importantly, it is what lets the phone **keep its
records after an export**. Nothing is deleted on the promise that the other end succeeded.
The user can export the same inbox every day for a week and the Mac absorbs one library.

## One manifest builder, not two

The entries are built through the same `SourceEntry(_:)` / `AssetEntry(_:tags:)` /
`MembershipEntry(_:file:)` initializers `LibraryArchiveWriter` uses — by constructing
`Source`, `Asset`, `CollectionItem` and `Collection` values **in memory**, from each record,
that no database will ever hold.

That looks strange for a moment. The alternative is a second set of entry initializers
taking raw fields, which is a second definition of what a manifest contains, and the golden
-file tests pin only one of them. A throwaway domain value is cheaper than a fork in the
format.

Likewise the provenance: every record goes through `CaptureDecoder.decodeFileInput` /
`decodeInput`, the same funnel the Mac's drain runs — S0's whole point — so a capture that
travels by archive arrives with the provenance it would have had if the Mac had drained it
directly. What the funnel refuses is skipped and **left in the inbox**, not written
half-formed.

## Reading a header, not a picture

An archive's byte-backed entry needs `width`, `height`, a MIME type and a hash, or
`LibraryArchiveReader` refuses it. The phone has none of those — the share extension went
out of its way never to decode anything (091 · D2's memory ceiling).

`probe` reads them with `CGImageSourceCopyPropertiesAtIndex`, which parses the container's
header without decoding pixels, so a 4000 px capture costs a header read rather than a
bitmap. It runs in the app rather than the extension, but on the same phone, so the same
care applies. A payload whose header cannot be read is skipped **here**, where it is still
in the inbox, rather than shipped as an entry the other end would drop.

The hash is `ContentHasher` — which moved to `AtelierCapture` for this, since an archive's
`blob_hash` is that digest and iOS could not link the package it lived in. A typealias, not
a wrapper: there is exactly one `ContentHasher` type in the program, so the phone's address
for a blob and the Mac's cannot drift. **That is the fifth type the AppKit boundary has
pulled out of AtelierIngestion** — after `InboxLayout`, `LibraryLocation`,
`LibraryMediaPaths` and the MIME→extension mapping.

## The handshake, tested where neither device is needed

The suite drives the **real** `InboxWriter` — a fixture that hand-wrote record JSON would
test this file against a spelling of the format rather than the format — with **real JPEGs**
made through ImageIO, because `probe`'s whole job is reading a container.

Nine tests: what an image capture becomes, what a shared link becomes, provenance verbatim,
two captures of identical bytes sharing one file, a vanished payload skipped while the rest
still export, an unreadable payload refused, an empty inbox refused rather than yielding an
empty folder, and a refused run leaving no manifest behind (the commit marker rule).

The ninth is the one that matters: **what the phone writes, `LibraryArchiveReader` reads.**
The producer and the consumer have never met before — one is the phone's, one is the Mac's —
and 415 having put them in the same package means they can be made to agree in `swift test`,
in 34 milliseconds, with no phone, no Mac app and no transport in the loop.

One assertion in that suite was wrong on the first run and the code was right: the manifest
is JSON, so a URL's slashes are escaped in it, and a `contains` check was asserting an
encoding detail. It now decodes the payload and compares the URL.

## Verification

| | |
|---|---|
| `AtelierArchive` | **55 / 9** — was 46 / 8; iOS build succeeds |
| `AtelierCapture` | 104 / 5 — unchanged with `ContentHasher` added; iOS build succeeds |
| `AtelierIngestion` | 467 / 48 — unchanged behind the typealias |
| macOS app | `xcodebuild test` — **TEST SUCCEEDED** |
| `scripts/verify.sh fast` | all 9 stages |

## Files

    AtelierArchive/Sources/AtelierArchive/     new — records → manifest + files, with the
      InboxArchive.swift                       header probe and the shared-file rule
    AtelierArchive/Tests/…/                    9 tests, including the reader handshake
      InboxArchiveTests.swift

    AtelierCapture/Sources/AtelierCapture/     moved from AtelierIngestion
      ContentHasher.swift
    AtelierIngestion/…/Imaging/                a typealias, so one type exists
      ContentHasher.swift

    AtelierRefs/…/ImportReplay.swift           `import AtelierCapture` for the typealias
    AtelierRefs/AtelierRefsTests/              same, two files

## Migration notes

`ContentHasher` is now `AtelierCapture.ContentHasher`, re-exported from AtelierIngestion as
a typealias. Existing call sites keep the name; a file that used it through AtelierIngestion
alone now also needs `import AtelierCapture`, which is a compile error rather than a silent
change, and three files needed it.

**The phone still has no button.** This is the writer and its tests; S6b-ii is the surface
that calls it and hands the folder to a share sheet.
