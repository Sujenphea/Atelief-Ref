// Atelier Capture — the opt-in drift canary CLI (Phase 8, [T12][12A]).
//
// OUTSIDE CI (it needs a real, freshly-captured response — which needs your logged-in
// session). Run it periodically, or when a live sweep suddenly yields nothing:
//
//   node scripts/drift-check.js                       # check the committed fixtures
//   node scripts/drift-check.js --x ../resources/live-bookmarks.json
//   node scripts/drift-check.js --pinterest-board ../resources/live-boardfeed.json
//
// With no path for a platform it falls back to that platform's committed fixture (a
// sanity check that the PARSERS still satisfy their own invariants). Pass a fresh
// capture (saved via DevTools into the gitignored resources/) to check it against the
// LIVE shape. Exits non-zero on any drift, so it doubles as a manual gate. The
// invariant logic lives in src/drift.js (unit-tested); this is just file loading, the
// capture-age warning, and reporting.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CHECKS, fixtureStaleReminder } from "../src/drift.js";

// The committed capture each check falls back to. A check with NO entry here has no
// committed fixture yet and can only run against a `--flag <path>` live capture — it is
// reported as AWAITING that capture rather than quietly passing, which is the whole point
// (a check nobody has ever run against a real response proves nothing). See [090] 1A.
const FIXTURE = {
  x: "../test/fixtures/x-bookmarks.json",
  "pinterest-board": "../test/fixtures/pinterest-boardfeed.json",
  "pinterest-boards": "../test/fixtures/pinterest-boards.json",
  instagram: "../test/fixtures/instagram-saved.json",
  "x-thread": "../test/fixtures/x-thread-detail.json",
};

/** How to obtain the capture a fixture-less check needs, printed where it's actionable.
 * Empty today — every check has a committed fixture — but the mechanism stays: the next
 * parser added here starts life unverified, and should say so rather than pass silently. */
const CAPTURE_HINT = {};
const here = (rel) => fileURLToPath(new URL(rel, import.meta.url));

/** Parse `--flag value` pairs into `{ flag: path }`. */
function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i].startsWith("--")) { args[argv[i].slice(2)] = argv[i + 1]; i += 1; }
  }
  return args;
}

/** Days between two YYYY-MM-DD-ish dates (Date is fine here — this is a CLI, not a
 * Workflow script, and the pure checks it calls are Date-free). */
function ageInDays(capturedAt) {
  const then = new Date(capturedAt).getTime();
  return Math.floor((Date.now() - then) / 86_400_000);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const baseline = JSON.parse(readFileSync(here("../test/fixtures/drift-baseline.json")));

  console.log("Atelier drift canary\n====================");
  const age = ageInDays(baseline.capturedAt);
  const reminder = fixtureStaleReminder(baseline);
  console.log(`Fixtures captured ${baseline.capturedAt} (${age}d ago)`
    + (reminder ? `  ⚠️  STALE` : ""));
  if (reminder) console.log(`  ${reminder}`);
  // Instagram carries its OWN capture date + a shorter stale window (14d — IG drifts
  // faster than X/Pinterest, 12A), read from its per-platform marker.
  const igMarker = baseline.markers.instagram;
  const igReminder = igMarker ? fixtureStaleReminder(igMarker) : null;
  if (igMarker) {
    console.log(`Instagram fixture captured ${igMarker.capturedAt} (${ageInDays(igMarker.capturedAt)}d ago,`
      + ` ${igMarker.staleAfterDays}d window)` + (igReminder ? `  ⚠️  STALE` : ""));
    if (igReminder) console.log(`  ${igReminder}`);
  }
  console.log(`Drift markers to re-verify live:`);
  console.log(`  X app queryId (Likes ${baseline.markers.x.likesQueryId}) — rotates ~2-4 weeks`);
  console.log(`  Pinterest X-APP-VERSION (${baseline.markers.pinterest.appVersion}) — required`);
  if (igMarker) console.log(`  Instagram saved-feed route (${igMarker.route}) + next_max_id pagination`);
  console.log(`  X harvest DOM (harvest.js): focal <article> scoping + pbs.twimg.com/media/`);
  console.log(`    photos — single-capture media[] collection relies on these\n`);

  let failed = false;
  const awaiting = [];
  for (const [flag, { label, run }] of Object.entries(CHECKS)) {
    if (!args[flag] && !FIXTURE[flag]) {
      console.log(`⊘ ${label} — NEVER VERIFIED against a real response`);
      console.log(`    ${CAPTURE_HINT[flag] || `pass --${flag} <live capture>`}`);
      awaiting.push(label);
      continue;
    }
    const path = args[flag] ? args[flag] : here(FIXTURE[flag]);
    const source = args[flag] ? `live: ${args[flag]}` : "committed fixture";
    let json;
    try {
      json = JSON.parse(readFileSync(path));
    } catch (error) {
      console.log(`✘ ${label} — could not read ${path}: ${error.message}`);
      failed = true;
      continue;
    }
    const result = run(json);
    const signals = Object.entries(result.signals).map(([k, v]) => `${k}=${v}`).join(" ");
    if (result.ok) {
      console.log(`✔ ${label} (${source}) — ${signals}`);
    } else {
      failed = true;
      console.log(`✘ ${label} (${source}) — DRIFT:`);
      for (const problem of result.problems) console.log(`    · ${problem}`);
    }
  }

  console.log(failed ? "\nDrift detected — update the parsers + re-capture fixtures."
    : "\nNo drift — every check that COULD run satisfied its invariants.");
  if (awaiting.length) {
    // Not a failure — there is nothing to fail against. Said plainly so "no drift" is
    // never mistaken for "verified": these parsers have only ever seen invented input.
    console.log(`\n⊘ Awaiting a live capture: ${awaiting.join(", ")}.`);
    console.log("  Until then, treat that parser as UNVERIFIED against production.");
  }
  const stale = reminder || igReminder;
  if (stale && !failed) {
    console.log("\nReminder: a fixture is past its staleAfterDays — re-capture before relying on live sweeps.");
  }
  process.exit(failed || stale ? 1 : 0);
}

main();
