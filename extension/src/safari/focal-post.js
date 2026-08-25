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
 *     containerCount, linklessCount
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
      containers: ["article", '[role="presentation"] > div > div'],
      link: 'a[href^="/p/"], a[href^="/reel/"]',
    },
    {
      hosts: ["pinterest.com", "pinterest.co.uk"],
      containers: ['[data-test-id="pin"]', '[data-test-id="pinWrapper"]', "[data-grid-item]"],
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
    if (!postUrl) {
      // A container with no permalink cannot be captured, so it is not a candidate —
      // but it is COUNTED, because "the selector matched 20 things and 20 had no link"
      // and "the selector matched nothing" are different failures and T0 must tell them
      // apart.
      base.linklessCount += 1;
      continue;
    }
    const rect = rects[index];
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
  if (!(score > 0)) return { postUrl: null, reason: "none-visible" };

  const next = ranked[1];
  const nextScore = next ? (basis === "centre-band" ? next.band : next.visible) : 0;
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
