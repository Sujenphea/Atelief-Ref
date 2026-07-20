# 170 — Bake-off library seeder + library-root override

## Summary

Unblocks the grid-performance bake-off, which must be measured at 2000 items,
by adding (1) a way to point the app at a throwaway library and (2) a
reproducible seeder that fills one with real images.

**Library-root override.** `LibraryLocation.resolvedRoot()` returns an override
when one is supplied and is otherwise exactly `defaultRoot()`. The override comes
from the `-library-root <value>` launch argument, or the `ATELIER_LIBRARY_ROOT`
environment variable when the argument is absent. `IngestionModel.bootstrap()`
now calls `resolvedRoot()` instead of `defaultRoot()` — a one-line change.

Because the app is sandboxed (`com.apple.security.app-sandbox`, with only
`files.user-selected.read-only`), an arbitrary absolute path is **not** writable
from inside the container. The value is therefore interpreted two ways:

- a **relative** value is a directory name under Application Support
  (`<Application Support>/<value>/`) — always sandbox-legal, and the form the app
  itself should be launched with;
- an **absolute** path is used verbatim, for unsandboxed callers.

An empty/whitespace value is ignored. With no argument and no environment
variable, behaviour is unchanged — verified by launching the app both ways and
watching which library's SQLite files get touched.

**Seeder.** `BakeoffSeedTests.seedBakeoffLibrary()` generates N JPEGs with
CoreGraphics/ImageIO (15 dimension buckets from 800×600 to 3000×2000, covering
portrait/landscape/square/extreme; hue-rotated gradient + random shapes + noise
blocks, quality 0.7) and ingests them through the production
`IngestPipeline`/`IngestCoordinator`, so blobs, all three thumbnail tiers, and
asset rows match a real capture. Images come from a seeded SplitMix64 PRNG, so a
given N reproduces the same library.

It is **not** part of the normal suite run: `.enabled(if:)` on
`ATELIER_SEED_BAKEOFF`, so `xcodebuild test` skips it. It also refuses to run
unless the library-root override is set, so seeding can never land in the user's
real library.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Media/LibraryLocation.swift` —
  added `resolvedRoot()`, `overrideValue()`, `overrideArgument`,
  `overrideEnvironmentKey`. `defaultRoot()` untouched.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `bootstrap()` now calls
  `resolvedRoot()`.
- `AtelierRefs/AtelierRefsTests/BakeoffSeedTests.swift` — new; the seeder.

## Usage

Seed (note both the `TEST_RUNNER_` prefix and the parallel flag — see below):

```
TEST_RUNNER_ATELIER_LIBRARY_ROOT=bakeoff-library \
TEST_RUNNER_ATELIER_SEED_BAKEOFF=2000 \
xcodebuild test -project AtelierRefs/AtelierRefs.xcodeproj \
  -scheme AtelierRefs -destination 'platform=macOS' \
  -only-testing:AtelierRefsTests/BakeoffSeedTests \
  -parallel-testing-enabled NO
```

Then launch the app against it:

```
AtelierRefs.app/Contents/MacOS/AtelierRefs -library-root bakeoff-library
```

Delete `<Application Support>/bakeoff-library/` to reset.

## Measured (N=2000, M-series, Debug build)

| | |
|---|---|
| wall clock | 62.0 s (32.3 img/s) |
| ingested / failed / deduplicated | 2000 / 0 / 0 |
| source JPEG generated | 159.9 MB |
| library on disk | 456.7 MB (blobs 160 MB + thumbnails ~290 MB) |
| thumbnails | 6000 files (2000 × 3 tiers) |

## Notes / gotchas

- **`TEST_RUNNER_` prefix is required.** xcodebuild does not forward the shell
  environment to the test host; a bare `ATELIER_SEED_BAKEOFF=…` is silently
  ignored and the test just skips.
- **`-parallel-testing-enabled NO` is required.** xcodebuild otherwise spawns two
  runner *processes* that both seed the same SQLite library and race — observed
  as one lost item out of 50. Swift Testing's `.serialized` cannot help, as the
  contention is cross-process.
- Re-running tops up the same `Bakeoff` collection, but the seeded RNG
  regenerates identical bytes, which the pipeline correctly dedups. Delete the
  library root first for a clean full-size seed.
- Pre-existing, unrelated: running *any* hosted test boots the host app, whose
  `IngestionModel.bootstrap()` opens the real library (and may take a daily
  snapshot). Setting the override during test runs now avoids this.

## Migration notes

None. Additive; no call sites change behaviour without the new argument.
