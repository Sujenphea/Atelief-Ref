// Atelier Capture — the X TweetDetail client ([090] 2A: the request/expansion half).
//
// Bundle discovery, queryId scraping, request building, the features-drift repair, and
// the expander that drives them over a swept page. `fetchThread` and the expander run
// against a fake fetch that reproduces X's real failure shapes (a features 400, a 429, a
// throw) — the conversation WALK they call into is pure and tested next door in
// twitter-thread.test.js.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  apiBundleURLs, scrapeQueryId, buildTweetDetailURL, missingFeatures, withFeatures,
  fetchThread, featuresFromURL, resolveQueryId, createThreadExpander,
  TWEET_DETAIL_OP, MAX_FEATURE_RETRIES,
} from "../src/twitter-detail-client.js";
import { mapTweet } from "../src/bulk-twitter.js";
import { isAllowedBundleHost } from "../src/media-hosts.js";
import { tweet, conversation } from "./fixtures/x-conversation.js";

// MARK: - queryId discovery

test("apiBundleURLs: collects X's own bundles, ranked, deduped; ignores other hosts", () => {
  const doc = { querySelectorAll: () => [
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/main.abc.js" : null) },
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.def123.js" : null) },
    { getAttribute: (a) => (a === "href" ? "https://abs.twimg.com/responsive-web/client-web-legacy/api.ghi.js" : null) },
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.def123.js" : null) },
    { getAttribute: () => "https://example.com/api.other.js" },   // not an X bundle
  ] };
  // The api.* pair rank first (and keep document order between them); main.* follows
  // rather than being discarded — it is where X actually keeps the table now.
  assert.deepEqual(apiBundleURLs(doc), [
    "https://abs.twimg.com/responsive-web/client-web/api.def123.js",
    "https://abs.twimg.com/responsive-web/client-web-legacy/api.ghi.js",
    "https://abs.twimg.com/responsive-web/client-web/main.abc.js",
  ]);
});

test("apiBundleURLs: finds the table's CURRENT home — X stopped shipping api.*.js", () => {
  // The exact script tags x.com served on 2026-08-13, verbatim. There is no api.*.js at
  // all any more, and the operation→queryId table is in main.*.js — so the old
  // api-only match returned [], resolveQueryId returned null, and thread expansion was
  // silently off on every sweep. This pins the real page against that regression.
  const live = [
    "https://abs.twimg.com/responsive-web/client-web/Chirp-Bold.ebb56aba.woff2",
    "https://abs.twimg.com/responsive-web/client-web/vendor.85e3918a.js",
    "https://abs.twimg.com/responsive-web/client-web/i18n/en.a0d1faaa.js",
    "https://abs.twimg.com/responsive-web/client-web/main.6ad8b08a.js",
    "https://abs.twimg.com/responsive-web/client-web/icon-svg.ea5ff4aa.svg",
  ];
  const doc = { querySelectorAll: () => live.map((src) => ({ getAttribute: (a) => (a === "src" ? src : null) })) };
  const urls = apiBundleURLs(doc);

  assert.ok(urls.includes("https://abs.twimg.com/responsive-web/client-web/main.6ad8b08a.js"),
    "main.*.js carries the table today and must be reachable");
  // main.* outranks the other bundles, so the common case is still one fetch.
  assert.equal(urls[0], "https://abs.twimg.com/responsive-web/client-web/main.6ad8b08a.js");
  // Non-JS assets are still excluded.
  assert.ok(urls.every((url) => url.endsWith(".js")));
});

