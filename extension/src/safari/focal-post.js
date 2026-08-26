// Atelier Capture — focal-post selection for the tier-3 popup trigger (096 § D1, T0/T3).
//
// iOS Safari has no context menu, so there is no `info.srcUrl` telling the extension
// which post the user means (094 § 2). 096 § D1's answer is that a phone viewport does
// most of that disambiguation by itself: it shows one post, sometimes two, and the one
// the user means is the one occupying the middle of the screen.
//
// Split the way `harvest.js` splits, and for the same reason:
//
//   · `readPostCandidates()` runs IN THE PAGE (serialized by `scripting.executeScript`)
//     and MUST be self-contained — no imports, no closure. It does only what needs a live
//     DOM: find the post containers, read their rects, and read each one's permalink. It
//     classifies nothing.
//   · `chooseFocalPost(reading)` is PURE — numbers in, one candidate out. Every rule
//     lives here, so the breakable half is unit-tested with plain objects and no DOM stub.
//
// **A candidate carries its post URL, not a post id.** Each extractor already derives its
// own id from a URL — `firstPostURL([context.linkUrl, …], isPost)` in twitter.js:24,
// instagram.js:21 and pinterest.js:27 — so handing the chosen `postUrl` through as
// `context.linkUrl` reuses that path unmodified. Re-parsing ids here would be a fourth
// copy of a rule that already lives in three places and is checked by drift-check.
//
// **The selectors are a list, and the reading says which one fired.** The mobile DOM of
// three SPAs is exactly the thing this file cannot know from a desk, so `matchedSelector`
// is part of the output: T0 (096) reads it off a real phone and the answer is data rather
// than a guess. A platform whose first selector finds nothing falls through to the next.

// ---------------------------------------------------------------------------
// The page reader (self-contained — serialized into the tab).
// ---------------------------------------------------------------------------

/**
 * Runs in the page. Returns a raw geometric reading — no classification, no scoring:
 *
 *   {
 *     url, host, matchedSelector,
 *     viewport: { height, width },
 *     candidates: [{ index, postUrl, top, bottom, area, visibleArea }],
 *     containerCount, linklessCount, zeroRectCount
 *   }
 *
 * `top`/`bottom` are viewport coordinates (`getBoundingClientRect`), so they are negative
 * above the fold and exceed `height` below it. `chooseFocalPost` clips; this does not.
 *
 * Every rect is read in one pass after the query, with no interleaved style writes, so
 * the browser does one layout rather than one per candidate.
 *
 * Self-contained by requirement: `executeScript` serializes this function, so it cannot
 * reference anything in this module (see `harvestSignals`, which carries the same rule).
 */
