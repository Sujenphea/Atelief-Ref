# 124 — Fix: drop the overbroad tweet quoted-media filter (dropped own photos)

The quoted-tweet exclusion added in 123 broke multi-photo single capture entirely: a
2–4 photo tweet saved as a **text card with no image**. Reverted the exclusion; a tweet's
photos are collected again.

## Root cause

123 flagged media inside a nested quoted tweet via `el.closest('[role="link"]')` and
filtered it out of both the card and `media[]`. But X wraps its **own** clickable photos
(and, in a feed, the whole tweet cell) in `[role="link"]` too — so `isQuoted` matched the
focal tweet's OWN photos and excluded all of them. Result: `mediaUrl` null + empty
`media[]` → a media-less text card. Confirmed live: a 4-photo tweet stored `media_count=0`,
no card blob; a console check showed all 4 photos correctly in the focal `<article>` (index
0), proving the scoping was fine and only the `quoted` filter was at fault.

## What changed (revert of 123's exclusion only; multi-image collection kept)

- **`harvest.js`** — removed the `isQuoted` detection, the `quoted` field on image/video
  reads, and the `quoted` carry-through in `buildHarvest` (`withArticle` restored).
- **`extractors/twitter.js`** — `focal` is back to `articleIndex === 0` only; `media[]`
  collects all focal `/media/` photos (card first, deduped, cap-4, full-res). A TODO notes
  that correct quoted-exclusion needs a per-photo status-id signal, not the `role="link"`
  heuristic.
- **`scripts/drift-check.js`** — drift marker updated (focal `<article>` + `/media/`
  photos; no `role="link"`).
- Tests — removed the 3 quoted-specific cases; the multi-photo / dedupe / cap-4 /
  single-photo / right-click / text-only cases remain. Extension `node --test`: **308 green**.

## Known limitation (accepted; follow-up)

A quoted tweet's photo rendered inside the focal `<article>` can now leak into `media[]`.
This is rare and benign (an extra reference) versus dropping every own photo. A correct
fix compares each photo link's `/status/<id>/photo/` id to the focal tweet id — deferred
as its own change; bulk already handles quotes structurally via `quoted_status_result`.

## Migration notes

None. Extension JS only; no schema/Swift/wire change.
