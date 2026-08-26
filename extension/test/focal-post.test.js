// Atelier Capture — chooseFocalPost tests (096 § T0/T3, decision 10A).
//
// `chooseFocalPost` takes NUMBERS, not a DOM — the split `harvest.js` actually makes
// (`harvest.test.js` builds raw snapshots with a helper and never touches a DOM). So the
// rules are asserted here with plain objects and no stub: no jsdom, no `vm`, matching this
// suite's zero-dependency rule.
//
// The page half (`readPostCandidates`) stays untested for the reason `harvestSignals` is:
// it is a branchless DOM read that is serialized into a page, and the only thing that can
// tell us whether its SELECTORS are right is a real phone — which is what 096 § T0 spends
// its day on, and why the reading carries `matchedSelector`.
//
// The corpus T0 captures replays through these same functions (096 § T0's second bar:
// 100% of the captured corpus, in CI, from T3 onward). `replayCorpus` below is that
// harness; it is a no-op until the fixtures land, and says so rather than passing quietly.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { chooseFocalPost, DEFAULT_BAND } from "../src/safari/focal-post.js";

/** A reading with sensible defaults — a 800px-tall phone viewport. */
function reading(candidates, over = {}) {
  return {
    url: "https://x.com/home",
    host: "x.com",
    matchedSelector: "article",
    viewport: { height: 800, width: 390 },
    candidates,
    containerCount: candidates.length,
    linklessCount: 0,
    ...over,
  };
}

/** A candidate spanning [top, bottom], 390 wide. */
function post(index, top, bottom, over = {}) {
  const width = 390;
  const visibleTop = Math.max(top, 0);
  const visibleBottom = Math.min(bottom, 800);
  return {
    index,
    postUrl: `https://x.com/a/status/${index}`,
    top,
    bottom,
    area: (bottom - top) * width,
    visibleArea: Math.max(0, visibleBottom - visibleTop) * width,
    ...over,
  };
}

// ---------------------------------------------------------------------------
// The ordinary case
// ---------------------------------------------------------------------------

test("the post covering the viewport centre wins", () => {
  // Band for an 800px viewport at 0.5 is [200, 600].
  const result = chooseFocalPost(reading([
    post(0, -500, 150),  // above the band
    post(1, 150, 700),   // covers [200, 600] entirely
    post(2, 700, 1200),  // below the band
  ]));
  assert.equal(result.postUrl, "https://x.com/a/status/1");
  assert.equal(result.index, 1);
  assert.equal(result.basis, "centre-band");
  assert.equal(result.score, 400);
});

test("the runner-up and margin are reported, so a miss can be judged near or wild", () => {
  const result = chooseFocalPost(reading([
    post(0, 0, 450),   // covers [200, 450] = 250
    post(1, 450, 900), // covers [450, 600] = 150
  ]));
  assert.equal(result.index, 0);
  assert.equal(result.score, 250);
  assert.equal(result.margin, 100);
  assert.deepEqual(result.runnerUp, {
    postUrl: "https://x.com/a/status/1", index: 1, score: 150,
  });
});

test("a lone candidate reports margin as its whole score and no runner-up", () => {
  const result = chooseFocalPost(reading([post(0, 100, 700)]));
  assert.equal(result.index, 0);
  assert.equal(result.runnerUp, null);
  assert.equal(result.margin, result.score);
});

// ---------------------------------------------------------------------------
// The edge cases 096 § T3 names
// ---------------------------------------------------------------------------

test("a post taller than the viewport covers the whole band and wins", () => {
  const result = chooseFocalPost(reading([
    post(0, -2000, 2000), // covers the band completely
    post(1, 550, 620),    // a sliver inside it
  ]));
  assert.equal(result.index, 0);
  assert.equal(result.score, 400);
});

test("two posts split exactly at the centre tie on band, then break on visible area", () => {
  // Both cover exactly 200px of the band. Post 1 is more visible overall.
  const result = chooseFocalPost(reading([
    post(0, 300, 400),  // band overlap [300,400] = 100, visible 100
    post(1, 400, 800),  // band overlap [400,600] = 200, visible 400
  ]));
  assert.equal(result.index, 1);

  // A genuine tie on BOTH falls to DOM order, and is stable.
  const tied = chooseFocalPost(reading([
    post(0, 200, 400),
    post(1, 400, 600),
  ]));
  assert.equal(tied.index, 0);
  assert.equal(tied.margin, 0, "a dead tie reports zero margin — the caller can see it was one");
  assert.equal(chooseFocalPost(reading([post(0, 200, 400), post(1, 400, 600)])).index, 0);
});

