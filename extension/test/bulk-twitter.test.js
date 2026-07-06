// Atelier Capture — X / Twitter BulkSource parsing + hook tests (Phase 5, [T9]).
//
// The parsers run against the committed sanitized `Bookmarks` fixture, so an X
// response-shape drift breaks a unit test, not a live sweep. Covers: the timeline
// URL predicate, tweet unwrap, the multi-photo → many-items mapping, video → poster
// + best-MP4, the "never read quoted media" rule, the page parser (items + bottom
// cursor + tweetCount), and the MAIN-world fetch hook (fake scope, no browser).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  unwrapTweet, findInstructions, mapTweet, parseTimelinePage,
} from "../src/bulk-twitter.js";

// twitter-hook.js ships as a CLASSIC MAIN-world content script (NO export — that would
// SyntaxError on injection and silently kill the hook). So load + evaluate the REAL file
// the way Chrome injects it and lift out its functions — this test then verifies the
// exact injected artifact, not an ESM-only shim. A fake `window` (no `.location`) skips
// the auto-install tail so only the explicit calls below run it.
const { installTimelineHook, isTimelineRequest, TIMELINE_MESSAGE_SOURCE } = (() => {
  const src = readFileSync(new URL("../src/twitter-hook.js", import.meta.url), "utf8");
  return new Function(
    "window",
    `${src}\nreturn { installTimelineHook, isTimelineRequest, TIMELINE_MESSAGE_SOURCE };`,
  )({});
})();

const bookmarks = JSON.parse(
  readFileSync(new URL("./fixtures/x-bookmarks.json", import.meta.url)));

// The three tweet entries in the fixture, by DOM order.
const entries = findInstructions(bookmarks)
  .flatMap((i) => i.entries || [])
  .filter((e) => e.content?.entryType === "TimelineTimelineItem")
  .map((e) => e.content.itemContent.tweet_results.result);
const [videoTweet, photoTweet] = entries;

// MARK: - isTimelineRequest

test("isTimelineRequest: matches Bookmarks/Likes graphql ops, rejects others", () => {
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/AbC123/Bookmarks"), true);
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/XyZ/Likes?variables=%7B%7D"), true);
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/AbC/HomeTimeline"), false);
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/AbC/BookmarksFolder"), false);
  assert.equal(isTimelineRequest("https://pbs.twimg.com/media/x.jpg"), false);
  assert.equal(isTimelineRequest(null), false);
});

// MARK: - unwrapTweet

test("unwrapTweet: unwraps visibility-wrapped tweets, drops tombstones", () => {
  assert.equal(unwrapTweet({ __typename: "Tweet", legacy: {} }).legacy != null, true);
  const inner = { __typename: "Tweet", legacy: {} };
  assert.equal(unwrapTweet({ __typename: "TweetWithVisibilityResults", tweet: inner }), inner);
  assert.equal(unwrapTweet({ __typename: "TweetTombstone" }), null);
  assert.equal(unwrapTweet(null), null);
});

// MARK: - mapTweet

test("mapTweet: a video tweet → one poster item with the best MP4 in rawMetadata", () => {
  const items = mapTweet(videoTweet, { host: "x.com" });
  assert.equal(items.length, 1);
  const item = items[0];
  assert.equal(item.sourceId, "REDACTED");        // media_key, not tweet id
  assert.equal(item.mediaUrl, "https://pbs.twimg.com/media/SAMPLE24.jpg?name=orig");
  assert.equal(item.mediaUrlFallback, "https://pbs.twimg.com/media/SAMPLE24.jpg");
  assert.equal(item.provenance.rawMetadata.kind, "video");
  assert.equal(item.provenance.rawMetadata.tweetId, "1000000000000000034");
  // highest-bitrate progressive MP4 from the response (no syndication call needed).
  assert.equal(item.provenance.rawMetadata.videoUrl,
    "https://video.twimg.com/amplify_video/1031/vid/720x1280/SAMPLE31.mp4?tag=12");
  assert.equal(item.provenance.authorHandle, "@sampleuser");
  assert.equal(item.provenance.originalURL, "https://x.com/sampleuser/status/1000000000000000034");
});

test("mapTweet: a multi-photo tweet → one item per photo, unique media keys", () => {
  const items = mapTweet(photoTweet, { host: "x.com" });
  assert.deepEqual(items.map((i) => i.sourceId), [
    "REDACTED", "REDACTED", "REDACTED",
  ]);
  for (const item of items) {
    assert.equal(item.provenance.rawMetadata.kind, "photo");
    assert.equal(item.provenance.rawMetadata.videoUrl, null);
    assert.match(item.mediaUrl, /\?name=orig$/);
  }
});

