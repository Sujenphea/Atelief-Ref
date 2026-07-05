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
import { CHECKS } from "../src/drift.js";

const FIXTURE = {
  x: "../test/fixtures/x-bookmarks.json",
  "pinterest-board": "../test/fixtures/pinterest-boardfeed.json",
  "pinterest-boards": "../test/fixtures/pinterest-boards.json",
};
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
  const stale = age > baseline.staleAfterDays;
  console.log(`Fixtures captured ${baseline.capturedAt} (${age}d ago)`
    + (stale ? `  ⚠️  STALE (> ${baseline.staleAfterDays}d) — re-capture live responses.` : ""));
  console.log(`Drift markers to re-verify live:`);
  console.log(`  X app queryId (Likes ${baseline.markers.x.likesQueryId}) — rotates ~2-4 weeks`);
  console.log(`  Pinterest X-APP-VERSION (${baseline.markers.pinterest.appVersion}) — required\n`);

  let failed = false;
  for (const [flag, { label, run }] of Object.entries(CHECKS)) {
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
    : "\nNo drift — every check satisfied its invariants.");
  process.exit(failed || stale ? 1 : 0);
}

main();