test("a sticky header is handled by insetTop, not by the reader guessing", () => {
  // Without an inset the band is [200,600] and post 0 wins on overlap.
  const plain = chooseFocalPost(reading([
    post(0, 0, 420),
    post(1, 420, 800),
  ]));
  assert.equal(plain.index, 0);

  // With a 200px header the usable viewport is [200,800], band [350,650],
  // so post 1 (overlap 230) beats post 0 (overlap 70).
  const inset = chooseFocalPost(
    reading([post(0, 0, 420), post(1, 420, 800)]),
    { insetTop: 200 },
  );
  assert.equal(inset.index, 1);
});

test("a band falling in a GAP between posts falls back to visible area, and says so", () => {
  // Band [200,600] lands entirely in the gap between the two posts.
  const result = chooseFocalPost(reading([
    post(0, -400, 190),  // visible 190
    post(1, 610, 1400),  // visible 190
    post(2, 620, 900),   // visible 180
  ]));
  assert.equal(result.basis, "visible-area");
  assert.equal(result.index, 0, "ties on visible area fall to DOM order");
  assert.ok(result.score > 0);
});

test("no candidates at all is a reason, not a pick", () => {
  const result = chooseFocalPost(reading([]));
  assert.deepEqual(result, { postUrl: null, reason: "no-candidates" });
});

test("candidates entirely off-screen are refused rather than guessed at", () => {
  const result = chooseFocalPost(reading([
    post(0, -900, -100),
    post(1, 900, 1600),
  ]));
  assert.deepEqual(result, { postUrl: null, reason: "none-visible" });
});

test("every candidate measuring zero tall is no-geometry, not none-visible", () => {
  // Observed live on instagram.com and pinterest.com: the selector matched, the permalinks
  // were there, every rect was 0. That is a reading to distrust, not a "scroll a bit".
  const result = chooseFocalPost(reading([
    post(0, 300, 300),
    post(1, 300, 300),
  ]));
  assert.deepEqual(result, { postUrl: null, reason: "no-geometry" });
});

test("a MIXTURE of zero-height and merely off-screen is none-visible", () => {
  // Some geometry existed; it just was not in view. Different diagnosis, different fix.
  const result = chooseFocalPost(reading([
    post(0, 300, 300),    // no geometry
    post(1, 900, 1600),   // real height, below the fold
  ]));
  assert.deepEqual(result, { postUrl: null, reason: "none-visible" });
});

test("a zero-height viewport is refused (no band can exist)", () => {
  const result = chooseFocalPost(reading([post(0, 0, 100)], { viewport: { height: 0, width: 390 } }));
  assert.deepEqual(result, { postUrl: null, reason: "no-viewport" });
});

test("insets that swallow the viewport are refused, not inverted", () => {
  const result = chooseFocalPost(reading([post(0, 0, 800)]), { insetTop: 500, insetBottom: 500 });
  assert.deepEqual(result, { postUrl: null, reason: "no-viewport" });
});

test("a candidate merely TOUCHING the band edge does not count as overlapping", () => {
  // Band is [200, 600]; post 0 ends exactly at 200, post 1 starts exactly at 600.
  const result = chooseFocalPost(reading([
    post(0, 0, 200),
    post(1, 600, 800),
  ]));
  assert.equal(result.basis, "visible-area", "zero-length overlap is not overlap");
});

test("a scrolled-past post with a negative top is clipped, not counted at full height", () => {
  const result = chooseFocalPost(reading([
    post(0, -10_000, 250),  // enormous, but only [200,250] is in the band
    post(1, 250, 800),      // [250,600] = 350
  ]));
  assert.equal(result.index, 1);
  assert.equal(result.score, 350);
});

// ---------------------------------------------------------------------------
// Uncapturable focal items (issue 22A) — ~25% of a real feed has no permalink
// ---------------------------------------------------------------------------

/** A container with no permalink: an ad, a promoted pin, a suggested-user card. */
const ad = (index, top, bottom) => post(index, top, bottom, { postUrl: null });

