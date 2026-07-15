# 123 — Single-capture tweet: multi-image `media[]` (003 · C3 follow-on)

A single X capture of a multi-photo tweet now records ALL the tweet's photos in
`payload.media[]` (card first), not just the one card image — matching what the bulk
sweep already does. The card (first photo) is the only image fetched as bytes; photos
2–4 ride as URL references, so a 4-photo tweet is still ONE network request.

Closes the last of the 003 · C3 single-capture tail. (The sibling text-only-tweet
follow-on already shipped in `54b865e`; the plan record is `.docs/026`.)

## What changed

- **`extractors/twitter.js`** — collects the focal tweet's OWN photos into `mediaUrls`:
  every `pbs.twimg.com/media/` image in the focal `<article>`, card first, deduped,
  capped at X's max of 4, each rewritten to full-res (`name=orig`). A nested quoted
  tweet's picture is excluded (see harvest change) — parity with the bulk mapper, which
  reads only the top-level tweet's entities. `mediaUrls` is attached as a CLIENT HINT.
- **`harvest.js`** — `harvestSignals` flags media inside a nested quoted-tweet container
  (`closest('[role="link"]')` within the article) with `quoted: true`; `buildHarvest`
  carries the flag through (like `articleIndex`). This also fixes a latent card bug: a
  text-only tweet QUOTING a photo tweet no longer borrows the quoted image — it stays a
  text card.
- **`endpoint.js`** — `tweetContent` reads `provenance.mediaUrls` (falling back to the
  single `mediaUrl` for older provenance). `normalizeProvenance` is unchanged — its key
  whitelist already drops `mediaUrls`, so the JS↔Swift wire contract and its fixture are
  byte-identical (no Swift/schema/server change).
- **`scripts/drift-check.js`** — adds the X harvest DOM selectors (focal `<article>` +
  quoted `[role="link"]`) to the live drift-marker checklist.

## Design notes (from `.docs/026`, interactive review)

- **DOM harvest, not the resolver.** The extra photos come from the harvest already in
  hand — NOT C2b's `PageResolver` (x.com is on `isAuthWalledHost`, so app-side
  resolution is refused by design). The 003 "waits on C2b" note was a misread; corrected.
- **`buildTweetPayload` stays the only shared seam** (single + bulk); each side collects
  media in its own idiom (DOM vs timeline JSON) — no forced shared collector.
- **References, not fetches** — media[] beyond the card are URL strings; one image fetch
  regardless of photo count.

## Tests (extension, `node --test`: 298 → 311 green)

- `extractors.test.js` — multi-photo collect (card first); quoted excluded from media[]
  AND the card; text-only tweet quoting a photo → text card; dedupe; cap-4; single-photo;
  right-clicked photo leads; text-only → empty media[].
- `harvest.test.js` — `quoted` carry-through (present when set, omitted for older snapshots).
- `endpoint.test.js` — `tweetContent` full-list + single-URL fallback; `mediaUrls`
  dropped from the wire provenance via both request builders (2A/10A).
- `sw.test.js` — a multi-photo tweet triggers exactly ONE `fetchImage` call (12A).

The quoted-tweet DOM DETECTION in `harvestSignals` stays E2E/drift-checked (no jsdom, per
the harvest test-suite decision); the pure carry-through + extractor filter are unit-tested.

## Migration notes

None. No schema, Swift, server, or wire-contract change.
