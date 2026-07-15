# 026 — Single-capture tweet follow-ons: multi-image `media[]` + text-only (plan)

> The two remaining 003 · C3 tail items (see `003-multi-kind-items.md:180-181`):
> **①** a single X capture of a multi-photo tweet carries ALL its photos in
> `payload.media[]` (not just the card), and **②** a text-only tweet can be
> single-captured (today it dies at the `no-image` guard). Bulk already does both;
> this closes the single/bulk gap. No Swift/schema/server change — both ride the
> media-less + hybrid content paths the server already accepts.

## Scope

- **In:** single-item X capture (context-menu "Save to Atelier") of photo and
  text-only tweets. Extractor + `tweetContent` + `captureCore` (extension JS only).
- **Out:** bulk (already multi-image + text-only); video tweets (unchanged — the
  video opt-in path is orthogonal); any Swift/server/schema change.

## Locked decisions (interactive review, all recommended options taken)

### Architecture
- **1A — DOM-harvest is the source of the extra photos.** The focal tweet's photos
  are already in the harvest (`articleIndex === 0`); collect them, no network call.
  NOT the C2b resolver — x.com is on `PageResolver.isAuthWalledHost`, so routing tweet
  media through it contradicts the resolver's own design. (003's "waits on C2b" note
  was a misread; correct it.)
- **2A — Media list rides as a DROPPED client hint.** Add `provenance.mediaUrls`;
  `normalizeProvenance` already whitelists keys (`endpoint.js:21-30`), so the list
  never hits the wire — the Swift `CaptureRequest`/contract fixture stay byte-identical.
  `mediaUrl`/`mediaKind` are the existing precedent for dropped hints.
- **3A — Reorder `captureCore`** so a tweet's content is computed before the no-image
  decision, giving one decision point instead of two detection sites.

### Code quality
- **4A — `buildTweetPayload` stays the ONLY shared seam.** Bulk (`mapTweet`, timeline
  JSON) and single (extractor, DOM harvest) collect media in their own idioms; the
  payload shape is already centralized. A shared collector over divergent inputs would
  be premature abstraction.
- **5A — Exclude nested quoted-tweet media.** The focal `<article>` also contains a
  quoted tweet's rendered photo (it has no separate `<article>`), so scoping by
  `articleIndex === 0` alone would leak it. Tag quoted media in `harvestSignals`
  (`closest('[role="link"]')` inside the article) and filter it out — parity with
  bulk's structural "top-level entities only" rule.
- **6A — `media[]` hygiene:** dedupe by URL, cap at X's max of 4, `toOrigName` each.
- **7A — Explicit `captureCore` branch order:** `(!media && !content) → no-image` →
  `no-token` → `(!media && content) → media-less ingest, SKIP video` → else today's
  media path (video detect → shared tail). A media-less tweet never touches video
  resolution.

### Tests
- **8A — Full extractor matrix** (synthetic harvest, extending the existing
  focal-scoping tests `extractors.test.js:47-69`): multi-photo → all, card first;
  quoted excluded; dedupe; cap-4; rewrite-each; single-photo regression; text-only →
  empty; right-clicked image is card and present.
- **9A — Quoted DOM detection stays E2E-only** (consistent with the no-jsdom decision
  `harvest.test.js:5`); unit-test `buildHarvest`'s `quoted` carry-through + the
  extractor filter; add the selector to the drift-check manual checklist.
- **10A — Wire regression guard:** assert `normalizeProvenance` drops `mediaUrls` and
  the contract fixture is unchanged.
- **11A — `captureCore` branch table** incl. the NEGATIVE assertion that
  `resolveTwitterVideo`/`twitterHasVideo` are not called for a media-less tweet, and
  the `no-token` short-circuit.

### Performance
- **12A — References, not fetches.** Only the card (first photo) is fetched as bytes;
  photos 2–4 are URL references in `payload.media[]`. One `fetchImage` call regardless
  of photo count (matches bulk; safe on the user's own X session). Pinned by a test.

## Files to change

- `extension/src/harvest.js` — `harvestSignals` tags `quoted` on nested-quote media;
  `buildHarvest` carries `quoted` through (like `articleIndex`).
- `extension/src/extractors/twitter.js` — collect focal, non-quoted `/media/` photos →
  `mediaUrls` (card first, deduped, cap-4, `toOrigName` each).
- `extension/src/endpoint.js` — `tweetContent` reads `provenance.mediaUrls`
  (fallback `[mediaUrl]`). `normalizeProvenance` unchanged (whitelist already drops it).
- `extension/src/sw.js` — `captureCore` 7A reorder.
- Tests: `extractors.test.js`, `harvest.test.js`, `endpoint.test.js`, `sw.test.js`.
- `.change-log/123-*.md`.

## Migration / contract impact

**None.** No schema, no Swift, no server, no wire-contract change — `payload.media[]`
already accepts N references, and the media-less/hybrid content POST paths are the
same ones bulk exercises.

## Test strategy

`node --test` in `extension/` green (extractor matrix, harvest carry-through, endpoint
drop + tweetContent, captureCore branch table). No new deps; no live network.
Manual/E2E: the drift canary continues to cover the `harvestSignals` quoted selector.

## Status (shipped)

- **Feature ② (text-only single capture): was ALREADY implemented** before this plan —
  `captureCore`'s 3A reorder landed in `54b865e`, with the branch-table tests
  (`sw.test.js:224-277`). The 003 doc simply hadn't been updated. No rework done.
- **7A REVERSED (user-confirmed).** The locked "skip video resolution for a media-less
  tweet" turned out to be wrong: the committed code runs video detection even when
  media-less, which correctly rescues a video tweet whose poster didn't harvest — at the
  cost of one doomed syndication fetch per genuinely text-only capture (a non-hot
  user-gesture path). Kept the committed behavior; did NOT apply the skip.
- **Feature ① (multi-image `media[]`): shipped** — changelog 123. Extension JS only.
- **5A REVERTED (changelog 124).** The quoted-exclusion via `closest('[role="link"]')`
  was overbroad — X wraps a tweet's OWN clickable photos in `[role="link"]`, so it
  dropped them and a multi-photo tweet saved as a media-less text card. Reverted the
  exclusion (harvest `quoted` flag + extractor filter); `media[]` collects all focal
  photos again. Correct quoted-exclusion needs a per-photo status-id signal — deferred as
  its own change. Net tests: 308 green.
