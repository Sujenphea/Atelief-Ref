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
  unwrapTweet, findInstructions, mapTweet, parseTimelinePage, matchesScope, graphqlOp,
} from "../src/bulk-twitter.js";
import {
  TIMELINE_MESSAGE_SOURCE as MSG_SRC, TIMELINE_REPLAY_SOURCE as REPLAY_SRC,
} from "../src/bulk-messages.js";

// twitter-hook.js ships as a CLASSIC MAIN-world content script (NO export — that would
// SyntaxError on injection and silently kill the hook). Since [5A] the interception
// MACHINERY lives in hook-core.js (tested in hook-core.test.js); this file is now a thin
// config, so we lift out only what it still owns: the URL matcher + the message tags. A
// fake `window` (no `.location`) skips the auto-install tail so the load is inert.
const { isTimelineRequest, TIMELINE_MESSAGE_SOURCE, REPLAY_REQUEST_SOURCE } = (() => {
  const src = readFileSync(new URL("../src/twitter-hook.js", import.meta.url), "utf8");
  return new Function(
    "window",
    `${src}\nreturn { isTimelineRequest, TIMELINE_MESSAGE_SOURCE, REPLAY_REQUEST_SOURCE };`,
  )({});
})();

const bookmarks = JSON.parse(
  readFileSync(new URL("./fixtures/x-bookmarks.json", import.meta.url)));

// The three tweet entries in the fixture, by DOM order.
const entries = findInstructions(bookmarks)
  .flatMap((i) => i.entries || [])
  .filter((e) => e.content?.entryType === "TimelineTimelineItem")
  .map((e) => e.content.itemContent.tweet_results.result);
const [videoTweet, photoTweet, textTweet] = entries;

// MARK: - isTimelineRequest

