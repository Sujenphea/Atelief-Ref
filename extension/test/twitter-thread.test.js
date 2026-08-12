// Atelier Capture — X self-thread expansion tests.
//
// Everything here except `fetchThread` is pure, so the whole expansion path is
// exercised without a browser or a network: bundle discovery, queryId scraping,
// request building, the features-drift repair, the reply-chain walk, and the
// re-stamping that makes a thread group as one post. `fetchThread` runs against a
// fake fetch that reproduces X's real failure shapes (a features 400, a 429, a throw).

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  apiBundleURLs, scrapeQueryId, buildTweetDetailURL, missingFeatures, withFeatures,
  collectConversationTweets, selfThreadChain, needsThreadExpansion, mapThread, fetchThread,
  featuresFromURL, resolveQueryId, createThreadExpander,
  TWEET_DETAIL_OP, MAX_FEATURE_RETRIES,
} from "../src/twitter-thread.js";
import { mapTweet } from "../src/bulk-twitter.js";
import { isAllowedBundleHost } from "../src/media-hosts.js";

// MARK: - fixtures

/** A minimal tweet result in the timeline/TweetDetail shape. */
function tweet({ id, author = "author", text = "t", replyTo = null, media = [], replyCount = 0 }) {
  return {
    __typename: "Tweet",
    rest_id: id,
    core: { user_results: { result: { core: { screen_name: author, name: author.toUpperCase() } } } },
    legacy: {
      full_text: text,
      conversation_id_str: "100",
      reply_count: replyCount,
      ...(replyTo ? { in_reply_to_status_id_str: replyTo } : {}),
      ...(media.length ? { extended_entities: { media } } : {}),
    },
  };
}

const photo = (key) => ({
  media_key: key, media_url_https: `https://pbs.twimg.com/media/${key}.jpg`, type: "photo",
});

/** A TweetDetail body: the focal tweet as a bare entry, the rest inside a conversation
 * MODULE — the two shapes the real response mixes. */
function conversation(tweets) {
  const [first, ...rest] = tweets;
  return {
    data: { threaded_conversation_with_injections_v2: { instructions: [{
      type: "TimelineAddEntries",
      entries: [
        { entryId: `tweet-${first.rest_id}`, content: {
          entryType: "TimelineTimelineItem",
          itemContent: { itemType: "TimelineTweet", tweet_results: { result: first } },
        } },
        { entryId: "conversationthread-999", content: {
          entryType: "TimelineTimelineModule",
          items: rest.map((t) => ({
            entryId: `conversationthread-999-tweet-${t.rest_id}`,
            item: { itemContent: { itemType: "TimelineTweet", tweet_results: { result: t } } },
          })),
        } },
      ],
    }] } },
  };
}

// MARK: - queryId discovery

test("apiBundleURLs: finds X's api bundle among the page's scripts, in order, deduped", () => {
  const doc = { querySelectorAll: () => [
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/main.abc.js" : null) },
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.def123.js" : null) },
    { getAttribute: (a) => (a === "href" ? "https://abs.twimg.com/responsive-web/client-web-legacy/api.ghi.js" : null) },
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.def123.js" : null) },
    { getAttribute: () => "https://example.com/api.other.js" },   // not an X bundle
  ] };
  assert.deepEqual(apiBundleURLs(doc), [
    "https://abs.twimg.com/responsive-web/client-web/api.def123.js",
    "https://abs.twimg.com/responsive-web/client-web-legacy/api.ghi.js",
  ]);
});

test("apiBundleURLs: a document with no scripts yields nothing rather than throwing", () => {
  assert.deepEqual(apiBundleURLs({}), []);
  assert.deepEqual(apiBundleURLs(null), []);
});

