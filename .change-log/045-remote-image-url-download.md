# 045 — Download a dragged/pasted image URL (+ feedback on unreadable drops)

## Summary

Dragging or pasting a **bare image URL** (a URL, no image bytes — e.g. a
Pinterest `https://i.pinimg.com/…​.jpg`) used to be a silent no-op: the app only
ever ingested bytes it was handed (`.data` / `.fileURL`) and never downloaded
from a URL. Backlog **B1** closes that gap in two parts:

- **Download a direct image URL** — a new, injectable, unit-tested
  `RemoteImageFetcher` fetches the bytes, validates they are actually a still
  image, enforces a size cap, and hands them to the existing pipeline with the
  image URL as **`.web`** provenance (`originalURL` = the image URL).
- **Feedback on unhandled drops/pastes** — a drop/paste the app can't read at all
  now says so on the existing `status` line instead of doing nothing.

Scope is strictly **direct image URLs**. A *page* URL that would need HTML
scraping is out of scope: a fetched non-image response fails cleanly with a typed
error (`.notAnImage`) and is **not** scraped — that stays with link-resolution /
the Chrome extension (#6, 007 §scope).

## What changed

- `AtelierIngestion/Sources/AtelierIngestion/Input/RemoteImageFetcher.swift` (new)
  - `RemoteImageFetcher` — a `Sendable` struct with an **injected** `URLSession`
    (default `.shared`) and a byte cap (default 32 MB), so nothing does real
    network I/O in tests.
  - `fetch(_:)` → `RemoteImage` (bytes + sniffed MIME + extension) or throws
    `RemoteImageFetchError`. Guards, in order: non-`http(s)` URL → `.invalidURL`;
    transport failure → `.requestFailed`; non-2xx → `.httpStatus`; over the cap →
    `.tooLarge`; bytes that aren't a still image → `.notAnImage`.
  - **"Is it an image?"** is decided by SNIFFING the downloaded bytes through the
    existing `ImageMetadata.extract` (ImageIO container detection) and requiring
    `kind == .image` — NOT by trusting the server's `Content-Type` (captured only
    for the `.notAnImage` diagnostic). This reuses the same type derivation the
    pipeline itself uses.
  - `ingestInput(for:into:at:)` — the reader path: fetch, then build the
    `IngestInput` via the **existing** `DirectInputReader.browserImageInput`
    factory (`.web`, the image URL as `originalURL`). No new provenance shape.
  - `RemoteImageFetchError` — typed, `Equatable`, in the same spirit as the
    package's existing `ImageError`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift`
  - Holds a `RemoteImageFetcher` (default session).
  - `ingestRemoteImage(from:)` — downloads OFF-MAIN (the fetcher's `await`s hop
    off the `@MainActor`), sets a "Downloading image…" `status`, then routes the
    built input through the existing `run(inputs:)` batch path. Failures map to a
    friendly `status` line via `remoteFetchStatus(for:)`.
  - `reportUnreadableDrop()` — sets a `status` line for a drop/paste with nothing
    ingestible (no bytes, no image URL).
- `AtelierRefs/AtelierRefs/LibraryView.swift`
  - `handleDrop` now has three outcomes: ingestible bytes → `run`; else a bare web
    URL → `ingestRemoteImage`; else `reportUnreadableDrop`.
  - `paste()` mirrors the same three outcomes (the Paste button / ⌘V path), with a
    new `firstWebURL(on:)` pasteboard helper that shares `DirectInputReader.isWebURL`.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Input/RemoteImageFetcher.swift` (new)
- `AtelierIngestion/Tests/AtelierIngestionTests/RemoteImageFetcherTests.swift` (new)
- `AtelierRefs/AtelierRefs/IngestionModel.swift`
- `AtelierRefs/AtelierRefs/LibraryView.swift`

## Verification

- `cd AtelierIngestion && swift test` — **all green: 84 tests in 11 suites**
  (8 new in the `RemoteImageFetcher` suite). The fetcher is exercised entirely
  through a `URLProtocol` stub (`URLSessionConfiguration.protocolClasses`), no
  real network. New tests cover the three B1 paths — **image** (real PNG →
  `RemoteImage`, MIME/ext from the bytes), **non-image** (an HTML page →
  `.notAnImage`, not scraped), **network error** (transport failure →
  `.requestFailed`) — plus the guards (non-http URL, non-2xx status, over-cap
  body, mislabeled Content-Type) and the reader path (URL → a `.web`
  `IngestInput` whose `originalURL` is the image URL). Suite is `.serialized`
  because the stub's response hook is process-wide.
- `cd AtelierRefs && xcodebuild -project AtelierRefs.xcodeproj -scheme AtelierRefs
  -destination 'platform=macOS' build` — **BUILD SUCCEEDED**.
- The app-side glue (`IngestionModel.ingestRemoteImage` / `reportUnreadableDrop`,
  `LibraryView.handleDrop` / `paste`) is SwiftUI/AppKit → **compile-verified
  only**; the fetcher + reader path it calls are **unit-tested** in the package. A
  manual drag-from-Pinterest / paste-URL check remains pending (consistent with
  the repo's "runtime UI verification pending" note, 009 §cross-cutting).

## Migration notes

None. Additive behavior; no schema, data, or public-API-removal change. New
package type `RemoteImageFetcher` (+ `RemoteImageFetchError`); reuses the existing
`.web` provenance factory (`DirectInputReader.browserImageInput`) and the existing
`status` / `lastError` UI infra — no new UI.
