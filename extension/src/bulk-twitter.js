// Atelier Capture — X / Twitter BulkSource parsing (Phase 5, [4A][9A][A2]).
//
// Unlike Pinterest (which we paginate ourselves), X's timeline requests are made BY
// THE PAGE as it auto-scrolls; a MAIN-world hook (twitter-hook.js) captures the
// `Bookmarks` / `Likes` GraphQL RESPONSES and forwards them to the content script.
// This module is the PURE half: parse an intercepted timeline response into
// `BulkItem`s + the bottom cursor. The push→pull adapter that feeds these into the
// engine lives with the content-script loop (Phase 6); the parsers here are what
// [T9] pins against the committed fixture.
//
// A tweet can carry up to 4 photos, so a tweet maps to MANY `BulkItem`s — one per
// media, keyed by the stable `media_key` (NOT the tweet id, which would collide and
// make the engine dedup-skip all but one). `originalURL` still points at the tweet.
// We read ONLY the top-level tweet's media — never a quoted tweet's (that's the
// quoted author's asset, not what the user bookmarked).

import { makeProvenance, toOrigName } from "./extractors/base.js";
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

/** Find the timeline `instructions` array across the operation shapes (Bookmarks
 * nests under `bookmark_timeline_v2`, Likes under `user.result.timeline_v2`), with a
 * bounded deep-search fallback so a wrapper rename doesn't silently yield nothing. */
export function findInstructions(json) {
  const data = json && json.data;
  const known =
    data?.bookmark_timeline_v2?.timeline ||
    data?.bookmark_timeline?.timeline ||
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
 * Map one timeline tweet result to `BulkItem`s — one per top-level media, `[]` for a
 * text-only tweet or a tombstone. `host` sets the `originalURL` origin; `cursor` is
 * threaded in by the caller (the page's bottom cursor). A video/gif item maps its
 * POSTER as the image (matching the Pinterest driver + the design's default-off bulk
 * video) and stashes the best progressive MP4 in `rawMetadata.videoUrl` for a future
 * opt-in — the URL is already in the response, so no syndication call is needed.
 */
export function mapTweet(result, { host = "x.com", cursor = null } = {}) {
  const tweet = unwrapTweet(result);
  if (!tweet) return [];

  const tweetId = tweet.rest_id || (tweet.legacy && tweet.legacy.id_str) || null;
  if (!tweetId) return [];

  const author = tweetAuthor(tweet);
  const legacy = tweet.legacy || {};
  const noteText = tweet.note_tweet?.note_tweet_results?.result?.text;
  const title = noteText || legacy.full_text || null;
  const originalURL = author.screenName
    ? `https://${host}/${author.screenName}/status/${tweetId}`
    : `https://${host}/i/status/${tweetId}`;

  const items = [];
  for (const media of tweetMedia(tweet)) {
    const sourceId = media.media_key || media.id_str || null;
    if (!sourceId) continue;
    const poster = media.media_url_https || null;
    if (!poster) continue;

    const mediaUrl = toOrigName(poster, { addIfAbsent: true });
    const mediaUrlFallback = mediaUrl !== poster ? poster : null;
    const isVideo = media.type === "video" || media.type === "animated_gif";
    const videoUrl = isVideo && media.video_info
      ? selectBestVideo({ video: media.video_info }) : null;

    items.push({
      sourceId,
      mediaUrl,
      mediaUrlFallback,
      cursor,
      provenance: makeProvenance({
        platform: "twitter",
        originalURL,
        mediaUrl,
        mediaUrlFallback,
        authorHandle: author.handle,
        authorName: author.name,
        title,
        rawMetadata: { tweetId, mediaKey: sourceId, kind: media.type || "photo", videoUrl },
      }),
    });
  }
  return items;
}

/**
 * Parse one intercepted timeline response into `{ items, bottomCursor, tweetCount }`.
 * `tweetCount` is the number of tweet ENTRIES seen (incl. text-only) — the Phase-6
 * loop treats a page with `tweetCount === 0` as the end of the timeline (X has no
 * `-end-` sentinel; an exhausted timeline simply stops returning tweets). Each item
 * carries `bottomCursor` as its checkpoint token (X resume leans on the engine's
 * dedup-skip, since pagination is scroll-driven and not cursor-injectable).
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
