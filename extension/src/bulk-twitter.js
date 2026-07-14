// Atelier Capture — X / Twitter BulkSource parsing (Phase 5, [4A][9A][A2]).
//
// Unlike Pinterest (which we paginate ourselves), X's timeline requests are made BY
// THE PAGE as it auto-scrolls; a MAIN-world hook (twitter-hook.js) captures the
// `Bookmarks` / `BookmarkFolderTimeline` / `Likes` GraphQL RESPONSES and forwards them
// to the content script.
// This module is the PURE half: parse an intercepted timeline response into
// `BulkItem`s + the bottom cursor. The push→pull adapter that feeds these into the
// engine lives with the content-script loop (Phase 6); the parsers here are what
// [T9] pins against the committed fixture.
//
// A tweet maps to ONE `BulkItem` (003 · C3 bulk): a tweet is a single first-class
// content item, keyed by its `tweetId`, carrying its media as REFERENCES — not one
// asset per photo. `media[]` lists every top-level media (all up-to-4 photos, or the
// video/gif poster); the FIRST media is fetched as the item's card image. X never
// mixes photos and video in one tweet, so "first media" is unambiguous. A text-only
// tweet still maps (an item with no media → a media-less text card). A REPOST (retweet)
// is unwrapped to the ORIGINAL tweet, whose text + media are the real substance. But a
// QUOTE tweet's own text is the substance and the quoted media belongs to the quoted
// author, so quoted media is NOT read — only the (unwrapped) tweet's own.

import { makeProvenance, toOrigName } from "./extractors/base.js";
import { buildTweetPayload } from "./endpoint.js";
import { selectBestVideo } from "./twitter-video.js";

/** Unwrap a `tweet_results.result` to the underlying Tweet, or null for a
 * tombstone / unavailable / missing result. `TweetWithVisibilityResults` nests the
 * real tweet under `.tweet`. */
export function unwrapTweet(result) {
  if (!result) return null;
  if (result.__typename === "TweetWithVisibilityResults" && result.tweet) return result.tweet;
  if (result.__typename === "Tweet" || result.legacy) return result;
  return null;                       // TweetTombstone / unknown → skip
}

/** Resolve a REPOST (retweet) to the ORIGINAL tweet it carries. A retweet's own
 * `legacy.full_text` is only "RT @user…" and it holds NO media — the substance (text
 * + media) lives on `retweeted_status_result.result`. Returns the original (unwrapped)
 * for a repost, or the tweet itself otherwise, so a reposted tweet saves the original's
 * media/text and dedups against a direct save (same tweet id). A QUOTE tweet is NOT
 * unwrapped — its own text is the substance and the quoted media belongs to the quoted
 * author (kept out, per the mapper's rule). */
export function underlyingTweet(tweet) {
  const reposted =
    tweet?.legacy?.retweeted_status_result?.result ||
    tweet?.retweeted_status_result?.result || null;
  return unwrapTweet(reposted) || tweet;
}

/** Find the timeline `instructions` array across the operation shapes (Bookmarks
 * nests under `bookmark_timeline_v2`, a bookmark FOLDER under
 * `bookmark_collection_timeline`, Likes under `user.result.timeline_v2`), with a
 * bounded deep-search fallback so a wrapper rename doesn't silently yield nothing. */
export function findInstructions(json) {
  const data = json && json.data;
  const known =
    data?.bookmark_timeline_v2?.timeline ||
    data?.bookmark_timeline?.timeline ||
    data?.bookmark_collection_timeline?.timeline ||
    data?.user?.result?.timeline_v2?.timeline ||
    data?.user?.result?.timeline?.timeline ||
    null;
  if (known && Array.isArray(known.instructions)) return known.instructions;
  return deepFindInstructions(json, 6) || [];
}

/** First `instructions` array found within `depth` levels (drift resilience). */
function deepFindInstructions(node, depth) {
  if (!node || typeof node !== "object" || depth < 0) return null;
  if (Array.isArray(node.instructions)) return node.instructions;
  for (const value of Object.values(node)) {
    const found = deepFindInstructions(value, depth - 1);
    if (found) return found;
  }
  return null;
}

/** The tweet's own media list (extended_entities preferred — it carries all photos
 * of a multi-photo tweet and the full video_info; entities.media is the fallback). */