test("scrapeQueryId: reads the id in either minified key order", () => {
  const forward = `{queryId:"AbC-123_x",operationName:"TweetDetail",operationType:"query"}`;
  const backward = `{operationName:"TweetDetail",queryId:"ZyX-987"}`;
  assert.equal(scrapeQueryId(forward), "AbC-123_x");
  assert.equal(scrapeQueryId(backward), "ZyX-987");
});

test("scrapeQueryId: will not pair one operation's name with another's id", () => {
  // The whole risk of a loose regex: a queryId from a DIFFERENT op 404s and reads
  // exactly like a rotation, so the match must stay adjacent-keys-only.
  const bundle = `{queryId:"BOOKMARKS_ID",operationName:"Bookmarks"},{queryId:"DETAIL_ID",operationName:"TweetDetail"}`;
  assert.equal(scrapeQueryId(bundle), "DETAIL_ID");
  assert.equal(scrapeQueryId(bundle, "Bookmarks"), "BOOKMARKS_ID");
  assert.equal(scrapeQueryId(bundle, "NotPresent"), null);
  assert.equal(scrapeQueryId(null), null);
});

// MARK: - request building

test("buildTweetDetailURL: carries the queryId, focal id, inherited features and toggles", () => {
  const url = buildTweetDetailURL({
    queryId: "QID", focalTweetId: "123", features: { inherited_flag: true },
  });
  const parsed = new URL(url);
  assert.equal(parsed.pathname, `/i/api/graphql/QID/${TWEET_DETAIL_OP}`);
  assert.equal(JSON.parse(parsed.searchParams.get("variables")).focalTweetId, "123");
  // Never ingest an ad out of a conversation.
  assert.equal(JSON.parse(parsed.searchParams.get("variables")).includePromotedContent, false);
  // The features blob is the page's, passed through untouched — not a hardcoded set.
  assert.deepEqual(JSON.parse(parsed.searchParams.get("features")), { inherited_flag: true });
  assert.equal(JSON.parse(parsed.searchParams.get("fieldToggles")).withArticlePlainText, false);
});

test("buildTweetDetailURL: null without a queryId or a focal id (nothing to ask for)", () => {
  assert.equal(buildTweetDetailURL({ queryId: null, focalTweetId: "1" }), null);
  assert.equal(buildTweetDetailURL({ queryId: "Q", focalTweetId: null }), null);
});

test("missingFeatures / withFeatures: a features 400 names its own repair", () => {
  const body = { errors: [{ message:
    "The following features cannot be null: responsive_web_grok_enabled, articles_preview_enabled" }] };
  assert.deepEqual(missingFeatures(body), [
    "responsive_web_grok_enabled", "articles_preview_enabled",
  ]);
  assert.deepEqual(withFeatures({ a: true }, missingFeatures(body)), {
    a: true, responsive_web_grok_enabled: true, articles_preview_enabled: true,
  });
  // An unrelated error is not a features problem.
  assert.deepEqual(missingFeatures({ errors: [{ message: "Rate limit exceeded" }] }), []);
  assert.deepEqual(missingFeatures({}), []);
});

// MARK: - the conversation walk

test("collectConversationTweets: finds tweets in bare entries AND inside modules", () => {
  const body = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  assert.deepEqual(collectConversationTweets(body).map((t) => t.rest_id), ["1", "2"]);
});

test("selfThreadChain: from a MID-thread tweet, walks up to the head and down to the end", () => {
  const chain = [
    tweet({ id: "1", text: "one" }),
    tweet({ id: "2", text: "two", replyTo: "1" }),
    tweet({ id: "3", text: "three", replyTo: "2" }),
    tweet({ id: "4", text: "four", replyTo: "3" }),
  ];
  // Bookmarking the 3rd tweet must yield all four, in reading order.
  const result = selfThreadChain(conversation(chain), "3");
  assert.deepEqual(result.map((t) => t.rest_id), ["1", "2", "3", "4"]);
});

