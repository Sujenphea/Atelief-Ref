// Atelier Capture — X push→pull source tests (Phase 6).
//
// The source adapts pushed timeline responses into the engine's pull iterator,
// auto-scrolling to page. `scroll` + `sleep` are injected, so a fake `scroll` that
// feeds the next response drives the whole loop with no browser.

import { test } from "node:test";
import assert from "node:assert/strict";

import { createTwitterSource, TimelineStallError } from "../src/twitter-source.js";

/** A minimal timeline response: one tweet entry per `keys` element (each a single-photo
 * tweet with `rest_id: t-<key>`) + a Bottom cursor. A tweet maps to one item PER MEDIA
 * keyed by the media key (310), so the yielded sourceIds are the `<key>`s themselves. */
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

async function collect(source) {
  const items = [];
  for await (const item of source.enumerate()) items.push(item);
  return items;
}

test("yields items across scroll-loaded pages, ends on an empty (0-tweet) page", async () => {
  const source = createTwitterSource({
    sleep: () => Promise.resolve(),
    maxIdleRounds: 3,
    scroll: (() => {
      // Each scroll loads the next page; the last is empty → terminates.
      const pages = [timeline(["k2"]), timeline([], "END")];
      let i = 0;
      return () => { if (i < pages.length) source.onResponse(pages[i++]); };
    })(),
  });
  source.onResponse(timeline(["k1a", "k1b"])); // first page already captured

  const keys = (await collect(source)).map((i) => i.sourceId);
  assert.deepEqual(keys, ["k1a", "k1b", "k2"]); // one item per tweet; empty page ends it
});

test("STALLS (throws) after maxIdleRounds when scrolling yields no new response", async () => {
  // A wall (rate-limit / DOM stall) is NOT a confirmed end — only a 0-tweet page is. So
  // idle exhaustion throws a typed stall; the engine turns that into a RESUMABLE pause
  // that keeps the checkpoint, rather than a false "complete" that deletes it (2A).
  let scrolls = 0;
  const source = createTwitterSource({
    sleep: () => Promise.resolve(),
    maxIdleRounds: 2,
    scroll: () => { scrolls += 1; }, // never feeds a response → the bottom / a wall
  });
  await assert.rejects(() => collect(source), TimelineStallError);
  assert.equal(scrolls, 2); // gave up after 2 idle rounds
});

test("a stall that follows real items still throws — the items already yielded are kept", async () => {
  // First page yields, then the page walls. The consumer (engine) has recorded the real
  // items before the throw, so a resumable pause loses nothing already ingested.
  const source = createTwitterSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 1, scroll: () => {},
  });
  source.onResponse(timeline(["k1"])); // one real page, cursor "C" (not an end page)
  const yielded = [];
  await assert.rejects(async () => {
    for await (const item of source.enumerate()) yielded.push(item.sourceId);
  }, TimelineStallError);
  assert.deepEqual(yielded, ["k1"]); // the real item came through before the wall
});

test("with a folder scope, drops responses from OTHER feeds (replay-buffer contamination)", async () => {
  // The hook forwards — and 075 replays — every timeline the page fetched: main
  // bookmarks, Likes, other folders. A folder sweep must ingest ONLY its own folder,
  // or it pulls in tweets from outside it. onResponse now takes the response's url.
  const FID = "2005398616131952777";
  const folderUrl = `https://x.com/i/api/graphql/q/BookmarkFolderTimeline?variables=${
    encodeURIComponent(JSON.stringify({ bookmark_collection_id: FID }))}`;
  const mainUrl = "https://x.com/i/api/graphql/q/Bookmarks?variables=%7B%7D";

  const source = createTwitterSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 1,
    // The next scroll delivers this folder's empty (0-tweet) end page → clean finish.
    scroll: (() => { let fed = false; return () => { if (!fed) { fed = true; source.onResponse(timeline([], "END"), folderUrl); } }; })(),
    scope: `bookmarks:${FID}`,
  });
  source.onResponse(timeline(["main1", "main2"]), mainUrl);       // WRONG feed → dropped
  source.onResponse(timeline(["fA", "fB"]), folderUrl);          // this folder → kept

  const keys = (await collect(source)).map((i) => i.sourceId);
  assert.deepEqual(keys, ["fA", "fB"]); // only the folder's own tweets
});

test("with no scope set, accepts every response (unchanged legacy behaviour)", async () => {
  const source = createTwitterSource({
    sleep: () => Promise.resolve(), maxIdleRounds: 1,
    scroll: (() => { let fed = false; return () => { if (!fed) { fed = true; source.onResponse(timeline([], "END")); } }; })(),
  });
  source.onResponse(timeline(["a"])); // no url, no scope → still queued
  const keys = (await collect(source)).map((i) => i.sourceId);
  assert.deepEqual(keys, ["a"]);
});

test("an unparseable captured response is ignored, not fatal", async () => {
  const source = createTwitterSource({ sleep: () => Promise.resolve(), maxIdleRounds: 1, scroll: () => {} });
  source.onResponse(null);            // garbage
  source.onResponse({ data: {} });    // no instructions
  const items = await collect(source);
  assert.equal(items.length, 0);      // survived; just yielded nothing
});
