# 444 — one authority, and a gate on the mirror

Two halves of the same complaint: a decision that had two implementations, and a mirror
that had none checking it.

## The plan decides what there is to capture, once

[436](436-the-decision-without-the-transport.md) pulled the capture DECISION out of `sw.js`
into `capture-plan.js`, so tier 3 could consume it without inheriting the localhost
transport. It left one copy behind.

`captureCore` opened with a hand-written `!provenance.mediaUrl && !content`, which is
`planCapture`'s `kind === "none"` asked a second time and **more narrowly** — `planCapture`
builds candidates from `[mediaUrl, mediaUrlFallback].filter(Boolean)` and this ignored the
fallback.

**Not a live bug, and the reason it wasn't is the interesting part.** `mediaUrl` is null only
when `rendered` is null, and every rewrite helper is *total*: `toOrigName` returns `src` when
`new URL` throws, `toOriginals` returns `src` when its regex misses, `toRednoteOriginal`
returns `src` in every branch. So `mediaUrl == null` implies `mediaUrlFallback == null`
across all five extractors — an invariant spread over five files and asserted nowhere.

The shape that breaks it is the obvious one to write: a regex-replace helper returning `null`
when it does not match. Nothing would have failed loudly. A capture would report `no-image`
and be lost with a usable URL sitting in its own provenance.

So `captureCore` asks `planCapture`, and the invariant is pinned anyway — belt and braces,
because the test documents what the extractors promise while the call site stops depending on
the promise. `no extractor produces a mediaUrlFallback without a mediaUrl` walks each
extractor down its no-media path (including an unparseable src and one matching no rewrite
rule); `every media-URL rewrite helper is total` asserts the property underneath it directly.

`ingestOne` gained the matching guard. It is the bulk engine's tail and tier 3's as well, and
reaching it with an empty plan used to fall through to `fetchImage([])` — which throws its
"No media URL to fetch." placeholder and surfaces as **`fetch-error`**: a sweep item
classified as a network failure when there was simply nothing on the post. The plan already
said so; now that is what gets reported.

## The mirror nobody checked, checked

`PageExtractor.swift` is a hand-written Swift mirror of the JS extractors, because the share
extension cannot run JavaScript and the phone has to reach the same URL a browser would.
[404](404-the-mirror-nobody-checked.md) made the host → platform half a CI gate. The
**rewrite rules** half had nothing.

That is the half that has actually drifted, in this branch:
[422](422-the-null-that-could-not-cross.md) found `format=webp` and `name=orig` are
incompatible — twimg 404s the pair, and the caller then silently captures the rendered size
while looking successful. The fix landed on the phone, where the bug was hit. It then had to
be carried back to `base.js` by hand ([428](428-three-cdns-none-of-them-asked.md)). One bug,
found once, fixed twice, with nothing in either suite to say the second fix was owed.

`extension/test/fixtures/media-rewrite-contract.json` now holds eleven cases, read by
`extractors.test.js` against `base.js` and by `PageExtractorTests.swift` against
`PageExtractor`. Same device as `capture-contract.json`, pointed at the other end of the same
mirror; the file lives under `extension/` so neither side owns it.

**It is not a URL-normalisation test.** Every case is a well-formed URL with an unambiguous
rewrite, because `URL.toString()` and `URLComponents.string` are entitled to disagree about
percent-encoding and that is not what this pins.

## Verification

Both implementations agree on all eleven cases today — no drift found, which is the expected
result for a gate installed after the last one was fixed by hand.

The gate was checked for teeth rather than assumed to have them: perturbing one fixture
expectation fails the Swift suite (`toOriginals … recorded an issue … expected
"…/DELIBERATELY-WRONG/…"`) and the node suite (`# fail 1`) together. Restored, and both green.

- `node --test` → **612 tests**, 611 pass, 1 skip (the T0 corpus gate), 0 fail. Was 610.
- `swift test` in AtelierCapture → **132 tests in 8 suites**, all pass. Was 130.
- `npm run drift-check` → no drift.

## Files changed

- `extension/src/sw.js` — `captureCore` asks `planCapture`; `ingestOne` returns `no-image`
  with the plan's `reason` instead of falling into `fetchImage([])`; `CAPTURE_KIND` imported.
- `extension/test/extractors.test.js` — the two invariant tests and the two contract tests.
- `extension/test/fixtures/media-rewrite-contract.json` — new, eleven cases.
- `AtelierCapture/Tests/AtelierCaptureTests/PageExtractorTests.swift` — the Swift half.

## Migration notes

`ingestOne` can now return `{ status: "no-image", reason }` where it previously threw its way
to `fetch-error`. Callers already handle `no-image`; `reason` is additive and ignored by
anything that does not read it.
