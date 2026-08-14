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
  combineQuoteText, tweetText, stampGroup,
} from "../src/bulk-twitter.js";
import {
  TIMELINE_MESSAGE_SOURCE as MSG_SRC, TIMELINE_REPLAY_SOURCE as REPLAY_SRC,
} from "../src/bulk-messages.js";

// twitter-hook.js ships as a CLASSIC MAIN-world content script (NO export — that would
// SyntaxError on injection and silently kill the hook). Since [5A] the interception
// MACHINERY lives in hook-core.js (tested in hook-core.test.js); this file is now a thin
// config, so we lift out only what it still owns: the two URL predicates + the message
// tags. The fake `window` carries a real X origin (`isProxyableRequest` resolves urls
// against it) and a no-op installer, so the auto-install tail runs inertly.
const { isTimelineRequest, isProxyableRequest, TIMELINE_MESSAGE_SOURCE, REPLAY_REQUEST_SOURCE } =
  (() => {
    const src = readFileSync(new URL("../src/twitter-hook.js", import.meta.url), "utf8");
    return new Function(
      "window",
      `${src}\nreturn { isTimelineRequest, isProxyableRequest, TIMELINE_MESSAGE_SOURCE, REPLAY_REQUEST_SOURCE };`,
    )({
      location: { hostname: "x.com", origin: "https://x.com" },
      __atelierInstallResponseHook: () => {},
    });
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

// MARK: - isProxyableRequest (the hook proxy's security boundary, [090] 3A/10A)

test("isProxyableRequest: allows X's own TweetDetail read and nothing else", () => {
  assert.equal(isProxyableRequest(
    "https://x.com/i/api/graphql/QID/TweetDetail?variables=%7B%7D"), true);
  assert.equal(isProxyableRequest("https://x.com/i/api/graphql/QID/TweetDetail"), true);
});

test("isProxyableRequest: refuses anything that would spend the token elsewhere", () => {
  // Every one of these is a request a page script would love the hook to make for it.
  const refused = [
    "https://x.com/i/api/1.1/dm/inbox.json",                    // same origin, DMs
    "https://x.com/i/api/graphql/QID/Bookmarks",                // another op entirely
    "https://x.com/i/api/graphql/QID/CreateTweet",              // a mutation
    "https://x.com/i/api/graphql/QID/TweetDetail/extra",        // path suffix past the op
    "https://x.com/i/api/graphql/QID/TweetDetailPlus",          // op-name prefix match
    "https://evil.example/i/api/graphql/QID/TweetDetail",       // right shape, wrong origin
    "https://x.com.evil.example/i/api/graphql/Q/TweetDetail",   // suffix spoof
    "http://x.com/i/api/graphql/QID/TweetDetail",               // downgraded
    "//x.com/i/api/graphql/QID/TweetDetail",                    // protocol-relative
    "/i/api/graphql/QID/TweetDetail",                           // origin-relative
    "garbage",
    null,
    undefined,
    42,
  ];
  for (const url of refused) {
    assert.equal(isProxyableRequest(url), false, `${url} must not be proxyable`);
  }
});

// MARK: - unwrapTweet

test("unwrapTweet: unwraps visibility-wrapped tweets, drops tombstones", () => {
  assert.equal(unwrapTweet({ __typename: "Tweet", legacy: {} }).legacy != null, true);
  const inner = { __typename: "Tweet", legacy: {} };
  assert.equal(unwrapTweet({ __typename: "TweetWithVisibilityResults", tweet: inner }), inner);
  assert.equal(unwrapTweet({ __typename: "TweetTombstone" }), null);
  assert.equal(unwrapTweet(null), null);
});

// MARK: - stampGroup (the JS↔Swift post-grouping contract, [090] 5A/16A)

/** A bare item in the shape stampGroup expects — just the provenance it rewrites. */
const groupItem = (extra = {}) => ({
  provenance: { originalURL: "https://x.com/a/status/1", rawMetadata: { kept: true, ...extra } },
});

test("stampGroup: writes one shared permalink and a 0-based running index", () => {
  const items = stampGroup([groupItem(), groupItem(), groupItem()], {
    permalink: "https://x.com/head/status/9",
  });
  assert.deepEqual([...new Set(items.map((i) => i.provenance.originalURL))],
    ["https://x.com/head/status/9"]);
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.carouselIndex), [0, 1, 2]);
  // Everything else the caller put in rawMetadata survives the stamp.
  for (const item of items) assert.equal(item.provenance.rawMetadata.kept, true);
});