function tweetMedia(tweet) {
  const legacy = tweet.legacy || {};
  const ext = legacy.extended_entities && legacy.extended_entities.media;
  if (Array.isArray(ext)) return ext;
  const base = legacy.entities && legacy.entities.media;
  return Array.isArray(base) ? base : [];
}

/** The tweet's author handle (`@name`) + display name, from the newer `core` shape
 * with a `legacy` fallback. */
function tweetAuthor(tweet) {
  const user = tweet?.core?.user_results?.result || null;
  const core = user?.core || {};
  const legacy = user?.legacy || {};
  const screenName = core.screen_name || legacy.screen_name || null;
  return {
    handle: screenName ? `@${screenName}` : null,
    name: core.name || legacy.name || null,
    screenName,
  };
}

/**
 * Map one timeline tweet result to a single `BulkItem` (`[item]`), or `[]` for a
 * tombstone / no-id / empty tweet (no text AND no media — the app would reject it).
 * `host` sets the `originalURL` origin; `cursor` is threaded in by the caller (the
 * page's bottom cursor).
 *
 * The item carries a `content` descriptor (`kind: "tweet"` + payload with the tweet's
 * whole `media[]` reference list) so it ingests as a first-class tweet, and its
 * `mediaUrl` = the FIRST media (the card image the SW fetches). A video/gif tweet maps
 * its POSTER as the card and stashes the best progressive MP4 in `rawMetadata.videoUrl`
 * (already in the response — no syndication call). With the video opt-in ON the relay
 * passes that MP4 and `ingestOne` ingests a video asset (the content descriptor is then
 * ignored — no regression); OFF (default) the tweet lands with its poster card.
 */
export function mapTweet(result, { host = "x.com", cursor = null } = {}) {
  const outer = unwrapTweet(result);
  if (!outer) return [];
  // A repost carries its content on the original — read media/text/author/id from it,
  // so a reposted tweet saves the original's media (not an empty "RT @user…").
  const tweet = underlyingTweet(outer);

  const tweetId = tweet.rest_id || (tweet.legacy && tweet.legacy.id_str) || null;
  if (!tweetId) return [];

  const author = tweetAuthor(tweet);
  const legacy = tweet.legacy || {};
  const noteText = tweet.note_tweet?.note_tweet_results?.result?.text;
  const title = noteText || legacy.full_text || null;
  const originalURL = author.screenName
    ? `https://${host}/${author.screenName}/status/${tweetId}`
    : `https://${host}/i/status/${tweetId}`;

  // Walk the top-level media ONCE: collect every reference for payload.media[], pick the
  // first as the card image to fetch, and capture the first video's progressive MP4.
  const mediaUrls = [];
  let card = null;          // { mediaUrl, mediaUrlFallback } — the image the SW fetches
  let videoUrl = null;      // opt-in progressive MP4 (first video/gif media)
  let kind = "text";        // rawMetadata hint: the tweet's media kind (text if none)
  for (const media of tweetMedia(tweet)) {
    const poster = media.media_url_https || null;
    if (!poster) continue;
    const mediaUrl = toOrigName(poster, { addIfAbsent: true });
    mediaUrls.push(mediaUrl);
    if (!card) {
      card = { mediaUrl, mediaUrlFallback: mediaUrl !== poster ? poster : null };
      kind = media.type || "photo";
    }
    const isVideo = media.type === "video" || media.type === "animated_gif";
    if (isVideo && !videoUrl && media.video_info) {
      videoUrl = selectBestVideo({ video: media.video_info });
    }
  }

  const content = buildTweetPayload({
    tweetID: tweetId,
    mediaUrls,
    text: title,
    authorHandle: author.handle,
    authorName: author.name,
  });
  if (!content) return []; // no substance (no text AND no media) → skip

  const mediaUrl = card ? card.mediaUrl : null;
  const mediaUrlFallback = card ? card.mediaUrlFallback : null;
  return [{
    sourceId: tweetId,
    mediaUrl,
    mediaUrlFallback,
    cursor,
    content,
    provenance: makeProvenance({
      platform: "twitter",
      originalURL,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: author.handle,
      authorName: author.name,
      title,
      rawMetadata: { tweetId, kind, videoUrl },
    }),
  }];
}