test("selfThreadChain: from the HEAD, walks down the whole thread", () => {
  const chain = [
    tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" }), tweet({ id: "3", replyTo: "2" }),
  ];
  assert.deepEqual(selfThreadChain(conversation(chain), "1").map((t) => t.rest_id), ["1", "2", "3"]);
});

test("selfThreadChain: excludes the author's replies TO COMMENTERS", () => {
  // The trap that filtering by author+conversation alone would fall into: `99` is the
  // author replying to a stranger's comment. Same author, same conversation, NOT the thread.
  const body = conversation([
    tweet({ id: "1", text: "one" }),
    tweet({ id: "2", text: "two", replyTo: "1" }),
    tweet({ id: "50", author: "stranger", text: "a comment", replyTo: "1" }),
    tweet({ id: "99", text: "thanks!", replyTo: "50" }),
  ]);
  assert.deepEqual(selfThreadChain(body, "1").map((t) => t.rest_id), ["1", "2"]);
});

test("selfThreadChain: stops walking UP at another author's tweet", () => {
  // The author replied to someone else and then threaded under their own reply. The
  // chain is theirs alone — the stranger's tweet is context, not part of the capture.
  const body = conversation([
    tweet({ id: "1", author: "stranger", text: "someone else's tweet" }),
    tweet({ id: "2", text: "my reply", replyTo: "1" }),
    tweet({ id: "3", text: "continued", replyTo: "2" }),
  ]);
  assert.deepEqual(selfThreadChain(body, "3").map((t) => t.rest_id), ["2", "3"]);
});

test("selfThreadChain: a branch resolves to the earliest continuation", () => {
  const body = conversation([
    tweet({ id: "1" }),
    tweet({ id: "300", replyTo: "1" }),   // the later aside
    tweet({ id: "200", replyTo: "1" }),   // the real continuation (earlier id)
  ]);
  assert.deepEqual(selfThreadChain(body, "1").map((t) => t.rest_id), ["1", "200"]);
});

test("selfThreadChain: a lone tweet is a chain of one; a missing focal tweet is empty", () => {
  assert.deepEqual(selfThreadChain(conversation([tweet({ id: "1" })]), "1").length, 1);
  // Protected / withheld conversation → the caller saves the tweet unexpanded.
  assert.deepEqual(selfThreadChain(conversation([tweet({ id: "1" })]), "404"), []);
  assert.deepEqual(selfThreadChain({}, "1"), []);
});

// MARK: - the expansion predicate

test("needsThreadExpansion: a reply is certain; a root only under probeRoots", () => {
  const reply = tweet({ id: "2", replyTo: "1" });
  const root = tweet({ id: "1", replyCount: 3 });
  const lonely = tweet({ id: "1", replyCount: 0 });

  assert.equal(needsThreadExpansion(reply), true);          // mid-thread by construction
  assert.equal(needsThreadExpansion(root), false);          // not knowable → no request spent
  assert.equal(needsThreadExpansion(root, { probeRoots: true }), true);
  // Even when probing, a root nobody replied to cannot have a continuation.
  assert.equal(needsThreadExpansion(lonely, { probeRoots: true }), false);
});

test("needsThreadExpansion: a self_thread marker counts even without a parent id", () => {
  const marked = tweet({ id: "5" });
  marked.legacy.self_thread = { id_str: "100" };
  assert.equal(needsThreadExpansion(marked), true);
});

// MARK: - chain → items