test("mapTweet: text-only / no-id / tombstone → no items", () => {
  assert.deepEqual(mapTweet({ __typename: "Tweet", rest_id: "1", legacy: {} }, {}), []);
  assert.deepEqual(mapTweet({ __typename: "Tweet", legacy: { full_text: "hi" } }, {}), []); // no id
  assert.deepEqual(mapTweet({ __typename: "TweetTombstone" }, {}), []);
});

// MARK: - parseTimelinePage

test("parseTimelinePage: yields one item per top-level media across the page", () => {
  const { items, bottomCursor, tweetCount } = parseTimelinePage(bookmarks, { host: "x.com" });

  assert.equal(tweetCount, 3);                     // three tweet entries
  assert.equal(bottomCursor, "Sample text");       // the Bottom cursor's value

  const keys = items.map((i) => i.sourceId);
  // tweet 1 (video) + tweet 2 (3 photos) = 4 top-level media.
  assert.deepEqual(keys, [
    "REDACTED",
    "REDACTED", "REDACTED", "REDACTED",
  ]);
  // Quoted-tweet media must NOT leak in (tweet 2 quotes a 3-photo tweet; tweet 3
  // quotes a video tweet) — we only read the TOP-LEVEL tweet's media.
  assert.equal(keys.includes("REDACTED"), false); // tweet-2 quoted photo
  assert.equal(keys.includes("REDACTED"), false); // tweet-3 quoted video

  // Every item is stamped with the page's checkpoint cursor.
  for (const item of items) assert.equal(item.cursor, "Sample text");
});

test("parseTimelinePage: an empty timeline → no items, tweetCount 0 (the terminator)", () => {
  const empty = { data: { bookmark_timeline_v2: { timeline: { instructions: [
    { type: "TimelineAddEntries", entries: [
      { content: { entryType: "TimelineTimelineCursor", cursorType: "Bottom", value: "END" } },
    ] },
  ] } } } };
  const { items, tweetCount, bottomCursor } = parseTimelinePage(empty, {});
  assert.equal(items.length, 0);
  assert.equal(tweetCount, 0);
  assert.equal(bottomCursor, "END");
});

test("findInstructions: falls back to a deep search when the wrapper key differs", () => {
  const odd = { data: { some_new_wrapper: { timeline: { instructions: [{ entries: [] }] } } } };
  assert.equal(Array.isArray(findInstructions(odd)), true);
  assert.equal(findInstructions(odd).length, 1);
  assert.deepEqual(findInstructions({ data: {} }), []);
});

// MARK: - installTimelineHook (MAIN-world fetch wrapper)

test("twitter-hook.js is a valid CLASSIC script (no static export/import → injectable)", () => {
  // The T9 bug: a static `export`/`import` SyntaxErrors when Chrome injects the file as
  // a classic MAIN-world script, silently killing the hook. new Function throws on that
  // exact syntax, so this guards the regression at its true failure point.
  const src = readFileSync(new URL("../src/twitter-hook.js", import.meta.url), "utf8");
  assert.doesNotThrow(() => new Function("window", src));
});

/** A fake window scope with an injectable `fetch` returning a cloneable response. */
function fakeScope(responseJson) {
  const response = {
    clone: () => ({ json: async () => responseJson }),
  };
  return { fetch: async () => response, __response: response };
}
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("installTimelineHook: forwards a timeline response, passes others through", async () => {
  const scope = fakeScope({ ok: 1 });
  const posted = [];
  assert.equal(installTimelineHook({ target: scope, post: (m) => posted.push(m) }), true);

  const returned = await scope.fetch("https://x.com/i/api/graphql/Q/Bookmarks");
  await tick();
  assert.equal(posted.length, 1);
  assert.equal(posted[0].url, "https://x.com/i/api/graphql/Q/Bookmarks");
  assert.deepEqual(posted[0].json, { ok: 1 });
  assert.equal(returned, scope.__response);        // page's own response, untouched

  await scope.fetch("https://x.com/i/api/graphql/Q/HomeTimeline");
  await tick();
  assert.equal(posted.length, 1);                  // non-timeline request ignored
});

test("installTimelineHook: is idempotent (no double-wrap) and needs a fetch", () => {
  const scope = fakeScope({});
  assert.equal(installTimelineHook({ target: scope, post: () => {} }), true);
  assert.equal(installTimelineHook({ target: scope, post: () => {} }), false);
  assert.equal(installTimelineHook({ target: {}, post: () => {} }), false); // no fetch
  assert.equal(typeof TIMELINE_MESSAGE_SOURCE, "string");
});

test("installTimelineHook: a post/parse failure never breaks the page's fetch", async () => {
  const scope = fakeScope({});
  const returned = await (() => {
    installTimelineHook({ target: scope, post: () => { throw new Error("boom"); } });
    return scope.fetch("https://x.com/i/api/graphql/Q/Likes");
  })();
  await tick();
  assert.equal(returned, scope.__response);        // still returns cleanly
});
