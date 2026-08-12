// Atelier Capture — X self-thread expansion (TweetDetail).
//
// A bookmarks timeline hands us ONE tweet. When that tweet is part of a thread the
// author wrote, the rest of the thread is nowhere in the response — it has to be
// asked for, and `TweetDetail` is the only op that returns a conversation.
//
// Nothing here is forged from constants, which is the whole difficulty:
//   · the `features` blob is INHERITED from a timeline request the page already made
//     (the same discipline the drift baseline records — "never hardcoded"), because a
//     features set that disagrees with the server is a 400, not a degraded response;
//   · the auth is the page's own, and it never comes near this module — the request
//     goes through the MAIN-world hook's proxy, which holds the headers itself
//     ([090] 3A, hook-proxy.js);
//   · only the `queryId` can't be inherited (TweetDetail has its own, and they rotate
//     every 2-4 weeks), so it is SCRAPED from X's own JS bundle at sweep time.
// When any of those is unavailable the expansion FAILS SOFT: the bookmarked tweet is
// saved on its own, exactly as it was before threads were expanded. A thread that
// doesn't expand is a smaller capture; a sweep that dies is a broken feature.
//
// A features mismatch is self-healing: X answers a missing/renamed flag with a 400
// whose message NAMES the flags it wanted, so `missingFeatures` reads them back and
// the caller retries with them defaulted on (bounded, twice) rather than needing a
// code change every time X adds a flag.
//
// The parsing is pure and fixture-tested; only `fetchThread` touches the network.

import { unwrapTweet, mapTweet, stampGroup } from "./bulk-twitter.js";
import { THREAD_PACING_MS, THREAD_PACING_JITTER_MS } from "./config.js";

/** The GraphQL operation that returns a conversation. */
export const TWEET_DETAIL_OP = "TweetDetail";

/** How many times to re-issue a request after X names missing feature flags. Two is
 * enough for a real drift (one round names them all); more would mask a genuine break. */
export const MAX_FEATURE_RETRIES = 2;

/** `fieldToggles` X sends with TweetDetail. Unlike `features` these are stable and
 * not echoed back in an error, so they're stated here; a wrong toggle degrades the
 * response rather than rejecting it. */
export const TWEET_DETAIL_FIELD_TOGGLES = Object.freeze({
  withArticleRichContentState: true,
  withArticlePlainText: false,
  withGrokAnalyze: false,
  withDisallowedReplyControls: false,
});

/** `variables` for a TweetDetail read. `focalTweetId` is filled per call. Promoted
 * content is off — a sweep must never ingest an ad. */
export const TWEET_DETAIL_VARIABLES = Object.freeze({
  referrer: "bookmarks",
  with_rux_injections: false,
  rankingMode: "Relevance",
  includePromotedContent: false,
  withCommunity: true,
  withQuickPromoteEligibilityTweetFields: false,
  withBirdwatchNotes: true,
  withVoice: true,
});

// MARK: - queryId discovery

/** Script/link URLs on the page that could be X's API bundle — the file that carries
 * the operation→queryId table. Matched loosely (the path shape has moved before:
 * `client-web`, `client-web-legacy`, hashed filenames) and returned in document order. */
export function apiBundleURLs(doc) {
  const urls = [];
  const push = (url) => {
    if (typeof url === "string" && /abs\.twimg\.com\/responsive-web\/.*\/api\.[^/]*\.js$/.test(url)) {
      if (!urls.includes(url)) urls.push(url);
    }
  };
  const nodes = typeof doc?.querySelectorAll === "function"
    ? doc.querySelectorAll("script[src], link[href]") : [];
  for (const node of nodes) {
    push(node.getAttribute ? node.getAttribute("src") : null);
    push(node.getAttribute ? node.getAttribute("href") : null);
  }
  return urls;
}

/**
 * The `queryId` X uses for `operation`, read out of a bundle's source, or null.
 *
 * The table is minified as object literals whose key ORDER is not stable across
 * builds, so both orders are tried: `queryId` before `operationName` and after. The
 * match is deliberately narrow (adjacent keys, no `.*` across the file) so it can't
 * pair one operation's name with another's id — a mismatched queryId would 404 and
 * look exactly like a rotation.
 */
