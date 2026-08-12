// Atelier Capture — the X TweetDetail client (discovery, request, fetch, expansion).
//
// Everything the thread feature needs from the OUTSIDE world: find X's `queryId`, build
// the request, issue it, repair a features drift, and drive the per-page expansion. The
// shape logic it hands the answers to is pure and lives next door in twitter-thread.js.
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

import { mapThread, needsThreadExpansion, selfThreadChain } from "./twitter-thread.js";
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

/**
 * Bundle URLs on the page that could carry the operation→queryId table, best candidate
 * first.
 *
 * This used to match `api.*.js` ALONE, and X has since stopped shipping that file: as of
 * 2026-08-13 the table lives in `main.*.js`, so the narrow match found nothing,
 * `resolveQueryId` returned null, and thread expansion was silently off for every sweep.
 * A single filename was never a safe thing to depend on — the path shape has moved
 * before (`client-web`, `client-web-legacy`, hashed names), and the failure is invisible
 * because "no queryId" degrades to "this tweet wasn't a thread".
 *
 * So the net is now ANY `responsive-web` script bundle, RANKED rather than filtered:
 * historically-correct names first (`api.*`, then `main.*`), everything else after.
 * `resolveQueryId` stops at the first bundle that yields an id, so ranking is what keeps
 * the common case at one fetch while the tail keeps it working when X moves the table
 * again — which is the part that actually matters.
 */
export function apiBundleURLs(doc) {
  const urls = [];
  const push = (url) => {
    if (typeof url === "string" && /abs\.twimg\.com\/responsive-web\/.*\.js$/.test(url)) {
      if (!urls.includes(url)) urls.push(url);
    }
  };
  const nodes = typeof doc?.querySelectorAll === "function"
    ? doc.querySelectorAll("script[src], link[href]") : [];
  for (const node of nodes) {
    push(node.getAttribute ? node.getAttribute("src") : null);
    push(node.getAttribute ? node.getAttribute("href") : null);
  }
  // Rank, preserving document order inside each tier.
  const tier = (url) => {
    if (/\/api\.[^/]*\.js$/.test(url)) return 0;
    if (/\/main\.[^/]*\.js$/.test(url)) return 1;
    return 2;
  };
  return urls
    .map((url, index) => ({ url, index, tier: tier(url) }))
    .sort((a, b) => a.tier - b.tier || a.index - b.index)
    .map((entry) => entry.url);
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
