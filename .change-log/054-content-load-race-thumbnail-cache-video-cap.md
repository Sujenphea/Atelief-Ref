# 054 — Folder-load race, async thumbnail cache, client video size cap

## Summary

Three fixes from a follow-up review, verified against the code before fixing:

- **Folder content loads could race** and show the wrong folder's items.
- **The Library grid decoded thumbnails synchronously on the main actor** during
  SwiftUI rendering — disk I/O on the UI path, re-run on every scroll.
- **The extension video path had no client-side size bound** — a huge MP4 was
  downloaded in full before the server's 512 MB cap could reject it.

## What changed

### App (`AtelierRefs`)

- **`IngestionModel.loadContents(of:)` — generation guard (race fix).** The load
  spawns a `Task` with two `await` DB reads (`collectionItems`, `childCollections`);
  because `@MainActor` only serializes at the `await` points, two rapid folder
  switches could finish out of order and the STALE read would overwrite `items`
  while a newer folder was selected. Now a monotonic `contentsLoadID` is captured
  per call; the results are computed into locals and only published when
  `loadID == contentsLoadID`, so a superseded load produces zero side effects.
- **`IngestionModel` — `thumbnail(for:)` → `thumbnailURL(for:)`.** The old accessor
  did `NSImage(contentsOf:)` (synchronous read + decode) on the main actor. It now
  returns only the URL (pure); decoding moves off-main (below).
- **`LibraryView` — async thumbnail cache (perf fix).** New `ThumbnailCache`
  (`NSCache`, keyed by blob hash, `countLimit 512`, thread-safe): a synchronous
  `cached(_:)` hit for the render path, and `load(hash:url:)` that reads + decodes
  OFF the main thread (`Task.detached` for the disk read) and stores the image —
  returning nothing so no non-Sendable `NSImage` crosses an isolation boundary. New
  `AsyncFolderThumbnail` view uses `.task(id: hash)` to show a cached image
  instantly or load a placeholder→image on cell reuse. The grid cell now uses it
  instead of the synchronous decode. Swift-6 clean.

### Extension (`extension/src/sw.js`)

- **`downloadAndIngestVideo` — Content-Length early-out.** Before reading the body
  (`response.blob()`), reject a clip whose declared `Content-Length` exceeds
  `MAX_VIDEO_BYTES` (512 MB, mirroring `CaptureServer.defaultMaxVideoBodyBytes`), so
  a doomed huge MP4 isn't fully downloaded before the server's 413. Absent on a
  chunked response → proceed, with the server cap as backstop. Complements 15A
  (Blob upload) from changelog 052 — this is the client-side early abort that
  review left as optional.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `contentsLoadID` + guarded
  `loadContents`; `thumbnailURL(for:)`.
- `AtelierRefs/AtelierRefs/LibraryView.swift` — `ThumbnailCache`,
  `AsyncFolderThumbnail`, grid cell wiring.
- `extension/src/sw.js` — `MAX_VIDEO_BYTES` + Content-Length check.
- `extension/test/sw.test.js` — over-cap rejection test.

## Verification

- `cd extension && npm test` — **70 pass** (was 69; +1 video size-cap test).
- `xcodebuild … -only-testing:AtelierRefsTests test` — **TEST SUCCEEDED** (build +
  existing app suite green; the two app fixes compile Swift-6-clean).
- The race and thumbnail jank are structural fixes verified by build + reasoning;
  a fast folder-switch stress and a large-folder scroll remain a manual check.

## Migration notes

None — no schema or wire-format change. `thumbnail(for:)` (one caller) was replaced
by `thumbnailURL(for:)`; the grid now loads via `AsyncFolderThumbnail`. The video
size cap is a client-side early-out only — captures under the cap are unaffected.