test("an AD in the centre is reported, not silently replaced by its neighbour", () => {
  // The failure this closes: the ad was invisible to the chooser, so the geometric winner
  // became a neighbouring post and the popup captured something else.
  const result = chooseFocalPost(reading([
    post(0, -400, 150),
    ad(1, 150, 700),        // covers the whole band
    post(2, 700, 1200),
  ]));
  assert.equal(result.postUrl, null);
  assert.equal(result.reason, "uncapturable-focal");
  assert.equal(result.index, 1, "it names WHICH container was in the way");
});

test("the best capturable thing nearby is offered as an alternative", () => {
  const result = chooseFocalPost(reading([
    ad(0, 150, 700),        // band overlap 400 — wins
    post(1, 700, 900),      // visible, capturable
  ]));
  assert.equal(result.reason, "uncapturable-focal");
  assert.deepEqual(result.alternative, {
    postUrl: "https://x.com/a/status/1", index: 1, score: 0,
  });
});

test("an ad that is NOT central loses to a real post, as it always did", () => {
  const result = chooseFocalPost(reading([
    ad(0, 0, 210),          // barely clips the band
    post(1, 210, 800),      // covers most of it
  ]));
  assert.equal(result.postUrl, "https://x.com/a/status/1");
  assert.equal(result.reason, undefined);
});

test("a feed of nothing BUT ads reports uncapturable, with no alternative", () => {
  const result = chooseFocalPost(reading([ad(0, 100, 400), ad(1, 400, 700)]));
  assert.equal(result.reason, "uncapturable-focal");
  assert.equal(result.alternative, null);
});

test("ads still do not count as candidates for the empty cases", () => {
  // No containers at all remains distinct from containers that cannot be captured.
  assert.deepEqual(chooseFocalPost(reading([])), { postUrl: null, reason: "no-candidates" });
  // An off-screen ad is none-visible, not uncapturable — nothing was in the middle at all.
  assert.deepEqual(
    chooseFocalPost(reading([ad(0, 900, 1600)])),
    { postUrl: null, reason: "none-visible" },
  );
});

// ---------------------------------------------------------------------------
// The band is a knob, so the corpus can be re-scored offline
// ---------------------------------------------------------------------------

test("the band width changes the decision, which is why the corpus is kept", () => {
  const candidates = [post(0, 0, 300), post(1, 300, 800)];
  // Band 0.5 → [200,600]: post 0 gets 100, post 1 gets 300.
  assert.equal(chooseFocalPost(reading(candidates)).index, 1);
  // Band 0.1 → [360,440]: post 0 gets 0, post 1 gets 80. Still post 1, more decisively.
  assert.equal(chooseFocalPost(reading(candidates), { band: 0.1 }).index, 1);
  // Band 1.0 → [0,800]: post 0 gets 300, post 1 gets 500.
  assert.equal(chooseFocalPost(reading(candidates), { band: 1 }).index, 1);
});

test("DEFAULT_BAND is the documented default", () => {
  const candidates = [post(0, 0, 300), post(1, 300, 800)];
  assert.deepEqual(
    chooseFocalPost(reading(candidates)),
    chooseFocalPost(reading(candidates), { band: DEFAULT_BAND }),
  );
});

// ---------------------------------------------------------------------------
// The T0 corpus replay (096 § T0's second bar)
// ---------------------------------------------------------------------------

const CORPUS = fileURLToPath(new URL("./fixtures/focal-post-observations.json", import.meta.url));

test("T0 corpus: every observation still picks the post a human confirmed", (t) => {
  if (!existsSync(CORPUS)) {
    // Deliberately a SKIP with a sentence, not a silent pass. A corpus check that has
    // never seen an observation proves nothing, and drift-check.js:  "⊘ NEVER VERIFIED"
    // is this repo's established way of saying so out loud.
    t.skip("no T0 corpus yet — capture it during 096 § T0 (fixtures/focal-post-observations.json)");
    return;
  }
  const observations = JSON.parse(readFileSync(CORPUS, "utf8"));
  assert.ok(Array.isArray(observations) && observations.length > 0, "corpus is a non-empty array");

  const misses = [];
  for (const observation of observations) {
    const result = chooseFocalPost(observation.reading, observation.options || {});
    if (result.postUrl !== observation.expectedPostUrl) {
      misses.push({
        platform: observation.reading.host,
        expected: observation.expectedPostUrl,
        got: result.postUrl,
        basis: result.basis,
        margin: result.margin,
      });
    }
  }
  assert.deepEqual(misses, [], `corpus regressions: ${JSON.stringify(misses, null, 2)}`);
});