export function readPostCandidates() {
  // Per-platform post containers, in fallback order, paired with the selector that finds
  // that container's permalink. First selector yielding at least one container wins.
  const RULES = [
    {
      hosts: ["x.com", "twitter.com"],
      containers: ["article"],
      link: 'a[href*="/status/"]',
    },
    {
      hosts: ["instagram.com"],
      // `article` only. The `[role="presentation"] > div > div` fallback this list used to
      // carry was measured at a phone viewport and found 1 element with 0 permalinks — a
      // fallback that cannot work is worse than none, because it turns "the selector broke"
      // into "the selector found something useless". If `article` ever stops matching, the
      // reading reports `matchedSelector: null` and says so plainly.
      containers: ["article"],
      link: 'a[href^="/p/"], a[href^="/reel/"]',
    },
    {
      hosts: ["pinterest.com", "pinterest.co.uk"],
      // Measured at a phone viewport: `[data-test-id="pin"]`, `[data-grid-item]` and
      // `[role="listitem"]` all return the same 8 containers with the same 6 permalinks and
      // the same 230px median height. `[data-test-id="pinWrapper"]` returns the same count
      // but a SMALLER box (198px) — it is the inner wrapper, so it under-reports how much of
      // the viewport a pin covers, and this file's whole job is measuring that. Dropped.
      // One structural fallback is kept for the day Pinterest renames its test ids.
      containers: ['[data-test-id="pin"]', "[data-grid-item]"],
      link: 'a[href^="/pin/"]',
    },
  ];

  const host = location.hostname.toLowerCase();
  const hostIs = (domain) => host === domain || host.endsWith("." + domain);
  const rule = RULES.find((entry) => entry.hosts.some(hostIs)) || null;
  const base = {
    url: location.href,
    host,
    matchedSelector: null,
    viewport: { height: window.innerHeight, width: window.innerWidth },
    candidates: [],
    containerCount: 0,
    linklessCount: 0,
    // Containers that HAVE a permalink but measure zero pixels tall. Observed on both
    // instagram.com and pinterest.com while validating these selectors: the selector
    // matched, the links were there, every rect was 0. Whether that is virtualization,
    // `content-visibility`, or a feed that had not laid out is unresolved — so it is
    // COUNTED rather than guessed at, because "the page had no geometry to give" and
    // "the user scrolled every post off screen" are different failures that would
    // otherwise arrive as the same empty result.
    zeroRectCount: 0,
  };
  if (!rule) return base;

  let elements = [];
  let matchedSelector = null;
  for (const selector of rule.containers) {
    const found = Array.from(document.querySelectorAll(selector));
    if (found.length) {
      elements = found;
      matchedSelector = selector;
      break;
    }
  }
  base.matchedSelector = matchedSelector;
  base.containerCount = elements.length;

  // Read every permalink first, THEN every rect: two homogeneous passes, so the layout
  // the rect reads force happens once.
  const links = elements.map((element) => {
    const anchor = element.querySelector(rule.link);
    return anchor ? anchor.href : null;
  });
  const rects = elements.map((element) => element.getBoundingClientRect());

  for (let index = 0; index < elements.length; index += 1) {
    const postUrl = links[index];
    // A container with no permalink cannot be captured — an ad, a promoted pin, a
    // "suggested for you" card. It is still a CANDIDATE, carrying `postUrl: null`.
    //
    // Dropping them was the earlier behaviour and it was wrong twice over. Measured at a
    // phone viewport, about a quarter of a feed is unlinked (instagram 3 of 4, pinterest 6
    // of 8), so an ad occupying the centre of the screen is common — and with the ad
    // invisible to the chooser, the geometric winner became a NEIGHBOURING post. The popup
    // would then silently capture something the user was not looking at, which is the worst
    // failure available here, and `chooseFocalPost` had no way to detect it.
    //
    // `linklessCount` stays as the at-a-glance summary; the candidates carry the geometry.
    if (!postUrl) base.linklessCount += 1;
    const rect = rects[index];
    if (rect.bottom - rect.top <= 0) base.zeroRectCount += 1;
    const visibleTop = Math.max(rect.top, 0);
    const visibleBottom = Math.min(rect.bottom, base.viewport.height);
    base.candidates.push({
      index,
      postUrl,
      top: rect.top,
      bottom: rect.bottom,
      area: rect.width * rect.height,
      visibleArea: Math.max(0, visibleBottom - visibleTop) * rect.width,
    });
  }
  return base;
}

// ---------------------------------------------------------------------------
// The pure chooser (numbers in, one candidate out) — unit-tested.
// ---------------------------------------------------------------------------

/** The middle fraction of the viewport a post has to cover to be "the one on screen".
 * A BAND rather than the centre LINE: a line makes a post boundary landing on the centre
 * a coin flip and gives no way to say a decision was close, while a band scores every
 * candidate on a continuum — which is what lets T0 record a miss as a near-miss (096 § T0
 * requires misses to be adjacent, and `margin` is how that is judged). */
export const DEFAULT_BAND = 0.5;

/** Overlap in pixels of [aTop, aBottom] with [bTop, bBottom]; 0 when they merely touch. */
function overlap(aTop, aBottom, bTop, bBottom) {
  return Math.max(0, Math.min(aBottom, bBottom) - Math.max(aTop, bTop));
}

/**
 * The post the user means, from a `readPostCandidates()` reading.
 *
 * Returns `{ postUrl, index, basis, score, margin, runnerUp }` on a decision, or
 * `{ postUrl: null, reason }` when there is nothing to decide between. `basis` is
 * `"centre-band"` normally, or `"visible-area"` when the band fell in a GAP between
 * posts (a feed with spacing can do this) — reported rather than hidden, because a run of
 * `visible-area` decisions in T0's corpus means the band is mistuned, and that is a thing
 * to learn from the data rather than from a bug report.
 *
 * `insetTop`/`insetBottom` shrink the viewport before the band is computed — the sticky
 * header case. The READER does not try to detect a header (guessing at three SPAs' chrome
 * from a desk is exactly what this file refuses to do); the band is re-scorable offline
 * against T0's corpus with an inset, which is the cheaper way to find out whether one is
 * needed.
 *
 * Ties are broken explicitly and in a fixed order — greater visible area, then DOM order —
 * so the same reading always yields the same post. A coin flip here would be
 * unreproducible in exactly the corpus meant to make this reproducible.
 */