/**
 * Parse one intercepted timeline response into `{ items, bottomCursor, tweetCount }` —
 * ONE item per substantive tweet (see `mapTweet`). `tweetCount` is the number of tweet
 * ENTRIES seen (incl. any dropped as empty) — the Phase-6 loop treats a page with
 * `tweetCount === 0` as the end of the timeline (X has no `-end-` sentinel; an exhausted
 * timeline simply stops returning tweets). Each item carries `bottomCursor` as its
 * checkpoint token (X resume leans on the engine's dedup-skip, since pagination is
 * scroll-driven and not cursor-injectable).
 */
export function parseTimelinePage(json, { host = "x.com" } = {}) {
  const items = [];
  let bottomCursor = null;
  let tweetCount = 0;

  for (const instruction of findInstructions(json)) {
    const entries = Array.isArray(instruction.entries) ? instruction.entries : [];
    for (const entry of entries) {
      const content = entry.content || {};
      if (content.entryType === "TimelineTimelineCursor") {
        if (content.cursorType === "Bottom") bottomCursor = content.value || null;
        continue;
      }
      if (content.entryType !== "TimelineTimelineItem") continue;
      const result = content.itemContent?.tweet_results?.result;
      const tweet = unwrapTweet(result);
      if (!tweet) continue;
      tweetCount += 1;
      for (const item of mapTweet(result, { host })) items.push(item);
    }
  }

  // Stamp the page's checkpoint token onto its items (mapTweet is cursor-agnostic).
  // Only on the BulkItem — NOT in provenance.rawMetadata, which the app stores.
  for (const item of items) item.cursor = bottomCursor;

  return { items, bottomCursor, tweetCount };
}

/**
 * Parse a Twitter GraphQL request URL into `{ op, variables }`, or null if it isn't a
 * GraphQL request. `op` is the operation name (`…/graphql/{queryId}/{Op}`); `variables`
 * is the `variables` query param JSON-PARSED (decision 6A) — `{}` when absent or
 * malformed. Parsing the structured params (rather than substring-matching the raw URL)
 * is robust to key ordering, whitespace and re-encoding.
 */
export function graphqlOp(url) {
  if (typeof url !== "string") return null;
  let parsed;
  try { parsed = new URL(url); } catch { return null; }
  const match = /\/graphql\/[^/]+\/([^/?]+)/.exec(parsed.pathname);
  if (!match) return null;
  let variables = {};
  const raw = parsed.searchParams.get("variables"); // URLSearchParams already decodes it
  if (raw) {
    try { variables = JSON.parse(raw); } catch { variables = {}; }
  }
  return { op: match[1], variables };
}

/**
 * Does an intercepted timeline response's request URL belong to THIS sweep's scope?
 *
 * Both the live stream and the replay buffer (075) carry EVERY timeline the page has
 * fetched — main bookmarks, Likes, and any OTHER bookmark folder you browsed before
 * starting. The hook is scope-blind by design (it forwards all three ops). Without
 * this gate a folder sweep would ingest the buffered pre-sweep pages of unrelated
 * timelines — tweets from OUTSIDE the folder. `scope` is exactly what
 * `resolveSweepSpec` emits: `"bookmarks"` (the main list) or `"bookmarks:<folderId>"`.
 *
 * A folder request is the `BookmarkFolderTimeline` op whose `variables` carry
 * `bookmark_collection_id: "<folderId>"`; the main list is the distinct `Bookmarks` op
 * (NOT `BookmarkFolderTimeline`, NOT `Likes`). Matched via `graphqlOp` (JSON-parsed
 * variables, 6A). An unknown / missing scope matches nothing — better to drop a page
 * than cross-contaminate.
 */
export function matchesScope(url, scope) {
  const request = graphqlOp(url);
  if (!request) return false;

  const folder = /^bookmarks:(\d+)$/.exec(scope || "");
  if (folder) {
    return request.op === "BookmarkFolderTimeline" &&
      String(request.variables.bookmark_collection_id) === folder[1];
  }

  if (scope === "bookmarks") {
    return request.op === "Bookmarks"; // the main list's own op only
  }

  return false; // unknown scope → drop rather than risk pulling the wrong feed
}
