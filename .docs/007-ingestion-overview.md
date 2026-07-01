# 007 — Ingestion: Overview (decisions + plan)

> Build-order **step 3** from [004-foundation-plan](./004-foundation-plan.md):
> the local capture loop — turn a pasted/dragged image into a stored, deduped,
> thumbnailed asset with full provenance, through the `AppServices.ingest` seam
> built in step 2 ([006-datacore-overview](./006-datacore-overview.md)). Pipeline
> spec: [003 §ingestion](./003-foundation-design.md).

`AtelierIngestion` is a local Swift package depending on `AtelierCore`. It owns
the content-addressed blob + thumbnail store (the media store deferred from step
2), the image utilities (hash / metadata / thumbnails), the ingestion pipeline,
and the bounded-concurrency coordinator. The app wires the paste/drag UI to it.

## Scope

**In:** the shared pipeline (read bytes → hash → dedup → store blob → extract
metadata → thumbnails → `AppServices.ingest` → add to collection), the blob +
thumbnail file store, and the **three local direct-input paths** — paste image,
drag file, drag browser image (carrying its source URL).

**Out (deferred):** the network **paste-a-bare-URL** / link-resolution path
(fetch page → OpenGraph/Twitter-card → resolve media) — it's live-network + HTML
parsing and overlaps the Chrome-extension work (build order #6). Also deferred:
persistent/resumable job queue, bulk import, video, orphan-blob GC.

## Decisions (from interactive review)

### Architecture
- **A1 — Sibling package `AtelierIngestion` → `AtelierCore`.** The media store +
  pipeline + coordinator live here; the app's paste/drag UI calls in. Image I/O
  has no AppKit dependency, so the pipeline stays headlessly testable.
- **A2 — Blob-first, content-addressed & idempotent, then DB.** Write bytes to
  the hash-derived path first (exists → skip = free dedup); only once durable,
  call `AppServices.ingest` with `download_state = .downloaded`. Invariant: **no
  asset row references a missing blob**; a crash leaves only a harmless orphan
  file. `pending/failed` are reserved for the deferred network paths.
- **A3 — Lightweight in-memory coordinator.** An `actor` running hash/thumbnail
  off-main with **bounded concurrency**, progress, and cancellation. No
  persistent/resumable queue (that's for bulk network import).
- **A4 — Eager fixed thumbnail tiers at ingest.** Generate a fixed set aligned to
  the canvas LOD (128 / 512 / 1280 px) via Image I/O, content-addressed in
  `thumbnails/` (derived, regenerable), off-main.

### Code quality
- **C5 — SHA-256 (CryptoKit), streamed.** System framework, collision-safe,
  memory-safe for large inputs. Hex-lowercased (64 chars) → `blob_hash`.
  `AppServices` validation stays algorithm-agnostic ("non-empty lowercased hex").
- **C6 — Sharded path + atomic write.** `blobs/ab/cd/<hash>.<ext>` (2-level
  shard); write a temp file on the same volume, then atomic rename into place;
  ext from detected mime; idempotent. Required for A2 (a file that exists is
  complete). Thumbnails `thumbnails/ab/cd/<hash>@<size>.<ext>`.
- **C7 — Derive metadata from the bytes.** ImageIO `CGImageSource` for
  dimensions + mime + EXIF orientation; UTType for image/video; never trust the
  pasteboard/file claimed type or extension; stored `width/height` are
  display-oriented; undecodable input → a typed error.
- **C8 — Per-item `Result` + typed `IngestError`.** One bad file never aborts the
  batch. `IngestError` (`unreadableSource`, `unsupportedType`, `decodeFailed`,
  `blobWriteFailed`, `.persistence(AtelierError)`) wraps the core error; retry is
  safe (content-addressing + DB idempotency).

### Tests
- **T9 — Temp Library dirs + committed fixtures.** `makeTempLibrary()`
  (`blobs`/`thumbnails`/`cache` + temp `DatabasePool` + `AppServices`), plus a
  small committed fixture set (valid, EXIF-oriented, corrupt/truncated,
  non-image) + synthetic `CGContext` images. End-to-end, no network.
- **T10 — Blob store atomicity & idempotency.** Deterministic path; idempotent
  write; bytes match; no temp/partial left at the final path (incl. simulated
  mid-write failure); concurrent same-bytes → one file; the A2 invariant (every
  asset row's blob exists).
- **T11 — Metadata extraction across formats/edges.** Dims for PNG/JPEG/HEIC;
  EXIF orientation → oriented dims; mime/kind from bytes not extension; corrupt →
  `decodeFailed`; zero-byte → error; non-image → `unsupportedType`; GIF.
- **T12 — Coordinator concurrency & partial-failure.** Mixed valid/corrupt batch
  → per-item outcomes, not aborted; bounded concurrency (≤ N in flight, via a
  probe); cancel mid-batch → no partial blobs; monotonic progress; idempotent
  retry; end-to-end (drop 3 → 3 assets, 3 blobs, thumbnails, in the collection).

### Performance
- **P13 — Stream + decode-direct-to-thumbnail-size.** Stream-hash;
  `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`
  decodes straight to target size (no full-res bitmap); stream blob to disk.
  Peak ≈ N-concurrent × (file bytes + small thumbnails).
- **P14 — Hash-first short-circuit.** Hash first; if the blob **and** all tiers
  already exist, skip decode/thumbnail and just ensure membership; regenerate
  only missing tiers (e.g. after a thumbnail purge).
- **P15 — Per-item transactions.** The metadata commit is negligible vs blob IO;
  WAL makes per-row commits cheap; keeps C8 per-item failure isolation. No DB
  batching.
- **P16 — Eager all defined tiers now.** 128/512/1280 all at ingest — trivial
  cost for local small batches. Lazy-largest is a bulk-import-era optimization.

## Build sequence (one agent per chunk, sequential)
1. **Scaffold + wiring** — `AtelierIngestion` package → `AtelierCore`, wired into
   the Xcode app (the `AtelierCore` pattern). Smoke test.
2. **MediaStore** — content-addressed sharded blob + thumbnail file store, atomic
   idempotent writes, existence checks (C6/A2). Store tests (T10).
3. **Image utilities** — SHA-256 stream hash (C5), metadata extraction (C7),
   thumbnail generation (A4/P13) + committed fixtures (T9). Extraction tests (T11).
4. **Pipeline + coordinator** — `IngestError` (C8), the blob-first pipeline (A2),
   hash-first short-circuit (P14), the bounded-concurrency actor (A3), per-item
   results. Coordinator + end-to-end tests (T12).
5. **Input adapters + app hook** — paste-image / drag-file / drag-browser-image →
   (bytes, `SourceDraft`) adapters (`local_paste` / `local_drag` / `web`), with
   tests; a thin app drop-target + paste command driving the coordinator to prove
   the loop end-to-end.

## Verification
`swift test` green across `AtelierIngestion`; the app builds with both packages
wired in; a manual paste/drag in the running app ingests → asset + blob +
thumbnails + membership, no UI stall.