export function chooseFocalPost(reading, options = {}) {
  const { band = DEFAULT_BAND, insetTop = 0, insetBottom = 0 } = options;
  const candidates = (reading && reading.candidates) || [];
  if (!candidates.length) return { postUrl: null, reason: "no-candidates" };

  const height = (reading.viewport && reading.viewport.height) || 0;
  const viewTop = insetTop;
  const viewBottom = height - insetBottom;
  if (!(viewBottom > viewTop)) return { postUrl: null, reason: "no-viewport" };

  const centre = (viewTop + viewBottom) / 2;
  const halfBand = ((viewBottom - viewTop) * band) / 2;
  const bandTop = centre - halfBand;
  const bandBottom = centre + halfBand;

  const scored = candidates.map((candidate) => ({
    candidate,
    band: overlap(candidate.top, candidate.bottom, bandTop, bandBottom),
    visible: overlap(candidate.top, candidate.bottom, viewTop, viewBottom),
  }));

  // The band decides; visible area is the tie-break AND the fallback when the band is
  // empty. Both orderings end on `index` so the result is total.
  const byBand = (a, b) =>
    b.band - a.band || b.visible - a.visible || a.candidate.index - b.candidate.index;
  const byVisible = (a, b) =>
    b.visible - a.visible || a.candidate.index - b.candidate.index;

  const bandRanked = [...scored].sort(byBand);
  const basis = bandRanked[0].band > 0 ? "centre-band" : "visible-area";
  const ranked = basis === "centre-band" ? bandRanked : [...scored].sort(byVisible);
  const score = basis === "centre-band" ? ranked[0].band : ranked[0].visible;
  if (!(score > 0)) {
    // Nothing scored. Say WHICH nothing: a page that gave no geometry at all (every
    // candidate zero pixels tall — see `zeroRectCount`) is a reading to distrust, while
    // candidates with real height that simply sit off screen is an honest "scroll a bit".
    // A MIXTURE is the second case: some geometry existed, it just was not in view.
    const everyRectEmpty = candidates.every((c) => c.bottom - c.top <= 0);
    return { postUrl: null, reason: everyRectEmpty ? "no-geometry" : "none-visible" };
  }

  const next = ranked[1];
  const nextScore = next ? (basis === "centre-band" ? next.band : next.visible) : 0;

  // The thing in the middle of the screen has no permalink. This is NOT "nothing here" —
  // something is plainly there and the user is looking at it — so it gets its own answer,
  // richer than the flat refusals above, carrying what was found and the best capturable
  // thing near it. What the popup does with `alternative` is a product decision (offer it,
  // or say "nothing to save here"); reporting it is this function's job.
  if (!ranked[0].candidate.postUrl) {
    const alternative = ranked.find((entry) => entry.candidate.postUrl) || null;
    return {
      postUrl: null,
      reason: "uncapturable-focal",
      index: ranked[0].candidate.index,
      basis,
      score,
      margin: next ? score - nextScore : score,
      alternative: alternative
        ? {
          postUrl: alternative.candidate.postUrl,
          index: alternative.candidate.index,
          score: basis === "centre-band" ? alternative.band : alternative.visible,
        }
        : null,
    };
  }

  return {
    postUrl: ranked[0].candidate.postUrl,
    index: ranked[0].candidate.index,
    basis,
    score,
    // How close the call was, in the same units as `score`. T0's bar is that misses are
    // ADJACENT rather than wild; a miss with a small margin is a tuning problem and a miss
    // with a large one is a rule problem, and they want different fixes.
    margin: next ? score - nextScore : score,
    runnerUp: next
      ? { postUrl: next.candidate.postUrl, index: next.candidate.index, score: nextScore }
      : null,
  };
}
