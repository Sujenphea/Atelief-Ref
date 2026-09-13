// Atelier Capture — the opt-in drift canary CLI (Phase 8, [T12][12A]).
//
// The CAPTURE checks below are opt-in and run OUTSIDE CI (they need a real, freshly-
// captured response — which needs your logged-in session). Run them periodically, or when
// a live sweep suddenly yields nothing:
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
//
// The PRODUCER-CONTRACT check is the exception and needs no capture at all: it compares
// this extension's host tables against the iOS share sheet's, both of which are files in
// this repo. It therefore runs unconditionally, including in CI, and is the reason this
// script is a gate and not only a canary (review issue 4 — see src/host-table.js for the
// invariant and the asymmetry it permits).

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CHECKS, fixtureStaleReminder } from "../src/drift.js";
import { checkHostTableAgreement } from "../src/host-table.js";

// The committed capture each check falls back to. A check with NO entry here has no
// committed fixture yet and can only run against a `--flag <path>` live capture — it is
// reported as AWAITING that capture rather than quietly passing, which is the whole point
// (a check nobody has ever run against a real response proves nothing). See [090] 1A.
// `x`, `instagram` and the two `pinterest-*` entries point at LIVE captures, not at the
// hand-composed fixtures the unit tests pin against. The two kinds answer different
// questions and had been answering only one: the composed ones are trimmed to exercise
// specific mapper rules (quote-merge, a bare quote, a text-only tweet) and their
// synthetic ids are asserted literally, so re-capturing them means rewriting those
// assertions — which is exactly why they went 41 days without being refreshed. The
// canary's question is "does a response the platform sent TODAY still parse", so each
// gets its own fixture on its own clock, replaceable wholesale without touching a test.
// The composed fixtures are still exercised by the checks in drift.test.js.
//
// Instagram's composed fixture was the starkest case: it carries 11-13 keys per media
// where the live API sends 108-128, so running the canary over it proved only that our
// own reduction still parsed.
const FIXTURE = {
  x: "../test/fixtures/x-bookmarks-live.json",
  "pinterest-board": "../test/fixtures/pinterest-boardfeed-live.json",
  "pinterest-boards": "../test/fixtures/pinterest-boards-live.json",
  instagram: "../test/fixtures/instagram-saved-live.json",
  "x-thread": "../test/fixtures/x-thread-detail.json",
};

/** How to obtain the capture a fixture-less check needs, printed where it's actionable.
 * The mechanism exists so a newly added parser starts life VISIBLY unverified rather than
 * passing silently — which is exactly rednote's state until 098 T4 sanitizes the live
 * capture into a committed fixture. */
const CAPTURE_HINT = {
  rednote:
    "Open a rednote board logged in, DevTools > Network > Fetch/XHR, scroll to load a\n"
    + "    second batch, and save the `/api/sns/web/v1/board/note` response. Then:\n"
    + "    node scripts/sanitize-capture.js <raw.json> test/fixtures/rednote-board-live.json",
};
const here = (rel) => fileURLToPath(new URL(rel, import.meta.url));

// The two producers' host tables. Resolved relative to THIS SCRIPT rather than to the
// cwd, so `working-directory: extension` in CI and a run from the repo root both find the
// same files. The Swift path leaves the extension directory, which is fine: the workflow
// checks out the whole repo, and the Swift package is a sibling of `extension/`.
const SWIFT_HOST_TABLE = "../../AtelierCapture/Sources/AtelierCapture/ShareCapture.swift";
const EXTRACTORS_DIR = "../src/extractors";
const MEDIA_HOSTS = "../src/media-hosts.js";

/** Read both producers' sources for the host-table check. A missing file THROWS rather
 * than degrading to a skip: "the Swift package isn't here" and "the tables agree" must
 * not print the same thing, which is the failure this whole check exists to prevent. */
