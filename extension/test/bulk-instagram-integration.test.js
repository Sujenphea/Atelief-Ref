// Atelier Capture — Instagram end-to-end integration: fixture → source → engine (002 · B3, [9A][11A]).
//
// The parser (bulk-instagram.js), the push→pull source (instagram-source.js) and the
// sweep engine (bulk-engine.js) are each unit-tested in isolation; these exercise them
// TOGETHER, the seam a real intercepted saved-feed response drives an actual sweep. A fake
// `scroll` feeds pages into the source exactly as the live hook would, `runSweep` pulls
// them, and a recording relay stands in for the SW. Second test pins the account-safety
// property (11A): a challenge mid-sweep halts RESUMABLE with the checkpoint preserved.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { createInstagramSource, InstagramStallError } from "../src/instagram-source.js";
import { parseSavedFeedPage, IG_MEDIA_TYPE } from "../src/bulk-instagram.js";
import { runSweep, OUTCOMES } from "../src/bulk-engine.js";

const saved = JSON.parse(readFileSync(new URL("./fixtures/instagram-saved.json", import.meta.url)));

/** The fixture's expected fanned-out item count (image + reel + carousel children). */
const EXPECTED_ITEMS = parseSavedFeedPage(saved).items.length;

const engineOpts = {
  sleep: () => Promise.resolve(), random: () => 0,
  config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
};

/** A relay that records every sourceId it ingests (stands in for the SW → app). */
function recordingRelay() {
  const ingested = [];
  return {
    ingested,
    relay: async (item) => { ingested.push(item.sourceId); return { outcome: OUTCOMES.ingested }; },
  };
}

test("IG integration: the real saved fixture drives a full sweep, every media ingested (fan-out)", async () => {
  // The live hook feeds page 1 (the fixture, more_available:false → the terminal page).
  const source = createInstagramSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 3,
    scroll: () => {}, // no more pages; the fixture is already end-of-feed
  });
  source.onResponse(saved, "https://www.instagram.com/api/v1/feed/saved/posts/");

  const { ingested, relay } = recordingRelay();
  const result = await runSweep(source, {}, { ...engineOpts, relay });

  assert.equal(result.status, "complete");
  assert.equal(result.counts.ingested, EXPECTED_ITEMS);
  assert.equal(ingested.length, EXPECTED_ITEMS);
  assert.equal(new Set(ingested).size, EXPECTED_ITEMS, "every fanned-out media is a distinct per-media pk");
});

test("IG integration: a carousel post ingests one item PER child image (1A end-to-end)", async () => {
  const carousel = saved.items.map((w) => w.media).find((m) => m.media_type === IG_MEDIA_TYPE.carousel);
  const onePost = { status: "ok", more_available: false, items: [{ media: carousel }] };

  const source = createInstagramSource({ sleep: () => Promise.resolve(), maxIdleRounds: 2, scroll: () => {} });
  source.onResponse(onePost, "https://www.instagram.com/api/v1/feed/saved/posts/");

  const { ingested, relay } = recordingRelay();
  const result = await runSweep(source, {}, { ...engineOpts, relay });

  assert.equal(result.status, "complete");
  assert.equal(ingested.length, carousel.carousel_media.length); // one BulkItem per child
  assert.deepEqual(ingested.sort(), carousel.carousel_media.map((c) => String(c.pk)).sort());
});

test("IG integration: a challenge mid-sweep HALTS resumable, checkpoint preserved (11A)", async () => {
  // Page 1 ingests; the next scroll delivers a checkpoint_required challenge body (which the
  // status-blind hook forwards). The source re-raises it → the engine halts RESUMABLE, so a
  // half-swept feed is paused (checkpoint kept), never falsely completed.
  const midPage = { status: "ok", more_available: true, next_max_id: "CURSOR2",
    items: [{ media: saved.items[0].media }] };
  const challenge = { message: "checkpoint_required", status: "fail" };

  const source = createInstagramSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 3,
    scroll: (() => { let fed = false; return () => { if (!fed) { fed = true; source.onResponse(challenge, "https://www.instagram.com/api/v1/feed/saved/posts/?max_id=CURSOR2"); } }; })(),
  });
  source.onResponse(midPage, "https://www.instagram.com/api/v1/feed/saved/posts/");

  const store = new Map();
  const storage = { load: async (k) => store.get(k) ?? null, save: async (k, v) => { store.set(k, v); }, remove: async (k) => { store.delete(k); } };
  const { ingested, relay } = recordingRelay();
  const result = await runSweep(source, {}, {
    ...engineOpts, relay, storage, checkpointKey: "ig:test",
  });

  assert.equal(result.status, "halted");                 // the challenge halted the sweep
  assert.ok(result.error && /checkpoint_required/.test(result.error), "the halt reason is the challenge");
  assert.ok(ingested.length >= 1, "page 1's items were ingested before the halt");
  assert.ok(store.has("ig:test"), "the checkpoint survived — the sweep is resumable, not lost");
});

test("IG integration: a stall (no challenge, no end page) halts resumable via InstagramStallError", async () => {
  // more_available:true but scrolling yields nothing new → a STALL, not a confirmed end.
  const midPage = { status: "ok", more_available: true, next_max_id: "CURSOR2",
    items: [{ media: saved.items[0].media }] };
  const source = createInstagramSource({ sleep: () => Promise.resolve(), maxIdleRounds: 2, scroll: () => {} });
  source.onResponse(midPage, "https://www.instagram.com/api/v1/feed/saved/posts/");

  await assert.rejects(async () => {
    for await (const _item of source.enumerate()) { /* drain */ }
  }, InstagramStallError);
});