test("isTimelineRequest: matches Bookmarks/BookmarkFolderTimeline/Likes ops, rejects others", () => {
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/AbC123/Bookmarks"), true);
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/XyZ/Likes?variables=%7B%7D"), true);
  // The real bookmark-folder op (verified live) — the folder-sweep enabler.
  assert.equal(isTimelineRequest(
    "https://x.com/i/api/graphql/oKopHt25pa6yhDn1ek7Qng/BookmarkFolderTimeline?variables=%7B%7D"), true);
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/AbC/HomeTimeline"), false);
  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/AbC/CreateBookmark"), false);
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

test("mapTweet: a video tweet → one tweet item, poster card + best MP4 stashed", () => {
  const items = mapTweet(videoTweet, { host: "x.com" });
  assert.equal(items.length, 1);
  const item = items[0];
  assert.equal(item.sourceId, "1000000000000000034");           // the TWEET id (not a media key)
  assert.equal(item.provenance.rawMetadata.tweetId, "1000000000000000034");
  assert.equal(item.mediaUrl, "https://pbs.twimg.com/media/SAMPLE24.jpg?name=orig"); // poster is the card
  assert.equal(item.mediaUrlFallback, "https://pbs.twimg.com/media/SAMPLE24.jpg");
  assert.equal(item.provenance.rawMetadata.kind, "video");
  // highest-bitrate progressive MP4 from the response (no syndication call needed).
  assert.equal(item.provenance.rawMetadata.videoUrl,
    "https://video.twimg.com/amplify_video/1031/vid/720x1280/SAMPLE31.mp4?tag=12");
  // The content descriptor: a tweet carrying its one media reference.
  assert.equal(item.content.kind, "tweet");
  assert.equal(item.content.payload.tweet.tweetID, "1000000000000000034");
  assert.equal(item.content.payload.tweet.media.length, 1);
  assert.equal(item.provenance.authorHandle, "@sampleuser");
  assert.equal(item.provenance.originalURL, "https://x.com/sampleuser/status/1000000000000000034");
});

test("mapTweet: a multi-photo tweet → ONE item carrying all photos in media[]", () => {
  const items = mapTweet(photoTweet, { host: "x.com" });
  assert.equal(items.length, 1);                                 // one tweet = one item
  const item = items[0];
  assert.equal(item.sourceId, "1000000000000000171");            // keyed by the tweet id
  assert.equal(item.provenance.rawMetadata.kind, "photo");
  assert.equal(item.provenance.rawMetadata.videoUrl, null);
  const media = item.content.payload.tweet.media;
  assert.equal(media.length, 3);                                 // all three photos, as references
  for (const m of media) assert.match(m.url, /\?name=orig$/);    // each at original resolution
  assert.equal(item.mediaUrl, media[0].url);                     // the first photo is the card image
});

test("mapTweet: a BARE quote of a video captures the QUOTED video (own media empty)", () => {
  // The fixture's 3rd tweet is a quote with no media of its own, quoting a video —
  // exactly the case where the substance is the quoted media.
  const items = mapTweet(textTweet, { host: "x.com" });
  assert.equal(items.length, 1);
  const item = items[0];
  assert.equal(item.sourceId, "1000000000000000212");           // the QUOTE tweet's OWN id (what you bookmarked)
  assert.equal(item.provenance.rawMetadata.kind, "video");
  assert.match(item.mediaUrl, /SAMPLE203\.jpg\?name=orig$/);     // the quoted video's poster
  assert.equal(item.provenance.rawMetadata.videoUrl,             // the quoted video's MP4 (opt-in downloads it)
    "https://video.twimg.com/amplify_video/1208/vid/720x1280/SAMPLE208.mp4?tag=12");
  assert.equal(item.content.payload.tweet.media.length, 1);
  assert.equal(item.content.payload.tweet.text, "Sample text"); // the quoter's OWN text is kept
});

test("mapTweet: a quote WITH its own media ignores the quoted media (own wins)", () => {
  const quote = {
    __typename: "Tweet", rest_id: "10",
    core: { user_results: { result: { core: { screen_name: "q", name: "Q" } } } },
    legacy: {
      full_text: "my take",
      extended_entities: { media: [
        { media_key: "own", media_url_https: "https://pbs.twimg.com/media/OWN.jpg", type: "photo" },
      ] },
      quoted_status_result: { result: { __typename: "Tweet", rest_id: "11", legacy: {
        extended_entities: { media: [
          { media_key: "q1", media_url_https: "https://pbs.twimg.com/media/QUOTED.jpg", type: "photo" },
        ] },
      } } },
    },
  };
  const item = mapTweet(quote, { host: "x.com" })[0];
  assert.equal(item.content.payload.tweet.media.length, 1); // NOT merged with the quoted photo
  assert.match(item.mediaUrl, /OWN\.jpg/);                  // the quoter's own media
});

test("mapTweet: a genuine text-only tweet (no media, no quote) → a media-less text card", () => {
  const textOnly = {
    __typename: "Tweet", rest_id: "555",
    core: { user_results: { result: { core: { screen_name: "u", name: "U" } } } },
    legacy: { full_text: "just a thought" },
  };
  const item = mapTweet(textOnly, { host: "x.com" })[0];
  assert.equal(item.sourceId, "555");
  assert.equal(item.mediaUrl, null);
  assert.equal(item.provenance.rawMetadata.kind, "text");
  assert.deepEqual(item.content.payload.tweet.media, []);
  assert.equal(item.content.payload.tweet.text, "just a thought");
});

test("mapTweet: an empty / no-id / tombstone tweet → no items", () => {
  // No text AND no media → the app would reject it, so we skip it up front.
  assert.deepEqual(mapTweet({ __typename: "Tweet", rest_id: "1", legacy: {} }, {}), []);
  assert.deepEqual(mapTweet({ __typename: "Tweet", legacy: { full_text: "hi" } }, {}), []); // no id
  assert.deepEqual(mapTweet({ __typename: "TweetTombstone" }, {}), []);
});

test("mapTweet: a REPOST unwraps to the original — saves its media/author/id", () => {
  // A retweet holds no media of its own; the substance is on retweeted_status_result.
  const repost = {
    __typename: "Tweet",
    rest_id: "9999", // the repost's OWN id — must NOT be used
    core: { user_results: { result: { core: { screen_name: "reposter", name: "Reposter" } } } },
    legacy: {
      full_text: "RT @orig: check this",
      retweeted_status_result: { result: {
        __typename: "Tweet",
        rest_id: "1000000000000000034",
        core: { user_results: { result: { core: { screen_name: "origauthor", name: "Orig Author" } } } },
        legacy: { full_text: "original tweet text", extended_entities: { media: [
          { media_key: "3_abc", media_url_https: "https://pbs.twimg.com/media/ORIG.jpg", type: "photo" },
        ] } },
      } },
    },
  };
  const items = mapTweet(repost, { host: "x.com" });
  assert.equal(items.length, 1);
  const item = items[0];
  assert.equal(item.sourceId, "1000000000000000034");          // the ORIGINAL's id → dedups w/ a direct save
  assert.equal(item.provenance.authorHandle, "@origauthor");    // original author, not the reposter
  assert.equal(item.provenance.originalURL, "https://x.com/origauthor/status/1000000000000000034");
  assert.equal(item.content.payload.tweet.text, "original tweet text");
  assert.equal(item.content.payload.tweet.media.length, 1);     // the original's media, saved
  assert.match(item.mediaUrl, /ORIG\.jpg\?name=orig$/);
});

// MARK: - parseTimelinePage

test("parseTimelinePage: yields ONE item per tweet, keyed by tweet id", () => {
  const { items, bottomCursor, tweetCount } = parseTimelinePage(bookmarks, { host: "x.com" });

  assert.equal(tweetCount, 3);                     // three tweet entries
  assert.equal(bottomCursor, "Sample text");       // the Bottom cursor's value

  // One item per tweet (video · 3-photo · text-only), keyed by the TWEET id.
  assert.deepEqual(items.map((i) => i.sourceId), [
    "1000000000000000034", "1000000000000000171", "1000000000000000212",
  ]);
  // Media references: video (1) + the photo tweet's OWN 3 photos + the bare-quote
  // tweet's fallback to its quoted video (1) = 5. The photo tweet HAS its own media, so
  // its quoted 3-photo tweet is NOT merged (own media wins) — only a BARE quote borrows.
  const totalMedia = items.reduce((n, i) => n + i.content.payload.tweet.media.length, 0);
  assert.equal(totalMedia, 5);

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

test("findInstructions: resolves the bookmark FOLDER wrapper (bookmark_collection_timeline)", () => {
  const folder = { data: { bookmark_collection_timeline: { timeline: { instructions: [{ entries: [] }] } } } };
  assert.equal(findInstructions(folder).length, 1);
});

test("parseTimelinePage: parses a bookmark-FOLDER response the same as the main tab", () => {
  // A folder response nests the SAME TimelineTimelineItem tweets under
  // `bookmark_collection_timeline` (verified against a live capture). Rewrap the real
  // fixture's instructions under the folder wrapper → it must yield the same items,
  // proving folder sweeps ingest once the hook forwards the response.
  const folderPage = {
    data: { bookmark_collection_timeline: { timeline: { instructions: findInstructions(bookmarks) } } },
  };
  const fromMain = parseTimelinePage(bookmarks, { host: "x.com" });
  const fromFolder = parseTimelinePage(folderPage, { host: "x.com" });
  assert.equal(fromFolder.items.length, fromMain.items.length);
  assert.ok(fromFolder.items.length > 0, "the folder page must yield media items");
  assert.equal(fromFolder.tweetCount, fromMain.tweetCount);
  assert.deepEqual(fromFolder.items.map((i) => i.sourceId), fromMain.items.map((i) => i.sourceId));
});

// MARK: - matchesScope (route intercepted responses to the right sweep)

const MAIN_URL = "https://x.com/i/api/graphql/q1/Bookmarks?variables=%7B%22count%22%3A20%7D";
const FOLDER_ID = "2005398616131952777";
const OTHER_FOLDER_ID = "1111111111111111111";
// A real folder URL: `bookmark_collection_id` rides (percent-encoded) in `variables`.
const folderUrl = (id) =>
  `https://x.com/i/api/graphql/q2/BookmarkFolderTimeline?variables=${
    encodeURIComponent(JSON.stringify({ bookmark_collection_id: id, count: 20 }))}`;
const LIKES_URL = "https://x.com/i/api/graphql/q3/Likes?variables=%7B%22count%22%3A20%7D";

test("matchesScope: main 'bookmarks' accepts only the Bookmarks op, not folders/Likes", () => {
  assert.equal(matchesScope(MAIN_URL, "bookmarks"), true);
  assert.equal(matchesScope(folderUrl(FOLDER_ID), "bookmarks"), false); // BookmarkFolderTimeline ≠ Bookmarks
  assert.equal(matchesScope(LIKES_URL, "bookmarks"), false);
});

test("matchesScope: a folder scope accepts only its own folder id", () => {
  assert.equal(matchesScope(folderUrl(FOLDER_ID), `bookmarks:${FOLDER_ID}`), true);
  assert.equal(matchesScope(folderUrl(OTHER_FOLDER_ID), `bookmarks:${FOLDER_ID}`), false); // another folder
  assert.equal(matchesScope(MAIN_URL, `bookmarks:${FOLDER_ID}`), false); // the main list
  assert.equal(matchesScope(LIKES_URL, `bookmarks:${FOLDER_ID}`), false);
});

test("matchesScope: a missing/unknown scope or non-string url matches nothing", () => {
  assert.equal(matchesScope(MAIN_URL, null), false);
  assert.equal(matchesScope(MAIN_URL, "likes"), false);
  assert.equal(matchesScope(undefined, "bookmarks"), false);
  assert.equal(matchesScope(folderUrl(FOLDER_ID), "bookmarks:notanid"), false);
});

test("graphqlOp: extracts the op name and JSON-parses the variables blob (6A)", () => {
  const parsed = graphqlOp(folderUrl(FOLDER_ID));
  assert.equal(parsed.op, "BookmarkFolderTimeline");
  assert.equal(parsed.variables.bookmark_collection_id, FOLDER_ID); // decoded + parsed, not substring
  assert.equal(parsed.variables.count, 20);

  assert.equal(graphqlOp(MAIN_URL).op, "Bookmarks");
  assert.deepEqual(graphqlOp("https://x.com/i/api/graphql/q/Bookmarks").variables, {}); // no variables → {}
});

test("graphqlOp: a non-GraphQL / malformed url → null; a bad variables blob → {} (never throws)", () => {
  assert.equal(graphqlOp("https://pbs.twimg.com/media/x.jpg"), null);
  assert.equal(graphqlOp("not a url"), null);
  assert.equal(graphqlOp(null), null);
  // A corrupt variables param degrades to {} rather than throwing into the sweep.
  assert.deepEqual(graphqlOp("https://x.com/i/api/graphql/q/Bookmarks?variables=%7Bnope").variables, {});
});

// MARK: - installTimelineHook (MAIN-world fetch wrapper)

test("twitter-hook.js is a valid CLASSIC script (no static export/import → injectable)", () => {
  // The T9 bug: a static `export`/`import` SyntaxErrors when Chrome injects the file as
  // a classic MAIN-world script, silently killing the hook. new Function throws on that
  // exact syntax, so this guards the regression at its true failure point.
  const src = readFileSync(new URL("../src/twitter-hook.js", import.meta.url), "utf8");
  assert.doesNotThrow(() => new Function("window", src));
});

test("hook wire constants stay in sync with bulk-messages (the KEEP IN SYNC duplication)", () => {
  assert.equal(TIMELINE_MESSAGE_SOURCE, MSG_SRC);
  assert.equal(REPLAY_REQUEST_SOURCE, REPLAY_SRC);
});