test("stampGroup: startIndex continues a running sequence across groups (one pass)", () => {
  // Exactly how mapThread stamps a thread: each tweet's items are a group, and the index
  // carries forward, so a 2-media tweet followed by a 1-media tweet reads 0,1,2 — not
  // 0,1,0. Doing it with startIndex is what avoids a second rewriting pass.
  const first = stampGroup([groupItem(), groupItem()], { permalink: "P", startIndex: 0 });
  const second = stampGroup([groupItem()], { permalink: "P", startIndex: first.length });
  assert.deepEqual([...first, ...second].map((i) => i.provenance.rawMetadata.carouselIndex),
    [0, 1, 2]);
});

test("stampGroup: extraMetadata merges into every item; no permalink leaves it alone", () => {
  const items = stampGroup([groupItem(), groupItem()], { extraMetadata: { threadId: "7" } });
  for (const item of items) {
    assert.equal(item.provenance.rawMetadata.threadId, "7");
    assert.equal(item.provenance.originalURL, "https://x.com/a/status/1"); // untouched
  }
  assert.deepEqual(stampGroup([], { permalink: "P" }), []);
});

// MARK: - mapTweet

test("mapTweet: a video tweet → one item keyed by the MEDIA, poster + best MP4", () => {
  const items = mapTweet(videoTweet, { host: "x.com" });
  assert.equal(items.length, 1);
  const item = items[0];
  // The MEDIA's key, not the tweet's (310): one tweet can now yield several items,
  // and the engine's skip key ([P14]) has to be per-asset or they'd collide.
  assert.equal(item.sourceId, "REDACTED");
  assert.equal(item.provenance.rawMetadata.tweetId, "1000000000000000034");
  assert.equal(item.mediaUrl, "https://pbs.twimg.com/media/SAMPLE24.jpg?name=orig"); // the poster
  assert.equal(item.mediaUrlFallback, "https://pbs.twimg.com/media/SAMPLE24.jpg");
  assert.equal(item.provenance.rawMetadata.kind, "video");
  // highest-bitrate progressive MP4 from the response (no syndication call needed).
  assert.equal(item.provenance.rawMetadata.videoUrl,
    "https://video.twimg.com/amplify_video/1031/vid/720x1280/SAMPLE31.mp4?tag=12");
  // A tweet's FIRST item carries its tweet identity: the descriptor names THIS tweet,
  // its text and its whole media list, so the app stores it as a tweet (dedup on the
  // tweet id, text into search_text) while still downloading the picture.
  assert.equal(item.content.kind, "tweet");
  assert.equal(item.content.payload.tweet.tweetID, "1000000000000000034");
  assert.equal(item.content.payload.tweet.text, "Sample text");
  assert.equal(item.content.payload.tweet.authorHandle, "@sampleuser");
  assert.equal(item.provenance.title, "Sample text");            // the text survives on the source
  assert.equal(item.provenance.authorHandle, "@sampleuser");
  assert.equal(item.provenance.originalURL, "https://x.com/sampleuser/status/1000000000000000034");
});

