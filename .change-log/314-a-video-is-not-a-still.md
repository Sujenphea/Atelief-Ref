# 314 — A video is not a still

## Summary

The collection detail overlay was handing video blobs to ImageIO.

`CollectionDetailHost`'s `displaySource` — the closure that tells `DetailSession`
which asset has a decodable full-res image — gated only on "does this asset have a
blob hash?". A video has one. So opening a video in the overlay sent its `.mp4`
straight into `DetailImageLoader` → `ImageDecoding.thumbnailCGImage(from:url:)`,
where `CGImageSourceCreateWithURL` dutifully succeeds (ImageIO opens anything),
reports type `n/a` with zero images, and the thumbnail call fails with `-50`.

The decode was not merely doomed, it was unused: `ItemDetailView.mediaArea`
switches on the 003 · O1 render seam and draws `.video` with `VideoPlayer`, never
reading `displayImage`. `ItemDetailView.loadMedia` already had the kind check — the
Space board and library-search paths were never affected. Only the loader-backed
collection overlay lacked it.

Cost per video: one file open plus an ImageIO probe that cannot succeed, on every
open AND on every video preloaded as a prev/next *neighbour*. Nothing negative-
caches, so a bucket change re-ran it. The video's hash also occupied a slot in the
loader's retention window, reserving cache budget for an image that never lands.

Visible symptom, under Xcode only (ImageIO emits this line just when a debugger is
attached, which is why it never showed in a plain run):

    CGImageSourceCreateThumbnailAtIndex:5278: *** ERROR:
    CGImageSourceCreateThumbnailAtIndex[0] - 'n/a ' - failed to create thumbnail
    [-50] {alw:1, abs: -1 tra:1 max:2048}

The option fingerprint is the decoder's own dictionary — `alw` =
`…ThumbnailFromImageAlways`, `tra` = `…WithTransform`, `abs: -1` = `…IfAbsent`
unset — and `max:2048` is the 2048 rung of `detailPixelBuckets`. Reproduced
byte-identically by running that exact dictionary against a real `.mp4` blob.

## Change

`displaySource` now excludes `.video` before the blob lookup. Video takes the
existing media-less arm of `DetailSession.loadDisplayImage` (no decode requested,
retained image cleared), exactly as `.color` already did.

Link and tweet stay in deliberately: their blob is a still image — a resolved
og:image, a captured card — that the media area does draw.

## Files changed

- `AtelierRefs/AtelierRefs/CollectionView.swift` — kind guard in
  `CollectionDetailHost.init`'s `displaySource`, with a comment recording why a
  blob hash alone is not enough.

## Migration notes

None. Behavioural change is confined to work that could only fail. Video items
render identically (they always did — through `VideoPlayer`).

## Not fixed — diagnosed as external

Investigated alongside this and confirmed to be framework/system noise, listed so
the next reader does not re-investigate:

- `AVGlassVolumeSlider` / `AVDesktopButton` / `NSGlassView` constraint conflict —
  AVKit's own playback-control chrome. A 180pt glass container cannot hold
  12 + 128 + 9 + 22 + 9 plus insets, so AppKit drops the slider width. We own no
  constraint in that set. macOS 26 Liquid Glass bug; self-recovering. The garbled
  `<decode: bad range for [%@]>` prefix is a defect in the OS's own message
  formatter.
- `AddInstanceForFactory: No factory registered for id …F8BB1C28-BAE8-11D6…` —
  CoreAudio HAL plugin lookup on first audio-unit init.
- `<<<< VRP >>>> err=-12852`, `<<<< FigAirPlay_Route >>>> err=-12860` —
  AVFoundation reporting "nothing to do" (no AirPlay target) via error codes.
- `VSGating: … VisualLookUp.EligibilityError`, `Attempting to update all DD
  element frames … Bounds: 0x0` — Visual Look Up / Data Detectors probing the
  video surface. The app calls no `ImageAnalyzer`; AVKit enables this itself.
- `Unable to obtain a task name port right for pid 431` — a system daemon denied
  a task port for an unrelated process.
