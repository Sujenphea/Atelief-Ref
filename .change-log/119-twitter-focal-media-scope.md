# 119 — Single-capture scopes media to the focal tweet (bug fix)

Fixes: single-capturing a tweet grabbed an image from a **reply/comment** when the
tweet itself had none. The harvester enumerates every `<img>` on the page in DOM
order (`harvest.js`) and the X extractor picked the first `pbs.twimg.com/media/`
image (`twitter.js`) — which, for a text-only tweet, belonged to a reply. So a
text-only tweet saved with a stranger's image as its card.

## What ships

- **`harvest.js`** — each harvested image / video is tagged with its containing
  `<article>` index (`articleIndex`). On a tweet status page the focal tweet is the
  first `<article>` and replies follow, so this lets the extractor tell them apart.
  `buildHarvest` carries the field through only when the reader provides it (older
  fixtures / non-tweet layouts are unaffected → no scoping).
- **`extractors/twitter.js`** — DOM media is now scoped to the **focal tweet**
  (article 0): a reply's image is never borrowed. A right-clicked image
  (`context.srcUrl`) stays UNSCOPED (the user's explicit choice is honored). And when
  a focal tweet has no media, the extractor no longer falls back to X's generic
  og:image summary card — a text-only tweet stays image-less.
- **`sw.js` `captureCore`** — a text-only tweet (no image, but real tweet content) is
  no longer rejected as "no-image": it POSTs a **media-less content capture** (a text
  card) via the `ingestOne` no-image path (the same one bulk uses). Only a capture
  with NEITHER an image NOR tweet content still returns "no-image".

## Result

- Text-only tweet → a proper **text card** (no more borrowed reply image).
- Image tweet → its **own** image, auto-detected (no right-click needed), never a
  reply's.
- Right-click an image → that exact image, as before.
- Bulk sweep was already correct (per-tweet media from the timeline JSON) — unchanged.

## Files changed

- `src/harvest.js` (articleIndex on images/videos + passthrough), `src/extractors/twitter.js`
  (focal scoping + og:image only when unscoped), `src/sw.js` (captureCore text-card path).
- `test/harvest.test.js` (+1), `test/extractors.test.js` (+3: reply ignored, focal wins,
  right-click unscoped), `test/sw.test.js` (+2: text-only → text card, no-content → no-image).

## Tests

Extension **295** green (`node --test`, +6). No Swift change.

## Notes

- Closes the "single-capture of a text-only tweet" follow-on flagged in changelog 116.
- Scoping is to the first `<article>`; a quoted tweet nested INSIDE the focal tweet is
  still in article 0, so its media can be picked (matches prior behavior; the bulk
  driver's stricter "never read quoted media" rule is a separate, JSON-only concern).