export function scrapeQueryId(source, operation = TWEET_DETAIL_OP) {
  if (typeof source !== "string" || !operation) return null;
  const op = operation.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const forward = new RegExp(
    `queryId\\s*:\\s*"([^"]+)"\\s*,\\s*operationName\\s*:\\s*"${op}"`);
  const backward = new RegExp(
    `operationName\\s*:\\s*"${op}"\\s*,\\s*queryId\\s*:\\s*"([^"]+)"`);
  return (forward.exec(source) || backward.exec(source) || [])[1] || null;
}

/**
 * The `features` blob X sent on an intercepted request, JSON-parsed, or null.
 * Inheriting it (rather than stating a set here) is what keeps a features drift from
 * being a code change: whatever the live client is sending is what we send.
 */
export function featuresFromURL(url) {
  try {
    const raw = new URL(url).searchParams.get("features");
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * Resolve the TweetDetail `queryId` by reading X's own bundles, or null.
 *
 * `fetchBundle(url) => string|null` is injected because a content script cannot
 * fetch abs.twimg.com under the page's CORS — the service worker does it under
 * `host_permissions` (BULK.bundle) and hands back the text. Bundles are tried in
 * document order and the first hit wins.
 */
export async function resolveQueryId({ doc, fetchBundle, operation = TWEET_DETAIL_OP, log = () => {} }) {
  const urls = apiBundleURLs(doc);
  if (urls.length === 0) {
    log("no X api bundle on the page (path shape moved?)");
    return null;
  }
  for (const url of urls) {
    let source = null;
    try {
      source = await fetchBundle(url);
    } catch (error) {
      log("bundle fetch failed:", url, String(error));
      continue;
    }
    const queryId = scrapeQueryId(source, operation);
    if (queryId) return queryId;
  }
  log("no", operation, "queryId in any bundle (table shape moved?)");
  return null;
}

// MARK: - request building

/**
 * The TweetDetail request URL. `features` is the blob INHERITED from an intercepted
 * timeline request (an object, already JSON-parsed) — passing an empty/missing one
 * is allowed but will almost certainly 400, which the retry path then repairs from
 * the server's own error message.
 */
export function buildTweetDetailURL({
  queryId, focalTweetId, features = {}, host = "x.com",
  fieldToggles = TWEET_DETAIL_FIELD_TOGGLES,
}) {
  if (!queryId || !focalTweetId) return null;
  const variables = { ...TWEET_DETAIL_VARIABLES, focalTweetId: String(focalTweetId) };
  const params = new URLSearchParams({
    variables: JSON.stringify(variables),
    features: JSON.stringify(features || {}),
    fieldToggles: JSON.stringify(fieldToggles),
  });
  return `https://${host}/i/api/graphql/${queryId}/${TWEET_DETAIL_OP}?${params}`;
}

/**
 * Feature flags a GraphQL error body says were missing, or `[]`. X phrases it as
 * "The following features cannot be null: a, b, c" — reading the names back is what
 * makes a features drift self-repairing instead of a hard break.
 */
export function missingFeatures(body) {
  const errors = Array.isArray(body?.errors) ? body.errors : [];
  const names = new Set();
  for (const error of errors) {
    const match = /following features cannot be null:\s*([^"}]+)/i.exec(error?.message || "");
    if (!match) continue;
    for (const name of match[1].split(",")) {
      const clean = name.trim().replace(/[.\s]+$/, "");
      if (clean) names.add(clean);
    }
  }
  return [...names];
}

/** `features` with `names` defaulted to true — the repair for a 400 that named them. */
export function withFeatures(features, names) {
  const next = { ...(features || {}) };
  for (const name of names) next[name] = true;
  return next;
}

// MARK: - conversation → the author's own chain

/** Every `tweet_results.result` in a TweetDetail body, unwrapped, in document order.
 * Walks generically (entries carry tweets both directly and nested inside conversation
 * MODULES) so an entry-shape rename doesn't silently yield an empty conversation. */
export function collectConversationTweets(json, depth = 12) {
  const out = [];
  const seen = new Set();
  const walk = (node, level) => {
    if (!node || typeof node !== "object" || level < 0) return;
    if (Array.isArray(node)) {
      for (const value of node) walk(value, level - 1);
      return;
    }
    if (node.tweet_results && typeof node.tweet_results === "object") {
      const tweet = unwrapTweet(node.tweet_results.result);
      const id = tweet?.rest_id || tweet?.legacy?.id_str || null;
      if (tweet && id && !seen.has(id)) {
        seen.add(id);
        out.push(tweet);
      }
    }
    for (const value of Object.values(node)) walk(value, level - 1);
  };
  walk(json, depth);
  return out;
}

/** A tweet's author screen name (the `core` shape, `legacy` fallback), or null. */
function screenNameOf(tweet) {
  const user = tweet?.core?.user_results?.result || null;
  return user?.core?.screen_name || user?.legacy?.screen_name || null;
}

const idOf = (tweet) => tweet?.rest_id || tweet?.legacy?.id_str || null;
const parentIdOf = (tweet) => tweet?.legacy?.in_reply_to_status_id_str || null;

/** Ascending snowflake compare (ids exceed Number.MAX_SAFE_INTEGER, so BigInt), with
 * a lexical fallback for a non-numeric id rather than a throw. */
function compareIds(a, b) {
  try {
    const left = BigInt(a);
    const right = BigInt(b);
    return left < right ? -1 : left > right ? 1 : 0;
  } catch {
    return String(a).localeCompare(String(b));
  }
}

/**
 * The author's OWN chain through a conversation, in reading order, including the
 * focal tweet. Walks the reply links rather than filtering by author alone: in a
 * popular thread the author also replies TO COMMENTERS, and those replies share both
 * the author and the conversation id — sweeping them in would file someone else's
 * discussion under the thread. Following `in_reply_to_status_id_str` keeps only the
 * spine: up from the focal tweet to the thread's first tweet, then down its
 * continuations (earliest id wins when the author branched).
 *
 * Returns `[]` when the focal tweet isn't in the body (a protected/withheld
 * conversation), which the caller reads as "don't expand".
 *
 * `log` is called when a fork is discarded ([090] 7A). The heuristic is fine — real
 * self-threads almost never branch — but doing it SILENTLY is not: if a capture is ever
 * missing an arm of a thread, the only way to know that's what happened is a line saying
 * so at the moment it happened.
 */
export function selfThreadChain(json, focalTweetId, { log = () => {} } = {}) {
  const tweets = collectConversationTweets(json);
  const byId = new Map();
  for (const tweet of tweets) {
    const id = idOf(tweet);
    if (id) byId.set(id, tweet);
  }
  const focal = byId.get(String(focalTweetId));
  if (!focal) return [];

  const author = screenNameOf(focal);
  const sameAuthor = (tweet) => !!author && screenNameOf(tweet) === author;

  // A parent → its children index, built ONCE ([090] 15A). The walk below asks "who
  // replied to this?" at every step, and answering that by re-scanning every tweet each
  // time is quadratic on a popular conversation — which is exactly the conversation most
  // likely to be big. Buckets are pre-sorted so the walk's own choice is just "the first
  // one still eligible", and only the author's own replies are indexed at all, since the
  // spine is the only thing being walked.
  const childrenOf = new Map();
  for (const tweet of tweets) {
    if (!sameAuthor(tweet)) continue;
    const parentId = parentIdOf(tweet);
    if (!parentId) continue;
    if (!childrenOf.has(parentId)) childrenOf.set(parentId, []);
    childrenOf.get(parentId).push(tweet);
  }
  for (const children of childrenOf.values()) {
    children.sort((a, b) => compareIds(idOf(a), idOf(b)));
  }

  // Up: follow the reply links to the first tweet the author wrote in this chain.
  const ancestors = [];
  const walked = new Set([idOf(focal)]);
  let cursor = focal;
  while (true) {
    const parentId = parentIdOf(cursor);
    if (!parentId || walked.has(parentId)) break;
    const parent = byId.get(parentId);
    if (!parent || !sameAuthor(parent)) break;   // replying to someone else → chain starts here
    walked.add(parentId);
    ancestors.unshift(parent);
    cursor = parent;
  }

  // Down: each step is the author's own reply to the current tweet. A branch (the
  // author posted two replies to the same tweet) resolves to the earliest, which is
  // the continuation; the later one is an aside — reported, not silently dropped.
  const descendants = [];
  cursor = focal;
  while (true) {
    const currentId = idOf(cursor);
    const children = (childrenOf.get(currentId) || []).filter((tweet) => !walked.has(idOf(tweet)));
    const next = children[0];
    if (!next) break;
    if (children.length > 1) {
      log("thread forked under", currentId, "— keeping", idOf(next),
        "and dropping", children.slice(1).map(idOf).join(","));
    }
    walked.add(idOf(next));
    descendants.push(next);
    cursor = next;
  }

  return [...ancestors, focal, ...descendants];
}

/**
 * Whether a swept tweet is worth a TweetDetail call.
 *
 * A REPLY is certain: it names a parent, so it is mid-thread by construction and the
 * rest of the chain is missing. A ROOT is not knowable from the timeline alone — the
 * response says nothing about whether the author carried on underneath it — so
 * expanding those means PROBING, one request per bookmark, which `probeRoots` gates.
 * With probing off, bookmarking the first tweet of a thread saves that tweet only.
 */
export function needsThreadExpansion(tweet, { probeRoots = false } = {}) {
  const legacy = tweet?.legacy || {};
  if (legacy.in_reply_to_status_id_str) return true;
  if (legacy.self_thread && legacy.self_thread.id_str) return true;
  if (!probeRoots) return false;
  // A root with no replies at all cannot have a continuation — cheapest possible
  // screen, and it spares the request on the many bookmarks that are lone tweets.
  return Number(legacy.reply_count || 0) > 0;
}

// MARK: - the chain → BulkItems

/**
 * Map a self-thread chain to `BulkItem`s: every tweet mapped as usual, then re-stamped
 * so the whole thread reads as ONE post.
 *
 * Two fields are overridden, both via `stampGroup` — the same helper `mapTweet` uses for
 * a multi-media tweet, because a thread is that same grouping one level up ([090] 5A).
 * `originalURL` becomes the thread's FIRST tweet's permalink on every item — that shared
 * permalink is the app's post-grouping key (`PostGrouping.swift`), so a 5-tweet thread
 * collapses to a single tile instead of five loose ones. And `carouselIndex` runs
 * CONTINUOUSLY across the thread rather than restarting per tweet, so the tile opens 1→n
 * in the order the thread was written (a 2-image tweet 1 followed by a 1-image tweet 2
 * gives 0,1,2 — not 0,1,0); `startIndex` carries that running count from one tweet's
 * group to the next, so the whole thread is stamped in ONE pass ([090] 16A).
 *
 * Each tweet keeps its own `rawMetadata.tweetId`, so an individual tweet is still
 * identifiable after the group permalink is applied, and gains `threadId` (the first
 * tweet's id) plus `threadIndex` (its position in the chain, media of one tweet
 * sharing one index).
 */
export function mapThread(tweets, { host = "x.com", cursor = null } = {}) {
  if (!Array.isArray(tweets) || tweets.length === 0) return [];

  const perTweet = tweets.map((tweet) => mapTweet(tweet, { host, cursor }));
  const flat = perTweet.flat();
  if (flat.length === 0) return [];

  // The group permalink is the FIRST tweet's — the head of the thread, which is what a
  // reader means by "the thread". Fall back to the first item that produced one, so a
  // head that mapped to nothing (all media unusable) can't leave the group url null.
  const threadURL = perTweet.find((items) => items.length > 0)?.[0]?.provenance?.originalURL
    || flat[0].provenance.originalURL;
  const threadId = perTweet.find((items) => items.length > 0)?.[0]
    ?.provenance?.rawMetadata?.tweetId || null;

  let index = 0;
  perTweet.forEach((items, threadIndex) => {
    stampGroup(items, {
      permalink: threadURL,
      startIndex: index,
      extraMetadata: { threadId, threadIndex },
    });
    // Strip the expansion hint: these items ARE the expansion, and leaving it on
    // would let the expander walk them again (a request per tweet, every sweep).
    for (const item of items) delete item.threadHint;
    index += items.length;
  });

  return flat;
}

// MARK: - the expander (the seam the sweep pulls through)

/** Items belonging to one tweet, in order — the unit the expander decides about.
 * Grouped on `rawMetadata.tweetId` because a tweet has already fanned out per media
 * by the time items reach here. */
function groupByTweet(items) {
  const groups = [];
  let current = null;
  for (const item of items) {
    const id = item?.provenance?.rawMetadata?.tweetId || null;
    if (!current || current.tweetId !== id) {
      current = { tweetId: id, items: [], hint: item?.threadHint || null };
      groups.push(current);
    }
    current.items.push(item);
  }
  return groups;
}

/** Consecutive failed conversation reads before expansion gives up for the sweep. Three
 * is past coincidence — one slow request or one protected conversation is normal, three
 * in a row means something systemic (a rotation, a block, the network). */
export const MAX_CONSECUTIVE_THREAD_FAILURES = 3;

/** How many conversations to remember per sweep ([090] 13A). Same bounded-buffer
 * discipline as hook-core's replay buffer: an unbounded map on a long sweep is a slow
 * leak of whole conversation bodies. Small is enough — bookmarks from one thread arrive
 * ADJACENT in the feed, so nearly all the dedup value is in the most recent handful. */
export const CHAIN_CACHE_LIMIT = 50;

/**
 * Build the `expandItems` hook the X source runs over each page: swap a threaded
 * tweet's items for the whole thread's.
 *
 * `resolveCredentials` is async and called at most once per sweep (its result is
 * cached, including a failure — a bundle that won't yield a queryId won't yield one
 * on the next item either, and re-scraping per tweet would be a request storm).
 *
 * A conversation is fetched ONCE per sweep: bookmarking three tweets of the same
 * thread is common, and without the cache each would re-fetch the identical
 * conversation. The later ones reuse the chain, and the engine's dedup then skips the
 * items it has already ingested. The cache is LRU-bounded (`CHAIN_CACHE_LIMIT`).
 *
 * Failure is always "leave the items as they were" — the sweep's job is to save what
 * you bookmarked, and an unexpanded thread still does that.
 *
 * A CIRCUIT BREAKER bounds how long that stays true ([090] 4A). Failing soft per item is
 * right for one bad conversation and wrong for a rate-limit: swallowed individually, a
 * 429 would let the sweep keep firing TweetDetail at X for every remaining bookmark —
 * hundreds of refused requests, silently, which is both useless and the behaviour most
 * likely to escalate a rate-limit into a block. So the first 429, or
 * `MAX_CONSECUTIVE_THREAD_FAILURES` failures in a row, trips expansion off for the rest
 * of the sweep, logged ONCE. The sweep itself carries on and saves everything unexpanded.
 */
export function createThreadExpander({
  resolveCredentials, probeRoots = false, host = "x.com",
  fetchImpl = fetch, log = () => {},
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  random = Math.random,
  pacingMs = THREAD_PACING_MS,
  pacingJitterMs = THREAD_PACING_JITTER_MS,
  maxConsecutiveFailures = MAX_CONSECUTIVE_THREAD_FAILURES,
  cacheLimit = CHAIN_CACHE_LIMIT,
} = {}) {
  let credentials;                       // undefined = not yet resolved; null = unavailable
  let tripped = false;                   // the breaker — one-way, for the sweep's lifetime
  let consecutiveFailures = 0;
  const chainCache = new Map();          // conversation id → chain (or [] when it didn't expand)

  /** Gap before each conversation read. These are a SECOND request stream the engine's
   * item pacing doesn't cover (it paces relays to the local app; these go to X), so
   * they carry their own paced, jittered gap rather than bursting per page. Only a
   * real fetch waits — a cache hit costs nothing. */
  const pace = () => sleep(pacingMs + Math.floor(random() * pacingJitterMs));

  /** LRU read/write over `chainCache`. A `Map` iterates in insertion order, so
   * re-inserting on a hit keeps the oldest key first and eviction is just "drop it". */
  const cacheGet = (key) => {
    if (!chainCache.has(key)) return undefined;
    const chain = chainCache.get(key);
    chainCache.delete(key);
    chainCache.set(key, chain);
    return chain;
  };
  const cacheSet = (key, chain) => {
    chainCache.delete(key);
    chainCache.set(key, chain);
    if (chainCache.size > cacheLimit) chainCache.delete(chainCache.keys().next().value);
  };

  /** Record one conversation read's outcome; returns true once the breaker has tripped. */
  const noteOutcome = (status) => {
    if (status === 429) {
      tripped = true;
      log("thread expansion OFF for this sweep: X rate-limited the conversation read");
    } else if (status === 0 || status >= 400) {
      consecutiveFailures += 1;
      if (consecutiveFailures >= maxConsecutiveFailures) {
        tripped = true;
        log("thread expansion OFF for this sweep:", consecutiveFailures,
          "conversation reads failed in a row");
      }
    } else {
      consecutiveFailures = 0;           // a good read clears the run
    }
    return tripped;
  };

  return async function expandItems(items) {
    if (!Array.isArray(items) || items.length === 0) return items;
    if (tripped) return items;           // breaker open — not one more request this sweep
    const groups = groupByTweet(items);
    if (!groups.some((group) => group.hint && needsThreadExpansion(group.hint, { probeRoots }))) {
      return items;                      // nothing on this page is threaded — no work, no request
    }

    if (credentials === undefined) {
      try {
        credentials = (await resolveCredentials()) || null;
      } catch (error) {
        log("thread expansion unavailable:", String(error));
        credentials = null;
      }
      if (!credentials || !credentials.queryId) {
        log("thread expansion off: no TweetDetail queryId (X bundle moved?)");
        credentials = null;
      }
    }
    if (!credentials) return items;

    const out = [];
    for (const group of groups) {
      if (tripped || !group.tweetId || !group.hint ||
          !needsThreadExpansion(group.hint, { probeRoots })) {
        out.push(...group.items);
        continue;
      }
      const conversationId = group.hint?.legacy?.conversation_id_str || group.tweetId;
      let chain = cacheGet(conversationId);
      if (chain === undefined) {
        await pace();
        const result = await fetchThread(group.tweetId, { ...credentials, host, fetchImpl, log });
        chain = result.tweets;
        cacheSet(conversationId, chain);
        noteOutcome(result.status);
      }
      // A chain of one is just the tweet we already have — keep the original items
      // rather than re-mapping them to an identical set.
      if (chain.length > 1) {
        const expanded = mapThread(chain, { host, cursor: group.items[0]?.cursor ?? null });
        log("thread expanded:", group.tweetId, "→", chain.length, "tweets,", expanded.length, "items");
        out.push(...expanded);
      } else {
        out.push(...group.items);
      }
    }
    return out;
  };
}

// MARK: - the fetch

/**
 * Fetch `focalTweetId`'s conversation and return `{ tweets, status }` — the raw shapes
 * `mapTweet` consumes, plus what the server said. Never throws: every failure mode here
 * (rotation, rate-limit, a protected conversation) must degrade to "save the one tweet we
 * already have" rather than halt a sweep.
 *
 * `status` is reported rather than swallowed because the CALLER has to tell three
 * outcomes apart that all yield no tweets: a conversation that legitimately has none
 * (200), a request X refused (4xx/5xx), and one that never reached it at all (0). Only
 * the caller can act on that difference — a 429 means stop asking ([090] 4A), a 200 with
 * one tweet means this simply wasn't a thread.
 *
 * `features` is inherited from an intercepted request; a 400 naming missing flags is
 * retried with them on, bounded by `MAX_FEATURE_RETRIES`.
 *
 * `fetchImpl` is handed a url and NOTHING ELSE — no headers, no `credentials`. In
 * production it is the MAIN-world hook's proxy (hook-proxy.js), which owns the auth this
 * request rides on; this side of the boundary never sees a token, and the shape of this
 * call is what keeps that true rather than merely conventional.
 */
export async function fetchThread(focalTweetId, {
  queryId, features = {}, host = "x.com",
  fetchImpl = fetch, log = () => {},
} = {}) {
  const nothing = (status = 0) => ({ tweets: [], status });
  if (!queryId || !focalTweetId) return nothing();
  let currentFeatures = features;
  let status = 0;

  for (let attempt = 0; attempt <= MAX_FEATURE_RETRIES; attempt += 1) {
    const url = buildTweetDetailURL({ queryId, focalTweetId, features: currentFeatures, host });
    if (!url) return nothing();
    let body = null;
    try {
      const response = await fetchImpl(url);
      status = response.status;
      body = await response.json();
    } catch (error) {
      log("thread fetch failed:", String(error));
      return nothing();
    }

    const missing = missingFeatures(body);
    if (missing.length && attempt < MAX_FEATURE_RETRIES) {
      log("thread fetch: server asked for features", missing.join(","), "— retrying");
      currentFeatures = withFeatures(currentFeatures, missing);
      continue;
    }
    if (status >= 400) {
      log("thread fetch: HTTP", status, "— saving the tweet unexpanded");
      return nothing(status);
    }
    return { tweets: selfThreadChain(body, focalTweetId, { log }), status };
  }
  // Out of retries with the server still naming features: the last status is the useful
  // one (a 400 here is a real break, not a rate-limit).
  return nothing(status);
}