test("mapThread: the whole thread shares the HEAD's permalink and one running index", () => {
  const items = mapThread([
    tweet({ id: "1", text: "one", media: [photo("a"), photo("b")] }),
    tweet({ id: "2", text: "two", replyTo: "1", media: [photo("c")] }),
    tweet({ id: "3", text: "three", replyTo: "2" }),               // text-only → a card
  ], { host: "x.com" });

  assert.equal(items.length, 4);                                    // 2 photos + 1 photo + 1 card
  // ONE permalink across the thread — the grouping key that collapses it to a single tile.
  const permalinks = new Set(items.map((i) => i.provenance.originalURL));
  assert.deepEqual([...permalinks], ["https://x.com/author/status/1"]);
  // The index runs CONTINUOUSLY, so the tile opens in the order the thread was written
  // rather than restarting at 0 on each tweet.
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.carouselIndex), [0, 1, 2, 3]);
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.threadIndex), [0, 0, 1, 2]);
  // Each tweet stays individually identifiable under the shared permalink.
  assert.deepEqual(items.map((i) => i.provenance.rawMetadata.tweetId), ["1", "1", "2", "3"]);
  for (const item of items) assert.equal(item.provenance.rawMetadata.threadId, "1");
  // Per-media dedup keys survive the re-stamp — a collision would make the engine
  // skip every sibling as already-seen.
  assert.equal(new Set(items.map((i) => i.sourceId)).size, 4);
});

test("mapThread: an empty chain maps to nothing", () => {
  assert.deepEqual(mapThread([]), []);
  assert.deepEqual(mapThread(null), []);
});

// MARK: - fetchThread (the one impure piece)

/** A fake fetch that answers a queue of `{ status, body }` and records the URLs asked for. */
function fakeFetch(responses) {
  const calls = [];
  const impl = async (url) => {
    calls.push(url);
    const next = responses.shift() || { status: 200, body: {} };
    return { status: next.status, json: async () => next.body };
  };
  return { impl, calls };
}

test("fetchThread: returns the chain on a clean response", async () => {
  const body = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  const { impl, calls } = fakeFetch([{ status: 200, body }]);
  const chain = await fetchThread("1", { queryId: "QID", features: { f: true }, fetchImpl: impl });
  assert.deepEqual(chain.map((t) => t.rest_id), ["1", "2"]);
  assert.equal(calls.length, 1);
  assert.match(calls[0], /\/graphql\/QID\/TweetDetail\?/);
});

test("fetchThread: repairs a features 400 from the error message and retries", async () => {
  const body = conversation([tweet({ id: "1" })]);
  const { impl, calls } = fakeFetch([
    { status: 400, body: { errors: [{ message:
      "The following features cannot be null: new_flag" }] } },
    { status: 200, body },
  ]);
  const chain = await fetchThread("1", { queryId: "QID", features: {}, fetchImpl: impl });
  assert.equal(chain.length, 1);
  assert.equal(calls.length, 2);
  // The retry carries the flag the server named — this is what keeps a features
  // drift from needing a code change.
  assert.deepEqual(JSON.parse(new URL(calls[1]).searchParams.get("features")), { new_flag: true });
});

test("fetchThread: gives up (bounded) if the server keeps naming features", async () => {
  const featuresError = { status: 400, body: { errors: [{ message:
    "The following features cannot be null: a" }] } };
  const { impl, calls } = fakeFetch([featuresError, featuresError, featuresError, featuresError]);
  assert.deepEqual(await fetchThread("1", { queryId: "QID", fetchImpl: impl }), []);
  assert.equal(calls.length, MAX_FEATURE_RETRIES + 1);       // bounded, not a loop
});

test("fetchThread: a rate-limit / throw / missing queryId all degrade to no expansion", async () => {
  // Every failure here must mean "save the one tweet we already have" — never a halt.
  const rateLimited = fakeFetch([{ status: 429, body: { errors: [{ message: "Rate limit exceeded" }] } }]);
  assert.deepEqual(await fetchThread("1", { queryId: "QID", fetchImpl: rateLimited.impl }), []);

  const thrower = async () => { throw new Error("network down"); };
  assert.deepEqual(await fetchThread("1", { queryId: "QID", fetchImpl: thrower }), []);

  // No queryId (the scrape failed / X moved its bundle) → not even a request.
  const unused = fakeFetch([]);
  assert.deepEqual(await fetchThread("1", { queryId: null, fetchImpl: unused.impl }), []);
  assert.equal(unused.calls.length, 0);
});

