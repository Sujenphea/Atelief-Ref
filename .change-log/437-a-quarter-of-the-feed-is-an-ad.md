# 437 — a quarter of the feed is an ad

Selector and geometry readings taken at a phone viewport on all three platforms, the two
changes they justified, and the T0 probe built and verified.

## What was measured

Safari Responsive Design Mode, 400×860, live logged-in feeds. **The user-agent stayed
desktop**, so this is still each site's responsive app at phone width rather than its mobile
site — the caveat 434 carries, unchanged.

| | selector | containers | with permalink | zero-height | median height |
|---|---|---:|---:|---:|---:|
| x.com | `article` | 7 | 7 | 1 | 547 |
| instagram.com | `article` | 4 | 3 | 0 | 728 |
| pinterest.com | `[data-test-id="pin"]` | 8 | 6 | 0 | 230 |

## `no-geometry` was my automation, not the phone

[433](433-a-probe-that-reads-the-real-modules.md) added `zeroRectCount` and a `no-geometry`
reason after seeing every candidate on Instagram and Pinterest measure zero pixels tall.
**In a real browser both are zero.** The earlier reading was pages that had not rendered
under automation, not a property of the sites.

The diagnostic stays and is not wasted: x.com shows 1 zero-height container in 7, so
individual empty rects are real, and `no-geometry` fires only when *every* candidate is
empty — which is now known to be an automation signature rather than a mobile condition.
That is worth having as a tripwire precisely because it would mean the reading is untrustworthy.

## Two dead selectors removed

Instagram's `[role="presentation"] > div > div` found **1 element with 0 permalinks**. A
fallback that cannot work is worse than no fallback: it converts "the selector broke" into
"the selector found something useless". Instagram is now `article` alone, and a break shows
up as `matchedSelector: null`.

Pinterest's `[data-test-id="pin"]`, `[data-grid-item]` and `[role="listitem"]` return
identical results (8 / 6 / 230px). `[data-test-id="pinWrapper"]` returns the same count with
a **smaller box** (198px) — it is the inner wrapper, so it under-reports how much of the
viewport a pin covers, which is the one thing this file measures. Dropped. One structural
fallback kept.

## The finding: unlinked containers, and what they were doing

**About a quarter of a real feed has no permalink** — instagram 3 of 4, pinterest 6 of 8.
Ads, promoted pins, suggested-user cards.

The reader used to **drop** them. That was wrong twice:

1. **The product silently captured the wrong thing.** With the ad invisible to the chooser,
   an ad occupying the centre of the screen meant the geometric winner was a *neighbouring*
   post. Tapping save while looking at an ad would have saved a different post, and nothing
   in the code could detect it. That is the worst failure mode available here — worse than
   refusing — and 096 § D8 already reserves a `no-focal-post` status that could not fire for
   it because the evidence was thrown away.
2. **It would have corrupted T0's measurement.** The bar is ≥27/30 per platform. On
   Pinterest a quarter of the grid is unpickable, so observations where an ad was centred
   would have scored as misses caused by ad density rather than by the geometry rule, and a
   red result would not have said which.

So unlinked containers are now candidates carrying `postUrl: null`, and `chooseFocalPost`
returns a distinct `uncapturable-focal` answer when the geometric winner is one — richer
than the flat refusals, naming which container was in the way and what the nearest
capturable thing was. What the popup does with `alternative` (offer it, or say "nothing to
save here") stays a product decision; reporting it is the function's job.

`linklessCount` remains as the at-a-glance summary; the candidates now carry the geometry.

In the probe, an unlinked container is listed and **tappable** — tapping it records
`expectedPostUrl: null`, "the thing in the middle was an ad". That is a real observation
rather than a spoiled one, so the corpus measures ad density alongside the hit rate, and
`null === null` counts as a hit: the code and the human agreeing that nothing here is
capturable is as much a success as naming the right post.

## The probe is built

`xcrun safari-web-extension-converter` over a staging directory that is a manifest plus a
**symlink** to `extension/src` — never a copy, so a selector edit reaches the bundle on the
next build. Two defects, one of them predicted:

- **094 § 1's converter bug reproduced verbatim**: app id `sujenphea.Tier3Probe` (title-cased
  from `--app-name`) against extension id `sujenphea.tier3probe.Extension`, no shared prefix,
  `ValidateEmbeddedBinary` fails. Fixed with 094's own one-line `sed`.
- The staging symlink was copied *as a symlink* into the generated project, where its
  relative target no longer resolved. Repointed absolute; Xcode follows it at build time.

Verified by building for the simulator (no signing) and confirming the bundle contains
`src/probe.js`, `src/safari/focal-post.js`, `src/capture-plan.js`, the extractors — and a
manifest with **no content scripts**, which is 096 § D5's hook drop landing in a real binary.

## Files changed

- `extension/src/safari/focal-post.js` — unlinked containers become candidates;
  `uncapturable-focal` with `alternative`; two dead selectors removed, with the measurements
  recorded in comments.
- `extension/test/focal-post.test.js` — five cases: a centred ad reported not replaced, the
  alternative offered, a non-central ad still losing, an all-ads feed, and ads not collapsing
  the `no-candidates` / `none-visible` distinction.
- `extension/src/probe.js` — unlinked candidates tappable; `uncapturable-focal` rendered;
  `null === null` scores as a hit.
- `.gitignore` — `/tier3-probe-stage/`, `/tier3-probe-xcode/`.

Full suite: 606 pass, 1 skip. `drift-check` clean.

## Migration notes

None — `focal-post.js` still has no shipping consumer.

**The corpus format now admits `expectedPostUrl: null`**, and 431's replay harness compares
by equality so it already handles that. An observation with a null expectation is a real
data point: it says the centred item was an ad.

**Still open:** the true mobile DOM (ua stayed desktop in every reading so far), and the 30
observations per platform, which need the phone and a human's judgement.
