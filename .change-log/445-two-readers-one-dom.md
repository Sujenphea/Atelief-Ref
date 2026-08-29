# 445 — two readers, one DOM

There are two in-page DOM readers in this repo doing the same job for two runtimes:

- `extension/src/harvest.js` · `harvestSignals()` — injected by `scripting.executeScript`;
- `AtelierRefs/AtelierRefsShare/PagePreprocessor.js` — loaded by Safari as an
  `NSExtensionJavaScriptPreprocessingFile`.

They read the same elements and feed structurally the same shape: `buildHarvest` in JS,
`RawPageSignals` / `PageHarvest.build` in Swift. They are about 80% identical and diverge in
five places, **every one of which is deliberate and documented**:

1. the phone skips images below `MIN_SIDE` — chrome, avatars, pixels;
2. the phone caps the count at `MAX_IMAGES`, because the snapshot crosses XPC;
3. the phone must OMIT an absent key where the browser emits `alt: null` — a JS `null`
   becomes `NSNull`, which no property list can carry, and one of them makes the entire
   share unloadable ([422](422-the-null-that-could-not-cross.md));
4. the browser rasterizes a video frame to a canvas; the phone will not;
5. the phone reports `videoWidth`/`videoHeight` as 0 rather than omitting a video.

That is exactly the problem. Every divergence is justified, so nothing looks wrong, and
nothing would have noticed a **sixth** arriving by accident. `harvestSignals` is deliberately
untested ("minimal and hand-checked"); `ios-preprocessor.test.js` tested only the phone's.

Both are now run over one document stub and held to the subset they are meant to agree on.
The five above are the allowlist — expressed as an equation where possible rather than as
prose, so the phone's image list must equal the browser's filtered by exactly those caps.
A difference not on the list fails here.

## It found three on the first run

Not bugs — three spellings of the same rule, in two files that mirror each other:

| | `PagePreprocessor.js` | `harvestSignals()` |
|---|---|---|
| canonical selector | `link[rel=canonical]` | `link[rel="canonical"]` |
| canonical value | `link.href` | `getAttribute("href")` |
| page URL | `document.location.href` | bare `location.href` |

All three select or read the same thing in a real browser, and no page has ever behaved
differently. They are recorded rather than unified: changing a live selector to satisfy a
test stub is the tail wagging the dog, and the stub can honestly answer both. What they are
is evidence that two files drift in small ways nobody sees — which is the argument for the
test, made by the test, before it had asserted anything.

`both readers agree on the page's identity` now pins that all three still arrive equal.
`PageExtractor.liveURL` and the JS extractors key provenance off these fields, and 18A dedup
keys off provenance, so "same value by a different route" is the property that matters.

## What is asserted

- **identity** — `url`, `canonical`, `title` equal across both readers;
- **metas** — deep-equal, in document order, duplicates intact (which one wins is a decision,
  and decisions live in the pure half of each language);
- **article indices** — equal per image src. The one that matters most and is hardest to
  notice breaking: the X extractor scopes media to the FOCAL article, so a disagreement here
  means the phone captures a reply's photo where the browser captures the tweet's;
- **images** — the phone's list equals the browser's filtered by `MIN_SIDE`/`MAX_IMAGES`,
  with identical dimensions for the survivors;
- **the null discipline** — asserted in BOTH directions, so a future edit that "tidies" the
  preprocessor by emitting nulls fails with 422's reason attached.

## Files changed

- `extension/test/ios-preprocessor.test.js` — `makeDocument` extracted from `snapshot()` so
  one description feeds both readers; `browserHarvest` sets and restores the `document` and
  `location` globals; five comparison tests.

Nothing in `src/` or the share extension changed. This is a test-only commit.

## Verification

`node --test test/ios-preprocessor.test.js` → 13 tests, all pass (was 8).
`node --test` → **617 tests**, 616 pass, 1 skip (the T0 corpus gate), 0 fail. Was 612.

## Migration notes

None.
