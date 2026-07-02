# 048 — CanvasRenderer fixture determinism test de-flaked

## Summary

`FixtureImageSetTests."encoded bytes are deterministic for a fixed seed (T12)"`
was **flaky** (passed ~2 of 3 runs). It asserted that two `FixtureImageSet`
runs with the same seed produce **byte-identical** encoded image `Data`. The
seed does deterministically control the generated **pixels**, but ImageIO's PNG
encoder is **not byte-deterministic** on macOS 26 / Xcode 26 — its filter/zlib
choices jitter the encoded size run-to-run (e.g. 633855 vs 634007 bytes). The
source comment in `FixtureImages.swift` had assumed PNG encoding was
byte-stable; that assumption no longer holds on this toolchain.

This is a **test-harness determinism bug, not a product bug** — the pixels the
seed governs are reproducible; only the encoded container jitters. The fix moves
the determinism assertion from the encoded-bytes layer down to the **decoded
pixel** layer, which is exactly what "same seed → same image" is meant to
guarantee, and is robust to encoder jitter.

## What changed

- **`SpikeDataTests.swift` — reworked the flaky test.**
  - `"encoded bytes are deterministic for a fixed seed (T12)"` →
    `"the same seed yields pixel-identical images (T12)"`. It now decodes both
    encodings back to raw RGBA buffers and asserts equal **dimensions** and
    equal **pixel bytes** per image (PNG is lossless, so identical source pixels
    must decode identically). Robust to non-byte-deterministic encoders.
  - Added `"a different seed yields different images"` — decodes both sets and
    asserts the pixel buffers differ. This guards the determinism test from
    being trivially true (e.g. all-`nil` decodes comparing equal).
  - Added a private `decodedPixels(_:)` test helper that decodes encoded image
    `Data` into a normalised `(width, height, [UInt8])` RGBA buffer via
    `CGImageSource` + a fixed-format `CGContext`.
  - Added `import Foundation` (needed for `Data`).
- **No product code touched.** The generator already exposes `encoded`, and PNG
  losslessness makes decode-and-compare a faithful seam — no test-visible
  accessor was required.

## Files changed

- `CanvasRenderer/Tests/CanvasRendererTests/SpikeDataTests.swift` — reworked the
  determinism test to compare decoded pixels, added the different-seed
  divergence test and the `decodedPixels(_:)` helper, added `import Foundation`.

## Verification

Target suite (`swift test --filter FixtureImageSet`), 5 consecutive runs — all
green (previously flaky):

```
􁁛  Test run with 5 tests in 1 suite passed after 0.761 seconds.
􁁛  Test run with 5 tests in 1 suite passed after 0.745 seconds.
􁁛  Test run with 5 tests in 1 suite passed after 0.747 seconds.
􁁛  Test run with 5 tests in 1 suite passed after 0.882 seconds.
􁁛  Test run with 5 tests in 1 suite passed after 0.748 seconds.
```

An additional 8-run loop of the same suite was also 8/8 green.

**Note — a separate, unrelated flake exists.** The full-suite 5-run
(`swift test`) still shows intermittent failures, but they are **not** the test
fixed here and **not** a byte-equality issue:

```
Test run with 79 tests in 16 suites failed after 3.325 seconds with 3 issues.
Test run with 79 tests in 16 suites failed after 16.146 seconds with 2 issues.
Test run with 79 tests in 16 suites passed after 3.348 seconds.
Test run with 79 tests in 16 suites failed after 5.079 seconds with 1 issue.
Test run with 79 tests in 16 suites passed after 3.299 seconds.
```

Every failing issue is in `DecodeSchedulerTests."an async request populates the
cache and fires onDecoded"` (`HostTests.swift:149`): it waits on a fixed
2-second `Task.sleep` for a background decode + main-actor hop, and under
parallel suite load the decode misses that window, so the `confirmation` fires 0
times. That is an async-timing flake in a different file and out of this task's
stated scope (byte-equality de-flake), so it was left untouched.

## Migration notes

None. Test-only change; no product code, schema, or public-API change. The
stale "PNG encoding is deterministic" rationale in
`FixtureImages.swift`'s doc comment is now inaccurate on macOS 26 / Xcode 26 —
determinism is guaranteed at the pixel layer, not the encoded-byte layer — but
the comment was left as-is to respect the test-only scope.
