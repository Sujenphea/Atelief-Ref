// Atelier Capture — X thread expansion, end to end ([090] 11A).
//
// Every piece of thread expansion is unit-tested, and until now nothing exercised them
// TOGETHER. The seam is unusually long for this codebase and crosses a world boundary
// twice, so the unit tests each hold one end of a rope nobody had pulled:
//
//   MAIN-world hook (real hook-core.js, injected as a classic script)
//     → postMessage → the controller's proxy client (real hook-proxy.js)
//     → the expander → the conversation walk → mapThread
//     → the push→pull source → the sweep engine → a recording relay
//
// So these drive a fake page that yields a THREADED tweet, answer the TweetDetail call
// with a conversation, and assert what actually reaches the relay is the whole thread
// under one permalink — plus the load-bearing negative: when expansion blows up, the
// sweep still saves what you bookmarked.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { createTwitterSource } from "../src/twitter-source.js";
import { createThreadExpander } from "../src/twitter-detail-client.js";
import { createHookProxyFetch } from "../src/hook-proxy.js";
import { runSweep, OUTCOMES } from "../src/bulk-engine.js";
import {
  HOOK_PROXY_REQUEST_SOURCE, HOOK_PROXY_REPLY_SOURCE, TIMELINE_MESSAGE_SOURCE,
} from "../src/bulk-messages.js";
import { tweet, conversation } from "./fixtures/x-conversation.js";

// The REAL MAIN-world hook, loaded the way Chrome injects it (classic script, no export).
const coreSrc = readFileSync(new URL("../src/hook-core.js", import.meta.url), "utf8");
const loadHookCore = () => new Function(
  "window", `${coreSrc}\nreturn installResponseHook;`)({});

const ORIGIN = "https://x.com";
const TIMELINE_URL = `${ORIGIN}/i/api/graphql/q1/Bookmarks?variables=%7B%7D&features=${
  encodeURIComponent(JSON.stringify({ inherited_flag: true }))}`;
const isTimeline = (url) => /\/i\/api\/graphql\/[^/]+\/Bookmarks/.test(String(url));
const isTweetDetail = (url) =>
  typeof url === "string" && url.startsWith(`${ORIGIN}/i/api/graphql/`) &&
  new URL(url).pathname.endsWith("/TweetDetail");

const BEARER = "Bearer integration-secret";
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/** A timeline page carrying one tweet, in the shape the parser walks. */
const timelinePage = (tweets) => ({ data: { bookmark_timeline_v2: { timeline: { instructions: [{
  type: "TimelineAddEntries",
  entries: [
    ...tweets.map((t) => ({
      entryId: `tweet-${t.rest_id}`,
      content: { entryType: "TimelineTimelineItem", itemContent: { tweet_results: { result: t } } },
    })),
    { content: { entryType: "TimelineTimelineCursor", cursorType: "Bottom", value: "C1" } },
  ],
}] } } } });

/**
 * A fake page: ONE window object shared by the MAIN-world hook and the ISOLATED-world
 * controller, since that is exactly what they share in production — `postMessage` on the
 * page's window is the only channel between them, and the whole security design of 3A
 * turns on what does and doesn't travel over it.
 */
function fakePage({ conversationBody, detailStatus = 200, onDetail = null }) {
  const listeners = [];
  const win = {
    location: { origin: ORIGIN, href: `${ORIGIN}/i/bookmarks` },
    detailCalls: [],
    seen: [],                                   // every message that crossed the boundary
    addEventListener: (type, fn) => { if (type === "message") listeners.push(fn); },
    removeEventListener: (type, fn) => {
      const i = listeners.indexOf(fn);
      if (i >= 0) listeners.splice(i, 1);
    },
    postMessage: (data) => {
      win.seen.push(data);
      for (const fn of [...listeners]) fn({ source: win, data });
    },
    // The page's own fetch, which the hook wraps. Answers the timeline and, for the
    // credentialled follow-up the hook makes, the conversation.
    fetch: async (url, init = {}) => {
      if (isTweetDetail(url)) {
        win.detailCalls.push({ url, init });
        if (onDetail) onDetail(win.detailCalls.length - 1);
        return { status: detailStatus, json: async () => conversationBody };
      }
      const body = win.__timelineBody;
      return { status: 200, clone: () => ({ json: async () => body }), json: async () => body };
    },
  };
  return win;
}

/** Install the real hook on the page and wire the controller's source + expander to it,
 * exactly as buildTwitterDriver does. Returns everything a test needs to assert on. */
