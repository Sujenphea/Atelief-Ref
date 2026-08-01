// Atelier Capture — X end-to-end integration: fixture → source → engine (decision 11A).
//
// The parser (bulk-twitter.js), the push→pull source (twitter-source.js) and the sweep
// engine (bulk-engine.js) are each unit-tested in isolation, but nothing exercised them
// TOGETHER — the seam where a real intercepted `Bookmarks` response drives an actual
// sweep. These do: a fake `scroll` feeds pages into the source exactly as the live hook
// would, `runSweep` pulls them, and a recording relay stands in for the SW. Second test
// commits the 075/076 replay-contamination simulation (never committed before): a folder
// sweep fed a replayed MAIN-bookmarks page must ingest ONLY the folder's own tweets.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { createTwitterSource } from "../src/twitter-source.js";
import { parseTimelinePage } from "../src/bulk-twitter.js";
import { runSweep, OUTCOMES } from "../src/bulk-engine.js";

const bookmarks = JSON.parse(
  readFileSync(new URL("./fixtures/x-bookmarks.json", import.meta.url)));

/** The fixture's own MEDIA keys — one per media across every tweet (the 310 fan-out,
 * so a 3-photo tweet contributes three) — derived not hardcoded. */
const MAIN_KEYS = parseTimelinePage(bookmarks, { host: "x.com" }).items.map((i) => i.sourceId);

const MAIN_URL = "https://x.com/i/api/graphql/q1/Bookmarks?variables=%7B%7D";
const FOLDER_ID = "2005398616131952777";
const folderUrl = `https://x.com/i/api/graphql/q2/BookmarkFolderTimeline?variables=${
  encodeURIComponent(JSON.stringify({ bookmark_collection_id: FOLDER_ID }))}`;

/** A synthetic timeline page with distinct photo media keys + a Bottom cursor — so a
 * folder page is provably different from the main-bookmarks fixture. */
function timeline(keys, cursor = "C") {
  const tweetEntries = keys.map((key) => ({
    content: {
      entryType: "TimelineTimelineItem",
      itemContent: { tweet_results: { result: {
        __typename: "Tweet", rest_id: `t-${key}`,
        core: { user_results: { result: { core: { screen_name: "u", name: "U" } } } },
        legacy: { full_text: "x", extended_entities: { media: [
          { media_key: key, media_url_https: `https://pbs.twimg.com/media/${key}.jpg`, type: "photo" },
        ] } },
      } } },
    },
  }));
  const cursorEntry = { content: { entryType: "TimelineTimelineCursor", cursorType: "Bottom", value: cursor } };
  return { data: { bookmark_timeline_v2: { timeline: { instructions: [
    { type: "TimelineAddEntries", entries: [...tweetEntries, cursorEntry] },
  ] } } } };
}

const engineOpts = {
  sleep: () => Promise.resolve(), random: () => 0,
  config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
};

test("X integration: the real Bookmarks fixture drives a full sweep, every media ingested", async () => {
  // The live hook feeds page 1 (the fixture) then, on scroll, an empty tail page that
  // terminates the timeline (X has no -end- sentinel — a 0-tweet page is the end).
  const source = createTwitterSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 3, scope: "bookmarks",
    scroll: (() => {
      const pages = [[timeline([], "END"), MAIN_URL]];
      let i = 0;
      return () => { if (i < pages.length) { const [json, url] = pages[i++]; source.onResponse(json, url); } };
    })(),
  });
  source.onResponse(bookmarks, MAIN_URL); // page 1, as the replay buffer would deliver it

  const relayed = [];
  const relay = async (it) => { relayed.push(it.sourceId); return { outcome: OUTCOMES.ingested }; };
  const result = await runSweep(source, {}, { relay, ...engineOpts });

  assert.equal(result.status, "complete");
  assert.equal(result.counts.ingested, MAIN_KEYS.length);
  assert.deepEqual(relayed.slice().sort(), MAIN_KEYS.slice().sort());
});

test("X integration: a scroll STALL halts the sweep resumable, not a false complete (2A)", async () => {
  // The timeline yields a page, then scrolling walls (rate-limit / DOM stall) before any
  // 0-tweet end page. The source throws; the engine must HALT (→ the controller closes
  // "paused" and keeps the checkpoint), never "complete" (which would delete it).
  const source = createTwitterSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 2, scope: "bookmarks",
    scroll: () => {}, // never feeds another page → a wall after the first
  });
  source.onResponse(timeline(["a", "b"]), MAIN_URL); // one real page, then nothing more

  const relayed = [];
  const relay = async (it) => { relayed.push(it.sourceId); return { outcome: OUTCOMES.ingested }; };
  const result = await runSweep(source, {}, { relay, ...engineOpts });

  assert.equal(result.status, "halted");            // NOT "complete" → checkpoint survives
  assert.equal(result.haltStatus, null);            // self-halt → controller closes "paused"
  assert.deepEqual(relayed, ["a", "b"]);            // one item per MEDIA, keyed by media key
  assert.match(result.error, /stalled/);            // the stall surfaced for diagnostics
});

test("X integration: a folder sweep drops a replayed MAIN page, ingests ONLY the folder (075/076)", async () => {
  // Regression sim from 076: you browse your main bookmarks (buffered by 075), then open
  // a folder and sweep it. The replay re-emits the main page — scope-gating must drop it
  // so only the folder's own tweets ingest, not the whole main list.
  const source = createTwitterSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 3, scope: `bookmarks:${FOLDER_ID}`,
    scroll: (() => {
      const pages = [[timeline([], "END"), folderUrl]]; // empty folder tail → terminate
      let i = 0;
      return () => { if (i < pages.length) { const [json, url] = pages[i++]; source.onResponse(json, url); } };
    })(),
  });
  source.onResponse(bookmarks, MAIN_URL);              // replayed WRONG feed → must drop
  source.onResponse(timeline(["fA", "fB"]), folderUrl); // this folder → keep

  const relayed = [];
  const relay = async (it) => { relayed.push(it.sourceId); return { outcome: OUTCOMES.ingested }; };
  const result = await runSweep(source, {}, { relay, ...engineOpts });

  assert.equal(result.status, "complete");
  assert.deepEqual(relayed, ["fA", "fB"]);             // only the folder's media (keyed by media key)
  assert.equal(result.counts.ingested, 2);
  for (const key of MAIN_KEYS) {
    assert.equal(relayed.includes(key), false, `main-bookmarks media ${key} leaked into the folder sweep`);
  }
});
