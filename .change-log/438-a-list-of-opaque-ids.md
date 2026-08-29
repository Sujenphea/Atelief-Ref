# 438 — a list of opaque ids

The first real device readings for [096](../.docs/096-tier3-plan.md) § T0, the corpus they
seeded, and the protocol defect they exposed.

## The defect, first, because it invalidates data

The probe listed candidates by post URL and asked a human to tap the one that was centred.
On x.com that works: the handle is in the path, so `/andrewwoan/status/…` names something a
person can see on screen. **On instagram it is `/p/DcdkytGm1iW/` and on pinterest
`/pin/477311260530128089/`** — opaque ids that match nothing visible.

So on two of three platforms the probe was asking for a guess. Four observations were
recorded that way before it was noticed, and they have been **discarded**: a corpus of
guesses is worse than no corpus, because it looks like evidence and would have been pinned
in CI as ground truth.

Candidates now carry `thumb` (the container's first `<img>` src) and `alt`, and the probe
renders a 52px thumbnail per row. That is the reference the list was missing.

## What the four surviving observations say

All x.com, all hits, and decisive in a way the hit rate alone would not show:

| platform | hits | winning margins (px) |
|---|---|---|
| x.com | 4/4 | 350, 350, 350, 350 |

A margin of 350 is the **entire** centre band with the runner-up scoring **zero** — no other
post touched the middle of the screen. On a 699px viewport with posts 400–680px tall, one
post owns the centre. That is 096 § D1's argument in its strongest form, on a real phone.

Confirmed at the same time:

- `matchedSelector: "article"` on real mobile Safari, not just at desk width.
- `zeroRectCount: 0` everywhere — [433](433-a-probe-that-reads-the-real-modules.md)'s
  `no-geometry` really was an automation artifact. The tripwire stays; it now means "distrust
  this reading".
- **`/analytics` URLs in three of four readings.**
  [432](432-the-tweet-with-only-an-analytics-link.md) confirmed on-device.
- **Every** instagram URL was `/liked_by/`, in the discarded readings as well as the kept
  geometry — [434](434-every-instagram-link-was-a-liked-by-link.md) vindicated.
- [22A](437-a-quarter-of-the-feed-is-an-ad.md)'s null candidates appeared for real (2 on
  pinterest, 1 on instagram) and correctly lost rather than winning.

## Pinterest is a grid, and the rule is vertical-only

This finding **survives** the discarded observations, because a margin is computed from
geometry alone — it does not depend on what the human answered.

Pinterest's two readings produced winning margins of **15px and 46px**, against 274–350 on
the single-column feeds. `chooseFocalPost` scores vertical overlap with a centre band, which
is complete information when one post spans the width; pinterest.com is 2-column masonry, so
two pins share the vertical centre and 15px of difference is layout noise deciding the
outcome.

No rule change yet, deliberately. A centre-BOX rule may tie just as often on a symmetric
grid — a left-column and a right-column pin are equidistant from the centre line — and it is
not obvious that "the pin you are looking at" is even well defined there. What was missing
was the ability to *evaluate* any candidate rule: the reading recorded no horizontal extent,
so no horizontal rule could be tested offline and every attempt would have cost a fresh 30
taps. Candidates now carry `left` and `right`. Cheap to record, impossible to backfill.

## Files changed

- `extension/src/safari/focal-post.js` — candidates carry `left`, `right`, `thumb`, `alt`.
- `extension/src/probe.js`, `extension/src/probe.html` — thumbnail + alt-text rows.
- `extension/test/fixtures/focal-post-observations.json` — new, 4 x.com observations.
- `.change-log/438-a-list-of-opaque-ids.md` — this file.

Full suite: **607 pass, 0 skipped** — the corpus replay now runs instead of skipping, which
is the first time 096 § T0's second bar has been a live gate rather than a placeholder.

## Migration notes

The four kept observations predate `left`/`right`/`thumb`, so they carry none. That is
harmless — `chooseFocalPost` does not read them — but any horizontal rule must be evaluated
against observations captured from here on.

**Still open:** 30 per platform, now with a usable list. And the corpus still does not record
the provenance panel, so § T0's rider 2 (the D5 hook-drop gate — is the DOM alone enough?)
remains an on-screen reading rather than a counted one.