test("apiBundleURLs: ranks api.* first, then main.*, then any other bundle", () => {
  // Ranking is what keeps the net wide without paying for it: resolveQueryId stops at the
  // first hit, so the likely carrier is fetched first and the tail is only a fallback.
  const order = [
    "https://abs.twimg.com/responsive-web/client-web/vendor.1.js",
    "https://abs.twimg.com/responsive-web/client-web/main.2.js",
    "https://abs.twimg.com/responsive-web/client-web-legacy/api.3.js",
  ];
  const doc = { querySelectorAll: () => order.map((src) => ({ getAttribute: (a) => (a === "src" ? src : null) })) };
  assert.deepEqual(apiBundleURLs(doc), [
    "https://abs.twimg.com/responsive-web/client-web-legacy/api.3.js",
    "https://abs.twimg.com/responsive-web/client-web/main.2.js",
    "https://abs.twimg.com/responsive-web/client-web/vendor.1.js",
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

test("scrapeQueryId: non-bundle input yields null rather than a bogus id ([090] 12A)", () => {
  // Every one of these is something the SW can plausibly hand back INSTEAD of a bundle:
  // X serving an error/consent page, a rate-limited empty body, a truncated download.
  // Each must read as "no id", because a wrong id 404s and looks exactly like a rotation
  // — the failure that would send someone hunting for a queryId change that never happened.
  const notBundles = [
    "<!DOCTYPE html><html><head><title>Error</title></head><body>Try again</body></html>",
    "",
    "   \n\t  ",
    `{"errors":[{"message":"Rate limit exceeded"}]}`,
    `{queryId:"AbC-123",operationName:"TweetDe`,          // truncated mid-token
    `{queryId:"AbC-123",operationName:`,                  // truncated before the name
    `queryId:"AbC-123"`,                                  // an id with no operation at all
    `operationName:"TweetDetail"`,                        // an operation with no id
    null,
    undefined,
    12345,
    {},
  ];
  for (const source of notBundles) {
    assert.equal(scrapeQueryId(source), null, `${JSON.stringify(source)} must not yield an id`);
  }
});

test("scrapeQueryId: tolerates the whitespace a build's formatting can introduce", () => {
  assert.equal(scrapeQueryId(`{ queryId : "SPACED" , operationName : "TweetDetail" }`), "SPACED");
  assert.equal(scrapeQueryId(`{operationName:  "TweetDetail",\n  queryId:  "WRAPPED"}`), "WRAPPED");
});

test("resolveQueryId: an error page from every bundle turns expansion off, quietly", async () => {
  // The composed failure: bundle discovery works, the fetches succeed, and what comes
  // back is X's error page. The caller must get null — not a throw, and not an id.
  const doc = { querySelectorAll: () => [
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.1.js" : null) },
    { getAttribute: (a) => (a === "src" ? "https://abs.twimg.com/responsive-web/client-web/api.2.js" : null) },
  ] };
  const lines = [];
  const queryId = await resolveQueryId({
    doc,
    fetchBundle: async () => "<html><body>Something went wrong</body></html>",
    log: (...parts) => lines.push(parts.join(" ")),
  });
  assert.equal(queryId, null);
  assert.match(lines.join(" "), /queryId/, "the operator is told why expansion is off");
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
  const result = await fetchThread("1", { queryId: "QID", features: { f: true }, fetchImpl: impl });
  assert.deepEqual(result.tweets.map((t) => t.rest_id), ["1", "2"]);
  assert.equal(result.status, 200);
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
  const result = await fetchThread("1", { queryId: "QID", features: {}, fetchImpl: impl });
  assert.equal(result.tweets.length, 1);
  assert.equal(calls.length, 2);
  // The retry carries the flag the server named — this is what keeps a features
  // drift from needing a code change.
  assert.deepEqual(JSON.parse(new URL(calls[1]).searchParams.get("features")), { new_flag: true });
});

test("fetchThread: gives up at EXACTLY MAX_FEATURE_RETRIES if the server keeps naming features", async () => {
  const featuresError = { status: 400, body: { errors: [{ message:
    "The following features cannot be null: a" }] } };
  // More responses queued than the bound allows — the bound, not the queue, must stop it.
  const { impl, calls } = fakeFetch(Array.from({ length: 10 }, () => featuresError));
  const result = await fetchThread("1", { queryId: "QID", fetchImpl: impl });
  assert.deepEqual(result.tweets, []);
  // One initial attempt + MAX_FEATURE_RETRIES repairs. Asserted exactly (not `<=`): the
  // whole point of the bound is that a server stuck in this state can't be a loop.
  assert.equal(calls.length, MAX_FEATURE_RETRIES + 1);
  assert.equal(result.status, 400, "the last status is reported, not masked as a throw");
});

test("fetchThread: a rate-limit / throw / missing queryId all degrade to no expansion", async () => {
  // Every failure here must mean "save the one tweet we already have" — never a halt.
  // The STATUS still comes back, because the caller's breaker acts on it ([090] 4A).
  const rateLimited = fakeFetch([{ status: 429, body: { errors: [{ message: "Rate limit exceeded" }] } }]);
  assert.deepEqual(await fetchThread("1", { queryId: "QID", fetchImpl: rateLimited.impl }),
    { tweets: [], status: 429 });

  const thrower = async () => { throw new Error("network down"); };
  assert.deepEqual(await fetchThread("1", { queryId: "QID", fetchImpl: thrower }),
    { tweets: [], status: 0 });          // 0 = never reached the server

  // No queryId (the scrape failed / X moved its bundle) → not even a request.
  const unused = fakeFetch([]);
  assert.deepEqual(await fetchThread("1", { queryId: null, fetchImpl: unused.impl }),
    { tweets: [], status: 0 });
  assert.equal(unused.calls.length, 0);
});

test("fetchThread: a 200 conversation with nothing to expand is NOT a failure", async () => {
  // The distinction the breaker leans on: a protected/withheld conversation answers 200
  // with no focal tweet. Zero tweets, but the request worked — counting it as a failure
  // would trip expansion off on three private bookmarks in a row.
  const { impl } = fakeFetch([{ status: 200, body: conversation([tweet({ id: "999" })]) }]);
  assert.deepEqual(await fetchThread("1", { queryId: "QID", fetchImpl: impl }),
    { tweets: [], status: 200 });
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

function expanderFor(chainBody, {
  probeRoots = false, credentials = { queryId: "QID", features: {} },
  status = 200, respond = null, ...options
} = {}) {
  const calls = [];
  const paces = [];
  const logs = [];
  const expand = createThreadExpander({
    resolveCredentials: async () => credentials,
    probeRoots,
    sleep: async (ms) => { paces.push(ms); },       // injected: no real waiting in tests
    random: () => 0.5,
    log: (...parts) => logs.push(parts.join(" ")),
    fetchImpl: async (url) => {
      calls.push(url);
      // `respond` lets a test vary the answer per call (a 429 partway through a sweep).
      const answer = respond ? respond(calls.length - 1, url) : { status, body: chainBody };
      if (answer.throws) throw new Error(answer.throws);
      return { status: answer.status, json: async () => answer.body };
    },
    ...options,
  });
  return { expand, calls, paces, logs };
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

test("createThreadExpander: an unavailable resolve is logged with ITS OWN reason", async () => {
  // A stale MAIN-world hook turned expansion off for every sweep, and the single
  // catch-all message blamed the X bundle — the one part that was working. Whatever the
  // resolver says about itself has to reach the log verbatim, or the next silent
  // expansion-off is just as unreadable as this one was.
  const logFor = async (resolveCredentials) => {
    const lines = [];
    const expand = createThreadExpander({
      resolveCredentials,
      log: (...parts) => lines.push(parts.join(" ")),
      fetchImpl: async () => { throw new Error("should not be reached"); },
    });
    const swept = itemsFor(tweet({ id: "2", replyTo: "1" }));
    assert.deepEqual(await expand(swept), swept, "unavailable credentials leave items alone");
    return lines.join("\n");
  };

  const noAuth = await logFor(async () => ({ reason: "the hook has not handed over auth" }));
  assert.match(noAuth, /has not handed over auth/);
  assert.doesNotMatch(noAuth, /queryId/, "the auth failure must not be blamed on the bundle");

  const noQueryId = await logFor(async () => ({ reason: "no TweetDetail queryId in any bundle" }));
  assert.match(noQueryId, /no TweetDetail queryId/);

  // A resolver that throws, and a bare `null` from one that names nothing, both still log.
  assert.match(await logFor(async () => { throw new Error("boom"); }), /threw: Error: boom/);
  assert.match(await logFor(async () => null), /thread expansion off/);
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

// MARK: - the circuit breaker ([090] 4A)

/** A page of N distinct threaded tweets, each its own conversation — so an expander that
 * keeps going spends one request per tweet. */
function threadedPage(count, from = 0) {
  const items = [];
  for (let i = 0; i < count; i += 1) {
    const id = String(2000 + from + i);
    const t = tweet({ id, text: `t${id}`, replyTo: String(1000 + from + i) });
    t.legacy.conversation_id_str = `conv-${id}`;    // distinct conversations → no cache hits
    items.push(...mapTweet(t, { host: "x.com" }));
  }
  return items;
}

test("createThreadExpander: a 429 trips the breaker — no further requests all sweep", async () => {
  const chain = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  const { expand, calls, logs } = expanderFor(chain, {
    // First read is fine, second is rate-limited, and any read after that would be the bug.
    respond: (n) => (n === 1
      ? { status: 429, body: { errors: [{ message: "Rate limit exceeded" }] } }
      : { status: 200, body: chain }),
  });

  const page = threadedPage(10);
  const out = await expand(page);
  assert.equal(calls.length, 2, "stopped at the rate-limit instead of asking 8 more times");
  // The sweep still yields every tweet on the page — expansion is a bonus, never a blocker.
  assert.equal(new Set(out.map((i) => i.provenance.rawMetadata.tweetId)).size >= 10, true);

  // And it stays off for the REST of the sweep, not just the rest of the page.
  await expand(threadedPage(5, 100));
  assert.equal(calls.length, 2);
  assert.equal(logs.filter((line) => /expansion OFF/.test(line)).length, 1, "logged once");
});

test("createThreadExpander: N consecutive failures trip the breaker; a good read clears the run", async () => {
  const chain = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  // fail, fail, SUCCEED (run reset), then fail three in a row → trips on the 6th read.
  const script = [
    { status: 500, body: {} },
    { throws: "network down" },
    { status: 200, body: chain },
    { status: 500, body: {} },
    { status: 500, body: {} },
    { status: 500, body: {} },
  ];
  const { expand, calls, logs } = expanderFor(chain, {
    respond: (n) => script[n] || { status: 200, body: chain },
  });

  await expand(threadedPage(12));
  assert.equal(calls.length, 6, "two failures then a success did NOT trip it; three in a row did");
  assert.equal(logs.filter((line) => /expansion OFF/.test(line)).length, 1);
});

test("createThreadExpander: an empty-but-successful conversation never trips the breaker", async () => {
  // A protected/withheld conversation answers 200 with no focal tweet. Common enough that
  // treating it as a failure would switch expansion off on a run of private bookmarks.
  const empty = conversation([tweet({ id: "999" })]);
  const { expand, calls, logs } = expanderFor(empty);
  await expand(threadedPage(6));
  assert.equal(calls.length, 6, "kept trying — nothing here is broken");
  assert.deepEqual(logs.filter((line) => /expansion OFF/.test(line)), []);
});

// MARK: - the bounded chain cache ([090] 13A)

test("createThreadExpander: the chain cache is LRU-bounded, keeping the recent ones", async () => {
  const chain = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  const { expand, calls } = expanderFor(chain, { cacheLimit: 3 });

  await expand(threadedPage(4));                 // conversations 2000..2003 → 4 reads
  assert.equal(calls.length, 4);

  // The three most recent are still cached; the oldest was evicted and must re-fetch.
  await expand(threadedPage(3, 1));              // 2001, 2002, 2003 — all hits
  assert.equal(calls.length, 4, "recent conversations still answer from the cache");

  await expand(threadedPage(1, 0));              // 2000 — evicted, so one more read
  assert.equal(calls.length, 5);
});

test("createThreadExpander: a cache hit re-dates its entry (LRU, not first-in-first-out)", async () => {
  const chain = conversation([tweet({ id: "1" }), tweet({ id: "2", replyTo: "1" })]);
  const { expand, calls } = expanderFor(chain, { cacheLimit: 2 });

  await expand(threadedPage(2));                 // cache: 2000, 2001
  assert.equal(calls.length, 2);
  await expand(threadedPage(1, 0));              // touch 2000 → it becomes the newest
  assert.equal(calls.length, 2);
  await expand(threadedPage(1, 2));              // insert 2002 → evicts 2001, not 2000
  assert.equal(calls.length, 3);

  await expand(threadedPage(1, 0));              // 2000 survived the eviction
  assert.equal(calls.length, 3);
  await expand(threadedPage(1, 1));              // 2001 did not
  assert.equal(calls.length, 4);
});