test("mapTweet: a multi-photo tweet → ONE ITEM PER PHOTO, all sharing the permalink", () => {
  const items = mapTweet(photoTweet, { host: "x.com" });
  // 310: three photos, three assets — each downloaded, where only the first used to be.
  // This fixture tweet ALSO quotes a 3-photo tweet, so the merge rule appends those
  // three after its own; the first three are what the tweet itself carries.
  assert.equal(items.length, 6);
  assert.deepEqual(items.slice(0, 3).map((i) => i.sourceId), [
    "REDACTED", "REDACTED", "REDACTED",
  ]);
  for (const [index, item] of items.entries()) {
    assert.match(item.mediaUrl, /\?name=orig$/);                 // each at original resolution
    assert.equal(item.provenance.rawMetadata.kind, "photo");
    assert.equal(item.provenance.rawMetadata.videoUrl, null);
    assert.equal(item.provenance.rawMetadata.tweetId, "1000000000000000171");
    // The post-grouping index — what opens the tweet in ITS order, not the feed's.
    assert.equal(item.provenance.rawMetadata.carouselIndex, index);
  }
  // EXACTLY ONE descriptor, on the first item. A tweet capture dedups on
  // `(kind, tweetID)`, so a second item claiming the same tweet id would be deduped
  // away server-side and its photo deleted as an orphan blob — the six-photo fan-out
  // would silently become one.
  assert.equal(items.filter((i) => i.content).length, 1);
  assert.equal(items[0].content.payload.tweet.tweetID, "1000000000000000171");
  // …and that descriptor lists the tweet's WHOLE media set, not just its own picture.
  assert.equal(items[0].content.payload.tweet.media.length, 6);
  // The SHARED permalink is the grouping key: all six collapse to one tile.
  const permalinks = new Set(items.map((i) => i.provenance.originalURL));
  assert.equal(permalinks.size, 1);
  // The grouping key is stated separately from the permalink, because the app rewrites
  // a tweet capture's originalURL to its canonical form and would otherwise split the
  // first item out of its own post.
  const groupKeys = new Set(items.map((i) => i.provenance.rawMetadata.postGroupKey));
  assert.deepEqual([...groupKeys], ["https://x.com/sampleuser/status/1000000000000000171"]);
  // Distinct media, not the same photo repeated.
  assert.equal(new Set(items.map((i) => i.mediaUrl)).size, 6);
});

test("mapTweet: a quote merges BOTH media sets — own first, borrowed keys namespaced", () => {
  const quote = {
    __typename: "Tweet", rest_id: "10",
    core: { user_results: { result: { core: { screen_name: "q", name: "Q" } } } },
    legacy: {
      full_text: "my take",
      extended_entities: { media: [
        { media_key: "own", media_url_https: "https://pbs.twimg.com/media/OWN.jpg", type: "photo" },
      ] },
      quoted_status_result: { result: { __typename: "Tweet", rest_id: "11",
        core: { user_results: { result: { core: { screen_name: "orig", name: "Orig" } } } },
        legacy: {
          full_text: "the original point",
          extended_entities: { media: [
            { media_key: "q1", media_url_https: "https://pbs.twimg.com/media/QUOTED.jpg", type: "photo" },
          ] },
        } } },
    },
  };
  const items = mapTweet(quote, { host: "x.com" });
  assert.equal(items.length, 2);                    // both halves, not just the quoter's
  assert.match(items[0].mediaUrl, /OWN\.jpg/);      // the quoter's own comes first
  assert.match(items[1].mediaUrl, /QUOTED\.jpg/);
  // The BORROWED key is scoped to the quoting tweet: reused verbatim it would collide
  // with a direct save of tweet 11 and strand whichever the engine swept second.
  assert.deepEqual(items.map((i) => i.sourceId), ["own", "10:q1"]);
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.carouselIndex), [0, 1]);
  // One permalink — the quoter's, which is what was bookmarked — so they group as one post.
  assert.equal(new Set(items.map((i) => i.provenance.originalURL)).size, 1);
  assert.equal(items[0].provenance.originalURL, "https://x.com/q/status/10");
  // Both texts, quoter first.
  assert.equal(items[0].provenance.title, "my take\n\n↩ @orig: the original point");
});