// MARK: - credential inheritance

test("featuresFromURL: reads the blob the page sent, or null", () => {
  const url = "https://x.com/i/api/graphql/q/Bookmarks?variables=%7B%7D&features=" +
    encodeURIComponent(JSON.stringify({ some_flag: true, other: false }));
  assert.deepEqual(featuresFromURL(url), { some_flag: true, other: false });
  assert.equal(featuresFromURL("https://x.com/i/api/graphql/q/Bookmarks"), null);
  assert.equal(featuresFromURL("not a url"), null);
});

test("resolveQueryId: tries bundles in order and returns the first hit", async () => {
  const doc = { querySelectorAll: () => [
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.1.js" : null) },
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.2.js" : null) },
  ] };
  const asked = [];
  const queryId = await resolveQueryId({
    doc,
    fetchBundle: async (url) => {
      asked.push(url);
      return url.endsWith("api.2.js") ? `{operationName:"TweetDetail",queryId:"FOUND"}` : "nothing here";
    },
  });
  assert.equal(queryId, "FOUND");
  assert.equal(asked.length, 2);
});

test("resolveQueryId: a failing bundle fetch is skipped, not fatal", async () => {
  const doc = { querySelectorAll: () => [
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.1.js" : null) },
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.2.js" : null) },
  ] };
  const queryId = await resolveQueryId({
    doc,
    fetchBundle: async (url) => {
      if (url.endsWith("api.1.js")) throw new Error("blocked");
      return `{queryId:"OK",operationName:"TweetDetail"}`;
    },
  });
  assert.equal(queryId, "OK");
  // No bundles at all / no match → null, and the caller turns expansion off.
  assert.equal(await resolveQueryId({ doc: {}, fetchBundle: async () => "" }), null);
});

test("isAllowedBundleHost: only X's asset CDN, only https, no suffix spoof", () => {
  assert.equal(isAllowedBundleHost("https://abs.twimg.com/responsive-web/client-web/api.a.js"), true);
  assert.equal(isAllowedBundleHost("http://abs.twimg.com/x.js"), false);          // must be https
  assert.equal(isAllowedBundleHost("https://abs.twimg.com.evil.com/x.js"), false); // suffix spoof
  assert.equal(isAllowedBundleHost("https://pbs.twimg.com/x.js"), false);          // media CDN, not assets
  assert.equal(isAllowedBundleHost("http://127.0.0.1:47321/ingest"), false);       // never the app
  assert.equal(isAllowedBundleHost("garbage"), false);
});

// MARK: - the expander

/** Items as the sweep sees them: `mapTweet` output, hint attached. */
const itemsFor = (t) => mapTweet(t, { host: "x.com" });

function expanderFor(chainBody, { probeRoots = false, credentials = { queryId: "QID", features: {} } } = {}) {
  const calls = [];
  const paces = [];
  const expand = createThreadExpander({
    resolveCredentials: async () => credentials,
    probeRoots,
    sleep: async (ms) => { paces.push(ms); },       // injected: no real waiting in tests
    random: () => 0.5,
    fetchImpl: async (url) => {
      calls.push(url);
      return { status: 200, json: async () => chainBody };
    },
  });
  return { expand, calls, paces };
}

test("createThreadExpander: swaps a threaded tweet's items for the whole thread's", async () => {
  const chain = [tweet({ id: "1", text: "one" }), tweet({ id: "2", text: "two", replyTo: "1" })];
  const { expand, calls } = expanderFor(conversation(chain));

  const swept = itemsFor(tweet({ id: "2", text: "two", replyTo: "1" }));
  const out = await expand(swept);
  assert.equal(calls.length, 1);
  assert.deepEqual(out.map((i) => i.provenance.rawMetadata.tweetId), ["1", "2"]);
  // The whole thread files under the head's permalink → one tile.
  assert.deepEqual([...new Set(out.map((i) => i.provenance.originalURL))],
    ["https://x.com/author/status/1"]);
});