function readHostTableSources() {
  const dir = here(EXTRACTORS_DIR);
  return {
    swift: readFileSync(here(SWIFT_HOST_TABLE), "utf8"),
    mediaHosts: readFileSync(here(MEDIA_HOSTS), "utf8"),
    extractors: readdirSync(dir)
      .filter((filename) => filename.endsWith(".js"))
      .sort()
      .map((filename) => ({ filename, source: readFileSync(`${dir}/${filename}`, "utf8") })),
  };
}

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
  // Clamped at 0: `capturedAt` is a bare YYYY-MM-DD, which parses as UTC midnight, while
  // a capture taken today from a UTC+12 machine is stamped with a local date that UTC has
  // not reached yet. Unclamped, a fixture captured minutes ago reports "-1d ago".
  return Math.max(0, Math.floor((Date.now() - then) / 86_400_000));
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const baseline = JSON.parse(readFileSync(here("../test/fixtures/drift-baseline.json")));

  console.log("Atelier drift canary\n====================");
  // The top-level date is DESCRIPTIVE — the day the composed fixtures were first built —
  // and deliberately does NOT set the exit code. Those fixtures are trimmed by hand and
  // pinned literally by the unit tests; they are never re-captured on purpose, so a
  // staleness window over them could only ever be a permanently red gate with no action
  // behind it. Freshness is a per-fixture property now, and every fixture the canary
  // actually runs carries its own `capturedAt` + window below.
  console.log(`Composed fixtures authored ${baseline.capturedAt}`
    + ` (${ageInDays(baseline.capturedAt)}d ago — not a staleness signal)`);
  // A platform whose fixture was captured on its OWN day carries its own date and
  // window (IG drifts faster than X/Pinterest, 12A — 14d vs 30d). Reported generically
  // rather than per-platform: `xThread` already had a date that nothing printed and
  // nothing enforced, so it could have rotted silently, which is the one failure mode
  // this whole file exists to prevent. Any dated marker now sets the exit code — and an
  // UNDATED marker is reported too, because "no date" used to mean "inherits the
  // top-level date" and now means nothing at all.
  const igMarker = baseline.markers.instagram;
  let markerStale = false;
  for (const [name, marker] of Object.entries(baseline.markers)) {
    if (!marker) continue;
    if (!marker.capturedAt) { console.log(`${name} marker carries no capture date`); continue; }
    const markerReminder = fixtureStaleReminder(marker);
    if (markerReminder) markerStale = true;
    console.log(`${name} fixture captured ${marker.capturedAt} (${ageInDays(marker.capturedAt)}d ago,`
      + ` ${marker.staleAfterDays}d window)` + (markerReminder ? `  ⚠️  STALE` : ""));
    if (markerReminder) console.log(`  ${markerReminder}`);
  }
  console.log(`Drift markers to re-verify live:`);
  console.log(`  X app queryId (Likes ${baseline.markers.x.likesQueryId}) — rotates ~2-4 weeks`);
  console.log(`  Pinterest X-APP-VERSION (${baseline.markers.pinterest.appVersion}) — required`);
  if (igMarker) console.log(`  Instagram saved-feed route (${igMarker.route}) + next_max_id pagination`);
  console.log(`  X harvest DOM (harvest.js): focal <article> scoping + pbs.twimg.com/media/`);
  console.log(`    photos — single-capture media[] collection relies on these`);
  // 026 · 9A asked for the quoted-exclusion selector to live on this list, because it is
  // the one part of that rule no fixture can check: it is a DOM read and this suite has
  // no jsdom. 099 · P11 shipped the rule, so here it is.
  console.log(`  X photo anchor (harvest.js): a photo's <a href="/{handle}/status/{id}/photo/{n}">`);
  console.log(`    — the per-photo statusId that excludes a QUOTED tweet's photo (099 · P11).`);
  console.log(`    No fixture can check it: right-click a quoted photo and read the linkUrl.\n`);

  let failed = false;
  const awaiting = [];

  // First, and always: the one check that needs no capture. Reported in the same
  // ✔/✘ + signals form as the capture checks so there is a single reading of this output.
  const hostLabel = "Producer host tables (extension ↔ iOS share sheet)";
  let hostTable;
  try {
    hostTable = checkHostTableAgreement(readHostTableSources());
  } catch (error) {
    hostTable = { ok: false, problems: [`could not read a host table: ${error.message}`],
      signals: {}, swiftOnly: [] };
  }
  const hostSignals = Object.entries(hostTable.signals).map(([k, v]) => `${k}=${v}`).join(" ");
  if (hostTable.ok) {
    console.log(`✔ ${hostLabel} (repo sources) — ${hostSignals}`);
  } else {
    failed = true;
    console.log(`✘ ${hostLabel} (repo sources) — DRIFT:`);
    for (const problem of hostTable.problems) console.log(`    · ${problem}`);
  }
  // Printed pass or fail. A host only the phone can ever see is legitimate (`t.co` is
  // resolved by the browser long before a content script runs), but a NEW one should be
  // visible to whoever reads this output rather than absorbed silently.
  // Parenthesised and unbulleted so it never reads as one more problem in a DRIFT block.
  if (hostTable.swiftOnly && hostTable.swiftOnly.length) {
    console.log(`    (phone-only, no extractor can observe these: ${hostTable.swiftOnly.join(", ")})`);
  }
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

  // The remediation names both kinds now that a source-vs-source check shares this line:
  // re-capturing a fixture is no help at all against two host tables that disagree.
  console.log(failed ? "\nDrift detected — update the parsers + re-capture fixtures,"
    + " or reconcile the host tables."
    : "\nNo drift — every check that COULD run satisfied its invariants.");
  if (awaiting.length) {
    // Not a failure — there is nothing to fail against. Said plainly so "no drift" is
    // never mistaken for "verified": these parsers have only ever seen invented input.
    console.log(`\n⊘ Awaiting a live capture: ${awaiting.join(", ")}.`);
    console.log("  Until then, treat that parser as UNVERIFIED against production.");
  }
  const stale = markerStale;
  if (stale && !failed) {
    console.log("\nReminder: a fixture is past its staleAfterDays — re-capture before relying on live sweeps.");
  }
  // TWO ARMS, TWO EXIT CODES. They used to share `1`, and that cost the repo a
  // gate: a fixture aged past its window on 2026-08-28 and every `verify.sh full`
  // from then on was red while printing "No drift — every check that COULD run
  // satisfied its invariants" one line above. Nobody saw it, because `fast` mode
  // does not run this stage at all.
  //
  //   1 — DRIFT. A parser disagrees with a committed fixture, or the two host
  //       tables disagree. A code change fixes it. Always a hard failure.
  //   2 — STALE. A fixture is past its `staleAfterDays`. Only a fresh live
  //       capture from a logged-in session clears it, so no automated run can,
  //       and a gate that can only rot is not a gate. Reported, never fatal.
  //
  // Drift wins when both are true: the actionable signal is the one to surface.
  process.exit(failed ? 1 : stale ? 2 : 0);
}

main();
