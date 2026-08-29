// The live page-signal replay (096 review 12B).
//
// **What this exists to catch, and why the tests beside it cannot.**
// `extractors.test.js` and Swift's `PageExtractorTests` both run on HAND-COMPOSED
// harvests: an object with three metas and two images, trimmed to exercise one rule.
// That is the right shape for saying WHICH rule broke, and it is deliberately kept.
// What it cannot say is whether the rule still fires on a page x.com served today —
// the defect `fixtures/README.md` states plainly about Instagram, whose composed
// fixture carries 11–13 keys per media where the live API sends 108–128:
//
//   > Running the canary over it proved only that our own reduction still parsed.
//
// A live page is 100+ images, most of them avatars, card art and tracking pixels, in an
// order nobody composing a fixture would think to write down. `largestMedia`, the
// article-index scoping and the `name=orig` rewrites are all decisions taken against
// THAT, and none of them has ever been run against it.
//
// **The fixture is captured on a phone**, by the probe's "Dump signals" button (096 § T0,
// rider 5), keyed by page URL. Its `expected` block is the provenance the operator READ
// OFF THE SCREEN before pressing the button — the same epistemics as the focal-post tap.
// Recording the code's own answer unexamined would make this a snapshot test that defends
// whatever the extractor did on the day.
//
// **Each entry is a feed or a post (`pageKind`), and the difference is load-bearing.** On
// a feed, tier 3 hands the extractors a `linkUrl` naming which of forty posts was centred;
// Swift's `PageExtractor.capture(from:)` has no such parameter, because a share sheet has
// no right-clicked link to pass. This file replays BOTH kinds — the linkUrl is real on
// this side. `PageExtractorTests.swift` replays only the post pages, and says why.
//
// **`PageExtractorTests.swift` replays the same file**, which is the second reason it is
// raw rather than classified: `buildHarvest` and Swift's `PageHarvest.build(from:)` are
// the mirror `drift-check.js` guards for host tables, and this is that guard for page
// shape. A fixture stored post-classification would freeze one language's reading of the
// page into the file the other is checked against.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { buildHarvest } from "../src/harvest.js";
import { extractProvenance } from "../src/extractors/registry.js";

const FIXTURE = fileURLToPath(new URL("./fixtures/page-signals-live.json", import.meta.url));

/** The three platforms 096 § T0 covers. Same table and same `hostIs` semantics as
 * `focal-post.test.js`, so "which platforms are covered" means one thing in this repo
 * rather than two. */
const PLATFORMS = [
  { key: "x.com", domains: ["x.com", "twitter.com"] },
  { key: "instagram.com", domains: ["instagram.com"] },
  { key: "pinterest.com", domains: ["pinterest.com", "pinterest.co.uk"] },
];

function platformOf(host) {
  const lower = String(host || "").toLowerCase();
  const match = PLATFORMS.find((entry) =>
    entry.domains.some((domain) => lower === domain || lower.endsWith("." + domain)));
  return match ? match.key : `other:${lower || "unknown"}`;
}

/** The fields both languages compute. Anything outside this list is one side's extra,
 * and asserting it would report drift where nothing had drifted. */
const COMPARED = [
  "platform", "originalURL", "authorHandle", "authorName",
  "title", "mediaUrl", "mediaUrlFallback",
];

const readFixture = () => JSON.parse(readFileSync(FIXTURE, "utf8"));

const MISSING =
  "no live page-signal fixture yet — capture it during 096 § T0 with the probe's "
  + "\"Dump signals\" button (fixtures/page-signals-live.json)";

// The REGRESSION bar: runs against whatever has been captured, however little.
test("live signals: a real page still yields the provenance a human confirmed", (t) => {
  if (!existsSync(FIXTURE)) {
    // A SKIP with a sentence, not a silent pass — `drift-check.js`'s "⊘ NEVER VERIFIED"
    // is this repo's established way of saying a check has never seen its subject.
    t.skip(MISSING);
    return;
  }
  const bag = readFixture();
  const entries = Object.entries(bag);
  assert.ok(entries.length > 0, "fixture is a non-empty object keyed by page URL");

  const failures = [];
  for (const [pageUrl, entry] of entries) {
    assert.ok(entry && entry.raw, `${pageUrl}: entry carries a raw snapshot`);
    assert.ok(entry.expected, `${pageUrl}: entry carries a human-confirmed expectation`);

    const provenance = extractProvenance(
      buildHarvest(entry.raw), { linkUrl: entry.linkUrl || undefined });

    for (const field of COMPARED) {
      const got = provenance[field] ?? null;
      const want = entry.expected[field] ?? null;
      if (got !== want) failures.push({ page: pageUrl, field, want, got });
    }
  }
  assert.deepEqual(failures, [],
    `live page regressions: ${JSON.stringify(failures, null, 2)}`);
});

/** A page shape is not a sample of a distribution the way a focal-post pick is, so the
 * bar here is coverage rather than a count: a FEED and a POST per platform. Both, because
 * they are the two things tier 3 and tier 2 respectively see, and one standing in for the
 * other is how a gate ends up defending a page nobody's code path visits. */
test("live signals: a feed and a post captured per platform", (t) => {
  if (!existsSync(FIXTURE)) {
    t.skip(MISSING);
    return;
  }
  const covered = new Set();
  for (const entry of Object.values(readFixture())) {
    covered.add(`${platformOf(entry.host)}·${entry.pageKind}`);
  }
  const has = (key, kind) => covered.has(`${key}·${kind}`);
  const line = PLATFORMS.map((entry) =>
    `${entry.key} ${has(entry.key, "feed") ? "feed" : "—"}/${has(entry.key, "post") ? "post" : "—"}`
  ).join("  ");
  const short = PLATFORMS.filter((entry) =>
    !has(entry.key, "feed") || !has(entry.key, "post"));

  // The tally prints on every run for the same reason `focal-post.test.js`'s does: the
  // count is what makes "we have one of three" impossible to mistake for green.
  console.log(`  live page coverage: ${line}`);
  if (short.length) {
    t.skip(
      `not yet a gate — ${line}. 096 § T0 rider 5 asks for a feed AND a post per platform; `
      + `still short on ${short.map((entry) => entry.key).join(", ")}.`);
    return;
  }
  assert.ok(true);
});
