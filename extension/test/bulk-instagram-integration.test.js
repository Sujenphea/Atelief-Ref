// Atelier Capture — Instagram end-to-end integration: fixtures → driver → engine (002 · O2, [9A][11A]).
//
// The parser (bulk-instagram.js) and the sweep engine (bulk-engine.js) are unit-tested in
// isolation; these exercise them TOGETHER through the O2 PULL driver — a scripted
// `fetchJson` stands in for the credentialled saved-feed fetch, the driver paginates by
// `next_max_id`, `runSweep` pulls its items, and a recording relay stands in for the SW.
// Pins: multi-page pagination + fan-out end-to-end, the cursor is threaded into the next
// request, and the account-safety property (11A) — a challenge / non-200 mid-sweep halts
// RESUMABLE with the checkpoint preserved.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { instagramSavedDriver, parseSavedFeedPage } from "../src/bulk-instagram.js";
import { runSweep, OUTCOMES } from "../src/bulk-engine.js";

const page1 = JSON.parse(readFileSync(new URL("./fixtures/instagram-saved.json", import.meta.url)));       // 3 posts
const page2 = JSON.parse(readFileSync(new URL("./fixtures/instagram-saved-page2.json", import.meta.url))); // 11 posts

/** Fanned-out item count for a raw page (image/reel → 1, carousel → child count). */
const fanout = (page) => parseSavedFeedPage(page).items.length;

const engineOpts = {
  sleep: () => Promise.resolve(), random: () => 0,
  config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
};

function recordingRelay() {
  const ingested = [];
  return { ingested, relay: async (item) => { ingested.push(item.sourceId); return { outcome: OUTCOMES.ingested }; } };
}

/** A scripted `fetchJson`: serves `responses` in order and records every requested URL. */
function scriptedFetch(responses) {
  const urls = [];
  let i = 0;
  const fetchJson = async (url) => {
    urls.push(url);
    const r = responses[Math.min(i, responses.length - 1)];
    i += 1;
    return r;
  };
  return { fetchJson, urls };
}

test("IG integration: the driver paginates two pages and ingests every fanned-out media", async () => {
  // Page 1 (the 11-post fixture) carries more_available + a cursor → the driver continues to
  // page 2 (the 3-post fixture, terminal). Total = both pages' fan-out, all distinct pks.
  const midPage = { ...page2, more_available: true, next_max_id: "CURSOR2" };
  const { fetchJson, urls } = scriptedFetch([
    { httpStatus: 200, json: midPage },
    { httpStatus: 200, json: page1 },   // terminal (more_available:false)
  ]);
  const driver = instagramSavedDriver({ fetchJson, host: "www.instagram.com" });

  const { ingested, relay } = recordingRelay();
  const result = await runSweep(driver, {}, { ...engineOpts, relay });

  const expected = fanout(page2) + fanout(page1);
  assert.equal(result.status, "complete");
  assert.equal(ingested.length, expected);
  assert.equal(new Set(ingested).size, expected, "every fanned-out media is a distinct per-media pk");

  // The cursor was threaded: page 1 requested without max_id, page 2 with max_id=CURSOR2.
  assert.equal(urls.length, 2);
  assert.ok(!urls[0].includes("max_id"), "first page requested without a cursor");
  assert.match(urls[1], /max_id=CURSOR2/);
});

test("IG integration: a single terminal page completes cleanly (no phantom next request)", async () => {
  const { fetchJson, urls } = scriptedFetch([{ httpStatus: 200, json: page1 }]);
  const { ingested, relay } = recordingRelay();
  const result = await runSweep(instagramSavedDriver({ fetchJson }), {}, { ...engineOpts, relay });

  assert.equal(result.status, "complete");
  assert.equal(ingested.length, fanout(page1));
  assert.equal(urls.length, 1, "more_available:false → no second request");
});

test("IG integration: a challenge mid-sweep HALTS resumable, checkpoint preserved (11A)", async () => {
  // Page 1 ingests (with a cursor to continue); page 2 is a checkpoint_required body. The
  // driver throws → the engine halts RESUMABLE, keeping the checkpoint, never falsely
  // completing a half-swept feed.
  const midPage = { ...page1, more_available: true, next_max_id: "CURSOR2" };
  const { fetchJson } = scriptedFetch([
    { httpStatus: 200, json: midPage },
    { httpStatus: 400, json: { message: "checkpoint_required", status: "fail" } },
  ]);
  const store = new Map();
  const storage = { load: async (k) => store.get(k) ?? null, save: async (k, v) => { store.set(k, v); }, remove: async (k) => { store.delete(k); } };
  const { ingested, relay } = recordingRelay();

  const result = await runSweep(instagramSavedDriver({ fetchJson }), {}, {
    ...engineOpts, relay, storage, checkpointKey: "ig:test",
  });

  assert.equal(result.status, "halted");
  assert.ok(result.error && /checkpoint_required/.test(result.error), "halted on the challenge");
  assert.equal(ingested.length, fanout(page1), "page 1's items ingested before the halt");
  assert.ok(store.has("ig:test"), "checkpoint survived — the sweep is resumable, not lost");
});

test("IG integration: a non-200 (no recognizable challenge) also halts resumable", async () => {
  const midPage = { ...page1, more_available: true, next_max_id: "C2" };
  const { fetchJson } = scriptedFetch([
    { httpStatus: 200, json: midPage },
    { httpStatus: 500, json: {} },
  ]);
  const { ingested, relay } = recordingRelay();
  const result = await runSweep(instagramSavedDriver({ fetchJson }), {}, { ...engineOpts, relay });

  assert.equal(result.status, "halted");
  assert.ok(result.error && /http 500/.test(result.error));
  assert.equal(ingested.length, fanout(page1));
});