test("createThreadExpander: leaves an ordinary tweet untouched and spends no request", async () => {
  const { expand, calls } = expanderFor(conversation([tweet({ id: "1" })]));
  const swept = itemsFor(tweet({ id: "1", replyCount: 5 }));      // a ROOT — not knowable
  const out = await expand(swept);
  assert.deepEqual(out, swept);
  assert.equal(calls.length, 0);                                  // probing is off by default
});

test("createThreadExpander: probeRoots spends a request on a root that has replies", async () => {
  const chain = [tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })];
  const { expand, calls } = expanderFor(conversation(chain), { probeRoots: true });
  const out = await expand(itemsFor(tweet({ id: "1", replyCount: 4 })));
  assert.equal(calls.length, 1);
  assert.deepEqual(out.map((i) => i.provenance.rawMetadata.tweetId), ["1", "2"]);
});

test("createThreadExpander: fetches a conversation ONCE even when several of its tweets are swept", async () => {
  const chain = [
    tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" }), tweet({ id: "3", replyTo: "2" }),
  ];
  const { expand, calls } = expanderFor(conversation(chain));
  // Two tweets of the same thread bookmarked — the common case.
  const swept = [
    ...itemsFor(tweet({ id: "2", replyTo: "1" })),
    ...itemsFor(tweet({ id: "3", replyTo: "2" })),
  ];
  await expand(swept);
  assert.equal(calls.length, 1, "the conversation is cached across items in a sweep");
});

test("createThreadExpander: expanded items carry no hint, so they can never re-expand", async () => {
  const chain = [tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })];
  const { expand } = expanderFor(conversation(chain));
  const out = await expand(itemsFor(tweet({ id: "2", replyTo: "1" })));
  for (const item of out) assert.equal("threadHint" in item, false);
});

test("createThreadExpander: no credentials → the page passes through unexpanded", async () => {
  const chain = [tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })];
  const { expand, calls } = expanderFor(conversation(chain), { credentials: null });
  const swept = itemsFor(tweet({ id: "2", replyTo: "1" }));
  assert.deepEqual(await expand(swept), swept);
  assert.equal(calls.length, 0);
});

test("createThreadExpander: a chain of one keeps the original items", async () => {
  // The tweet is a reply to someone ELSE — a chain of one. Nothing to expand.
  const { expand } = expanderFor(conversation([tweet({ id: "2", replyTo: "1" })]));
  const swept = itemsFor(tweet({ id: "2", replyTo: "1" }));
  assert.deepEqual(await expand(swept), swept);
});

test("createThreadExpander: resolveCredentials is called at most once per sweep", async () => {
  let resolved = 0;
  const expand = createThreadExpander({
    resolveCredentials: async () => { resolved += 1; return null; },
    fetchImpl: async () => { throw new Error("should not be reached"); },
  });
  const swept = itemsFor(tweet({ id: "2", replyTo: "1" }));
  await expand(swept);
  await expand(swept);
  assert.equal(resolved, 1, "a failed resolve is cached — no per-page bundle re-scrape");
});

test("createThreadExpander: paces each conversation read, and a cache hit costs nothing", async () => {
  const chain = [
    tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" }), tweet({ id: "3", replyTo: "2" }),
  ];
  const { expand, calls, paces } = expanderFor(conversation(chain));
  await expand([
    ...itemsFor(tweet({ id: "2", replyTo: "1" })),
    ...itemsFor(tweet({ id: "3", replyTo: "2" })),
  ]);
  // Thread reads are a second request stream the engine's item pacing doesn't cover,
  // so each real fetch waits first — and the cached second lookup neither fetches
  // nor waits.
  assert.equal(calls.length, 1);
  assert.equal(paces.length, 1);
  assert.ok(paces[0] >= 1200, `expected a paced gap, got ${paces[0]}ms`);
});