test("mapTweet: a BARE quote of a video captures the QUOTED video (own media empty)", () => {
  // The fixture's 3rd tweet is a quote with no media of its own, quoting a video —
  // exactly the case where the substance is the quoted media.
  const items = mapTweet(textTweet, { host: "x.com" });
  assert.equal(items.length, 1);
  const item = items[0];
  // The quoted media's key, NAMESPACED by the quoting tweet so it can't collide with
  // a direct save of the tweet it was borrowed from.
  assert.equal(item.sourceId, "1000000000000000212:REDACTED");
  assert.equal(item.provenance.rawMetadata.tweetId, "1000000000000000212"); // the quote's own id
  assert.equal(item.provenance.rawMetadata.kind, "video");
  assert.match(item.mediaUrl, /SAMPLE203\.jpg\?name=orig$/);     // the quoted video's poster
  assert.equal(item.provenance.rawMetadata.videoUrl,             // the quoted video's MP4 (opt-in downloads it)
    "https://video.twimg.com/amplify_video/1208/vid/720x1280/SAMPLE208.mp4?tag=12");
  // The permalink is the QUOTER's — what you bookmarked — so the borrowed media
  // files under the quote rather than under the tweet it came from.
  assert.equal(item.provenance.originalURL, "https://x.com/sampleuser/status/1000000000000000212");
  // Both halves of the quote — the quoter's words, then the byline + text it quotes.
  // (The fixture is sanitized, so both texts read "Sample text".)
  assert.equal(item.provenance.title, "Sample text\n\n↩ @sampleuser: Sample text");
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
  assert.equal(item.sourceId, "3_abc");                         // the ORIGINAL media's key → dedups w/ a direct save
  assert.equal(item.provenance.rawMetadata.tweetId, "1000000000000000034"); // the original's id, not 9999
  assert.equal(item.provenance.authorHandle, "@origauthor");    // original author, not the reposter
  assert.equal(item.provenance.originalURL, "https://x.com/origauthor/status/1000000000000000034");
  assert.equal(item.provenance.title, "original tweet text");
  assert.match(item.mediaUrl, /ORIG\.jpg\?name=orig$/);         // the original's media, saved
  // Unwrapping used to lose the reposter entirely. A plain repost adds no words of its
  // own (its full_text is only the "RT @…" wrapper), so the handle IS what it adds.
  assert.equal(item.provenance.rawMetadata.repostedBy, "@reposter");
});

test("mapTweet: a NON-repost carries no repostedBy key at all", () => {
  // Written only when there is one, so an ordinary tweet's stored metadata is
  // byte-for-byte what it was before reposts were tracked.
  const plain = {
    __typename: "Tweet", rest_id: "42",
    core: { user_results: { result: { core: { screen_name: "u", name: "U" } } } },
    legacy: { full_text: "mine" },
  };
  const raw = mapTweet(plain, { host: "x.com" })[0].provenance.rawMetadata;
  assert.equal("repostedBy" in raw, false);
});

test("mapTweet: a repost OF a quote keeps the reposter AND merges the quoted half", () => {
  // Both rules at once — the repost unwraps first, so the quote read below is the
  // ORIGINAL's quote, not the retweet wrapper's.
  const repostOfQuote = {
    __typename: "Tweet", rest_id: "9999",
    core: { user_results: { result: { core: { screen_name: "reposter", name: "Reposter" } } } },
    legacy: { full_text: "RT @q: my take", retweeted_status_result: { result: {
      __typename: "Tweet", rest_id: "10",
      core: { user_results: { result: { core: { screen_name: "q", name: "Q" } } } },
      legacy: {
        full_text: "my take",
        quoted_status_result: { result: { __typename: "Tweet", rest_id: "11",
          core: { user_results: { result: { core: { screen_name: "orig", name: "Orig" } } } },
          legacy: { full_text: "the original point", extended_entities: { media: [
            { media_key: "q1", media_url_https: "https://pbs.twimg.com/media/Q.jpg", type: "photo" },
          ] } } } },
      },
    } } },
  };
  const items = mapTweet(repostOfQuote, { host: "x.com" });
  assert.equal(items.length, 1);
  assert.equal(items[0].sourceId, "10:q1");                     // namespaced by the QUOTER (10), not the retweet (9999)
  assert.equal(items[0].provenance.rawMetadata.repostedBy, "@reposter");
  assert.equal(items[0].provenance.originalURL, "https://x.com/q/status/10");
  assert.equal(items[0].provenance.title, "my take\n\n↩ @orig: the original point");
});

test("mapTweet: a text-only quote of a text-only tweet → one card carrying both texts", () => {
  const quote = {
    __typename: "Tweet", rest_id: "20",
    core: { user_results: { result: { core: { screen_name: "q", name: "Q" } } } },
    legacy: { full_text: "agreed", quoted_status_result: { result: {
      __typename: "Tweet", rest_id: "21",
      core: { user_results: { result: { core: { screen_name: "orig", name: "Orig" } } } },
      legacy: { full_text: "a claim" },
    } } },
  };
  const item = mapTweet(quote, { host: "x.com" })[0];
  assert.equal(item.mediaUrl, null);
  assert.equal(item.provenance.rawMetadata.kind, "text");
  // The card's own payload text carries the pair too, not just the source title —
  // it is what the app renders in `TweetCardTile`.
  assert.equal(item.content.payload.tweet.text, "agreed\n\n↩ @orig: a claim");
});

// MARK: - combineQuoteText / tweetText

