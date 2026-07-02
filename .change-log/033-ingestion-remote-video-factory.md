# 033 — Ingestion: remoteVideo file-URL factory (video capture, checkpoint B)

Adds `DirectInputReader.remoteVideo(fileURL:provenance:into:)` — the video
counterpart to `remoteInput`. A captured video is too large to carry as
base64/JSON in memory, so the localhost endpoint streams it to a temp file and
this factory ingests it via `ByteSource.fileURL` (the same disk-backed path a
dragged file uses). Rich caller-supplied `SourceDraft` is passed through verbatim,
exactly like `remoteInput`.

No downstream change: the pipeline already classifies `.movie` bytes as a `.video`
asset (`ImageMetadata.classify`), so a video flows through the existing
coordinator/pipeline/MediaStore unchanged.

## Files changed
- `AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputReader.swift`
- `AtelierIngestion/Tests/AtelierIngestionTests/DirectInputReaderTests.swift`
  (+1 test: provenance verbatim + `.fileURL` source)

## Verification
- `swift test --filter DirectInputReaderTests` → 11/11.
