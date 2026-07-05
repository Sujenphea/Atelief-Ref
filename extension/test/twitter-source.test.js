// Atelier Capture — X push→pull source tests (Phase 6).
//
// The source adapts pushed timeline responses into the engine's pull iterator,
// auto-scrolling to page. `scroll` + `sleep` are injected, so a fake `scroll` that
// feeds the next response drives the whole loop with no browser.

import { test } from "node:test";
import assert from "node:assert/strict";

import { createTwitterSource } from "../src/twitter-source.js";

/** A minimal timeline response: `mediaKeys` tweet entries + a Bottom cursor. */
function timeline(mediaKeys, cursor = "C") {
  const tweetEntries = mediaKeys.map((key) => ({
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
  assert.deepEqual(keys, ["k1a", "k1b", "k2"]); // empty page yields nothing, then ends
});

test("terminates after maxIdleRounds when scrolling yields no new response", async () => {
  let scrolls = 0;
  const source = createTwitterSource({
    sleep: () => Promise.resolve(),
    maxIdleRounds: 2,
    scroll: () => { scrolls += 1; }, // never feeds a response → the bottom / a wall
  });
  const items = await collect(source);
  assert.equal(items.length, 0);
  assert.equal(scrolls, 2); // gave up after 2 idle rounds
});

test("an unparseable captured response is ignored, not fatal", async () => {
  const source = createTwitterSource({ sleep: () => Promise.resolve(), maxIdleRounds: 1, scroll: () => {} });
  source.onResponse(null);            // garbage
  source.onResponse({ data: {} });    // no instructions
  const items = await collect(source);
  assert.equal(items.length, 0);      // survived; just yielded nothing
});