test("combineQuoteText: quoter first, quoted below; degrades cleanly", () => {
  assert.equal(combineQuoteText("mine", "@them", "theirs"), "mine\n\n↩ @them: theirs");
  // A BARE quote (no words of its own) → the quoted block alone, which IS the substance.
  assert.equal(combineQuoteText(null, "@them", "theirs"), "↩ @them: theirs");
  // Nothing quoted → the quoter's text, untouched (the non-quote path).
  assert.equal(combineQuoteText("mine", null, null), "mine");
  assert.equal(combineQuoteText(null, null, null), null);
  // A quoted tweet whose author couldn't be read still contributes its text.
  assert.equal(combineQuoteText("mine", null, "theirs"), "mine\n\n↩ theirs");
});

test("tweetText: prefers the note_tweet body over a TRUNCATED full_text", () => {
  const long = {
    legacy: { full_text: "the first 280 chars…" },
    note_tweet: { note_tweet_results: { result: { text: "the whole long-form body" } } },
  };
  assert.equal(tweetText(long), "the whole long-form body");
  assert.equal(tweetText({ legacy: { full_text: "short" } }), "short");
  assert.equal(tweetText({}), null);
});

test("mapTweet: a media entry with NO poster is dropped, not emitted unfetchable", () => {
  const mixed = {
    __typename: "Tweet", rest_id: "77",
    core: { user_results: { result: { core: { screen_name: "u", name: "U" } } } },
    legacy: { full_text: "two shown, one broken", extended_entities: { media: [
      { media_key: "a", media_url_https: "https://pbs.twimg.com/media/A.jpg", type: "photo" },
      { media_key: "broken", type: "photo" },                    // no poster → nothing to fetch
      { media_key: "c", media_url_https: "https://pbs.twimg.com/media/C.jpg", type: "photo" },
    ] } },
  };
  const items = mapTweet(mixed, { host: "x.com" });
  assert.deepEqual(items.map((i) => i.sourceId), ["a", "c"]);
  // The index is over the EMITTED items, so the grouping order has no hole in it.
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.carouselIndex), [0, 1]);
});

test("mapTweet: media with no key at all falls back to a per-tweet index key", () => {
  // A response shape missing both `media_key` and `id_str` must still dedup WITHIN
  // the tweet — one shared key would make the engine skip every sibling as seen.
  const keyless = {
    __typename: "Tweet", rest_id: "88",
    core: { user_results: { result: { core: { screen_name: "u", name: "U" } } } },
    legacy: { extended_entities: { media: [
      { media_url_https: "https://pbs.twimg.com/media/A.jpg", type: "photo" },
      { media_url_https: "https://pbs.twimg.com/media/B.jpg", type: "photo" },
    ] } },
  };
  assert.deepEqual(mapTweet(keyless, { host: "x.com" }).map((i) => i.sourceId), ["88-0", "88-1"]);
});

// MARK: - parseTimelinePage

test("parseTimelinePage: yields one item per MEDIA, keyed by the media key", () => {
  const { items, bottomCursor, tweetCount } = parseTimelinePage(bookmarks, { host: "x.com" });

  assert.equal(tweetCount, 3);                     // three tweet ENTRIES, still

  assert.equal(bottomCursor, "Sample text");       // the Bottom cursor's value

  // Eight items from three tweets: the video (1) + the photo tweet's own 3 AND the 3
  // it quotes + the bare quote's borrowed video (1). Every quoted media is merged in
  // — not only a bare quote's — and each borrowed key is namespaced by its quoter.
  assert.deepEqual(items.map((i) => i.sourceId), [
    "REDACTED",
    "REDACTED", "REDACTED", "REDACTED",
    "1000000000000000171:REDACTED",
    "1000000000000000171:REDACTED",
    "1000000000000000171:REDACTED",
    "1000000000000000212:REDACTED",
  ]);
  // The photo tweet's six (its own three plus the three it quotes) share one
  // permalink, so the app collapses them to a single tile.
  const byPermalink = new Map();
  for (const item of items) {
    const url = item.provenance.originalURL;
    byPermalink.set(url, (byPermalink.get(url) || 0) + 1);
  }
  assert.equal(byPermalink.size, 3);                              // three posts
  assert.deepEqual([...byPermalink.values()].sort(), [1, 1, 6]);  // one of them has 6 members

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