function wirePage(win, { probeRoots = false } = {}) {
  const installResponseHook = loadHookCore();
  installResponseHook({
    target: win,
    isMatch: isTimeline,
    headerAllowlist: ["authorization", "x-csrf-token"],
    proxy: {
      requestSource: HOOK_PROXY_REQUEST_SOURCE,
      replySource: HOOK_PROXY_REPLY_SOURCE,
      isAllowed: isTweetDetail,
    },
    post: (message) => win.postMessage({ source: TIMELINE_MESSAGE_SOURCE, ...message }, ORIGIN),
  });

  const proxy = createHookProxyFetch({ win });
  let harvested = null;
  const source = createTwitterSource({
    scope: "bookmarks", sleep: () => Promise.resolve(), maxIdleRounds: 2,
    scroll: () => {},                            // pages are fed explicitly per test
    expandItems: createThreadExpander({
      resolveCredentials: async () => harvested,
      probeRoots,
      fetchImpl: proxy.proxyFetch,
      sleep: () => Promise.resolve(),            // no real pacing wait in a test
      random: () => 0,
    }),
  });

  win.addEventListener("message", (event) => {
    if (event.source !== win) return;
    const data = event.data;
    if (!data || data.source !== TIMELINE_MESSAGE_SOURCE) return;
    if (data.hasAuth) harvested = { queryId: "DETAIL_QID", features: { inherited_flag: true } };
    source.onResponse(data.json, data.url);
  });

  return { source, proxy };
}

/** Drive the page's own timeline request — what primes the hook with credentials AND
 * delivers the page. */
async function loadTimeline(win, body) {
  win.__timelineBody = body;
  await win.fetch(TIMELINE_URL, {
    headers: { authorization: BEARER, "x-csrf-token": "csrf", cookie: "session=secret" },
  });
  await tick();
}

const engineOpts = {
  sleep: () => Promise.resolve(), random: () => 0,
  config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
};
const recordingRelay = () => {
  const relayed = [];
  return {
    relayed,
    relay: async (item) => { relayed.push(item); return { outcome: OUTCOMES.ingested }; },
  };
};

// MARK: - the happy path, all the way through

test("thread seam: a bookmarked mid-thread tweet ingests as the WHOLE thread, one post", async () => {
  const thread = [
    tweet({ id: "500", text: "one" }),
    tweet({ id: "501", text: "two", replyTo: "500" }),
    tweet({ id: "502", text: "three", replyTo: "501" }),
  ];
  const win = fakePage({ conversationBody: conversation(thread) });
  const { source } = wirePage(win);

  // You bookmarked the MIDDLE tweet — the timeline hands over that one and nothing else.
  await loadTimeline(win, timelinePage([tweet({ id: "501", text: "two", replyTo: "500" })]));
  source.onResponse(timelinePage([]), TIMELINE_URL);      // 0-tweet page ends the feed

  const { relay, relayed } = recordingRelay();
  const result = await runSweep(source, {}, { relay, ...engineOpts });

  assert.equal(result.status, "complete");
  // All three tweets reached the relay, in reading order — not just the one swept.
  assert.deepEqual(relayed.map((i) => i.provenance.rawMetadata.tweetId), ["500", "501", "502"]);
  // Under ONE permalink (the head's), which is what collapses them to a single tile...
  assert.deepEqual([...new Set(relayed.map((i) => i.provenance.originalURL))],
    [`${ORIGIN}/author/status/500`]);
  // ...opening in the order the thread was written.
  assert.deepEqual(relayed.map((i) => i.provenance.rawMetadata.carouselIndex), [0, 1, 2]);
  for (const item of relayed) assert.equal(item.provenance.rawMetadata.threadId, "500");

  // Exactly one conversation read for the whole thing.
  assert.equal(win.detailCalls.length, 1);
});

test("thread seam: the token is spent on the request but never crosses the boundary", async () => {
  const win = fakePage({
    conversationBody: conversation([
      tweet({ id: "500" }), tweet({ id: "501", replyTo: "500" }),
    ]),
  });
  const { source } = wirePage(win);
  await loadTimeline(win, timelinePage([tweet({ id: "501", replyTo: "500" })]));
  source.onResponse(timelinePage([]), TIMELINE_URL);
  await runSweep(source, {}, { relay: recordingRelay().relay, ...engineOpts });

  // The follow-up DID carry the page's credentials — expansion only works because of it.
  assert.equal(win.detailCalls.length, 1);
  assert.equal(win.detailCalls[0].init.headers.authorization, BEARER);
  assert.equal(win.detailCalls[0].init.credentials, "include");

  // And not one message on the page's shared bus contained them. This is the invariant
  // 3A exists for, asserted at the only place it can actually be observed: the wire.
  const wire = JSON.stringify(win.seen);
  assert.ok(!wire.includes(BEARER), "the bearer token crossed the message boundary");
  assert.ok(!wire.includes("session=secret"), "the session cookie crossed the message boundary");
  assert.ok(!wire.includes("csrf"), "the csrf token crossed the message boundary");
});

