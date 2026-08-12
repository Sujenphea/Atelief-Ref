// Atelier Capture — X conversation → the author's own thread (PURE).
//
// A bookmarks timeline hands us ONE tweet. When that tweet is part of a thread the
// author wrote, the rest of the thread is nowhere in the response — it has to be asked
// for, and `TweetDetail` is the only op that returns a conversation. Asking is
// twitter-detail-client.js's job. THIS file is what to do with the answer: walk a
// conversation body down to the author's own spine, and map that spine to the items the
// app groups into one post.
//
// Nothing here touches the network, the DOM, or a message boundary — it is a pair of
// total functions over a JSON body, which is why the whole thread feature can be
// fixture-tested without a browser. The split mirrors twitter-video.js: the shape logic
// is pure and testable, the I/O is a thin client beside it.

import { mapTweet, stampGroup, unwrapTweet } from "./bulk-twitter.js";

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