test("thread seam: the features blob is INHERITED from the page's own request", async () => {
  const win = fakePage({
    conversationBody: conversation([
      tweet({ id: "500" }), tweet({ id: "501", replyTo: "500" }),
    ]),
  });
  const { source } = wirePage(win);
  await loadTimeline(win, timelinePage([tweet({ id: "501", replyTo: "500" })]));
  source.onResponse(timelinePage([]), TIMELINE_URL);
  await runSweep(source, {}, { relay: recordingRelay().relay, ...engineOpts });

  const asked = new URL(win.detailCalls[0].url);
  assert.deepEqual(JSON.parse(asked.searchParams.get("features")), { inherited_flag: true });
  assert.equal(JSON.parse(asked.searchParams.get("variables")).focalTweetId, "501");
});

// MARK: - expansion is a bonus, never a blocker

test("thread seam: a throwing expander degrades to the raw page — the sweep still saves it", async () => {
  // The load-bearing property of the whole feature, previously only asserted at the unit
  // level. `expandItems` is the one place in the pull path that runs caller-supplied async
  // code; if a throw there could kill a sweep, every bookmark after it would be lost.
  const source = createTwitterSource({
    scope: "bookmarks", sleep: () => Promise.resolve(), maxIdleRounds: 2, scroll: () => {},
    expandItems: async () => { throw new Error("expansion exploded"); },
  });
  source.onResponse(timelinePage([tweet({ id: "501", replyTo: "500" })]), TIMELINE_URL);
  source.onResponse(timelinePage([]), TIMELINE_URL);

  const { relay, relayed } = recordingRelay();
  const result = await runSweep(source, {}, { relay, ...engineOpts });

  assert.equal(result.status, "complete", "a broken expander must not halt the sweep");
  assert.deepEqual(relayed.map((i) => i.provenance.rawMetadata.tweetId), ["501"]);
});

test("thread seam: a refused proxy request leaves the tweet saved, unexpanded", async () => {
  // The proxy's url gate says no (a queryId that resolved to something off-shape). The
  // expander gets a rejection where it expected a body — and the bookmark still lands.
  const win = fakePage({ conversationBody: conversation([tweet({ id: "500" })]) });
  const installResponseHook = loadHookCore();
  installResponseHook({
    target: win,
    isMatch: isTimeline,
    headerAllowlist: ["authorization"],
    proxy: {
      requestSource: HOOK_PROXY_REQUEST_SOURCE,
      replySource: HOOK_PROXY_REPLY_SOURCE,
      isAllowed: () => false,                    // nothing is proxyable
    },
    post: (message) => win.postMessage({ source: TIMELINE_MESSAGE_SOURCE, ...message }, ORIGIN),
  });
  const proxy = createHookProxyFetch({ win });
  let harvested = null;
  const source = createTwitterSource({
    scope: "bookmarks", sleep: () => Promise.resolve(), maxIdleRounds: 2, scroll: () => {},
    expandItems: createThreadExpander({
      resolveCredentials: async () => harvested,
      fetchImpl: proxy.proxyFetch,
      sleep: () => Promise.resolve(), random: () => 0,
    }),
  });
  win.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== win || !data || data.source !== TIMELINE_MESSAGE_SOURCE) return;
    if (data.hasAuth) harvested = { queryId: "DETAIL_QID", features: {} };
    source.onResponse(data.json, data.url);
  });

  await loadTimeline(win, timelinePage([tweet({ id: "501", replyTo: "500" })]));
  source.onResponse(timelinePage([]), TIMELINE_URL);

  const { relay, relayed } = recordingRelay();
  const result = await runSweep(source, {}, { relay, ...engineOpts });

  assert.equal(result.status, "complete");
  assert.equal(win.detailCalls.length, 0, "the refused url was never fetched");
  assert.deepEqual(relayed.map((i) => i.provenance.rawMetadata.tweetId), ["501"]);
});

test("thread seam: a rate-limited conversation read stops expanding but not sweeping", async () => {
  // 4A at full depth: X answers 429, and the sweep must go quiet on TweetDetail while
  // still ingesting every remaining bookmark.
  const win = fakePage({
    conversationBody: { errors: [{ message: "Rate limit exceeded" }] }, detailStatus: 429,
  });
  const { source } = wirePage(win);

  // Three bookmarks from three DIFFERENT threads — otherwise the conversation cache, not
  // the breaker, is what holds the request count down, and the test proves nothing.
  const separateThreads = ["501", "601", "701"].map((id) => {
    const t = tweet({ id, replyTo: String(Number(id) - 1) });
    t.legacy.conversation_id_str = `conv-${id}`;
    return t;
  });
  await loadTimeline(win, timelinePage(separateThreads));
  source.onResponse(timelinePage([]), TIMELINE_URL);

  const { relay, relayed } = recordingRelay();
  const result = await runSweep(source, {}, { relay, ...engineOpts });

  assert.equal(result.status, "complete");
  assert.equal(win.detailCalls.length, 1, "the breaker tripped on the first 429");
  assert.deepEqual(relayed.map((i) => i.provenance.rawMetadata.tweetId), ["501", "601", "701"]);
});
