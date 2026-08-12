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
// A tweet FANS OUT to one `BulkItem` per media (310) — the shape `bulk-instagram.js`
// has always had. Every photo is downloaded as its own asset, keyed by the MEDIA's
// `media_key`, and they all share the tweet's permalink, which is the app's
// post-grouping key: a 4-photo tweet collapses to one tile carrying a `⧉ 4` chip.
// It used to be ONE item per tweet (003 · C3 bulk) keyed by `tweetId`, with only the
// FIRST photo fetched and the rest kept as bare URL references in a `tweet` payload
// — listed in the UI, never downloaded.
//
// So a tweet with media is IMAGES, not a card; its text and author survive on the
// source (`title` / `authorHandle` / `authorName`). A tweet with no usable media is
// still a single media-less `tweet` card, which is the case that kind exists for.
// A REPOST (retweet) is unwrapped to the ORIGINAL tweet, whose text + media are the
// real substance; the reposter's handle survives as `rawMetadata.repostedBy`, since
// that identity is the only thing a plain repost actually adds (its `full_text` is
// just the "RT @user: …" wrapper). A QUOTE tweet carries BOTH halves: its title is
// the quoter's words followed by the quoted byline + text, and its media are the
// quoter's own followed by the quoted tweet's, all filed under the quoter's
// permalink so they group as one post. Borrowed media are namespaced by the quoting
// tweet's id so their dedup key can't collide with a direct save of the quoted tweet.

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

/** The QUOTED tweet a tweet embeds (`quoted_status_result`), unwrapped, or null.
 * Its text and media are BOTH read (appended after the quoter's own, never
 * replacing them) — a quote is only half a thought without the thing it quotes,
 * and for a BARE quote the quoted video/image is the entire substance. */
export function quotedTweet(tweet) {
  const quoted =
    tweet?.legacy?.quoted_status_result?.result ||
    tweet?.quoted_status_result?.result || null;
  return unwrapTweet(quoted);
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

/** The tweet's text: the `note_tweet` long-form body when present (a >280-char
 * tweet's `legacy.full_text` is TRUNCATED), else `legacy.full_text`. */
export function tweetText(tweet) {
  return tweet?.note_tweet?.note_tweet_results?.result?.text || tweet?.legacy?.full_text || null;
}

/**
 * The title for a QUOTE tweet: the quoter's own words first, then the quoted
 * tweet's byline + text below (the reader's order — you see the comment, then what
 * it is commenting on). One combined string rather than a second field, so both
 * halves land in the ONE place the app's provenance UI and FTS already read
 * (`source.title`) with no schema change.
 *
 * Returns the quoter's text unchanged when there is nothing quoted, and the quoted
 * block alone for a BARE quote (no words of its own) — the case where the quoted
 * tweet IS the whole substance.
 */
export function combineQuoteText(text, quotedByline, quotedText) {
  if (!quotedText) return text || null;
  const block = quotedByline ? `↩ ${quotedByline}: ${quotedText}` : `↩ ${quotedText}`;
  return text ? `${text}\n\n${block}` : block;
}

/**
 * Walk a tweet's media entries into the fan-out descriptors `mapTweet` emits, in
 * the tweet's own order. An entry with no poster is unusable (nothing to fetch,
 * nothing to show) and is dropped rather than emitted as an item the SW would fail on.
 *
 * `borrowedFrom` is the QUOTING tweet's id when these media belong to a quoted
 * tweet. It NAMESPACES the dedup key: the engine's skip set ([P14]) is keyed on
 * `sourceId`, so a borrowed `media_key` reused verbatim would collide with a direct
 * save of the quoted tweet and silently strand whichever was swept second. Scoping
 * the borrowed copy to its quoter keeps BOTH bookmarks complete; the app is
 * content-addressed (`blob_hash`), so the two assets share one blob on disk.
 */
function collectMedia(mediaList, { borrowedFrom = null } = {}) {
  const out = [];
  for (const media of mediaList) {
    const poster = media.media_url_https || null;
    if (!poster) continue;
    const mediaUrl = toOrigName(poster, { addIfAbsent: true });
    const isVideo = media.type === "video" || media.type === "animated_gif";
    // The media's own stable id — the engine's dedup + skip key ([P14]), which must
    // be per-ASSET since one tweet yields several. `media_key` is the modern field,
    // `id_str` the legacy one; the caller falls back to the index when both are absent.
    const mediaId = media.media_key || media.id_str || null;
    out.push({
      mediaUrl,
      mediaUrlFallback: mediaUrl !== poster ? poster : null,
      kind: media.type || "photo",
      videoUrl: isVideo && media.video_info ? selectBestVideo({ video: media.video_info }) : null,
      mediaId: mediaId && borrowedFrom ? `${borrowedFrom}:${mediaId}` : mediaId,
      borrowed: !!borrowedFrom,
    });
  }
  return out;
}

/**
 * Map one timeline tweet result to its `BulkItem`s, or `[]` for a tombstone /
 * no-id / empty tweet (no text AND no media — the app would reject it). `host`
 * sets the `originalURL` origin; `cursor` is threaded in by the caller (the page's
 * bottom cursor).
 *
 * FANNED OUT per media (310), the same shape `bulk-instagram.js` has always had:
 * a tweet with media yields ONE item per media, each with its own `sourceId` (the
 * media's `media_key` / `id_str`) and its own `mediaUrl`, all sharing the TWEET's
 * `originalURL`. That shared permalink is the post-grouping key, so a 4-image
 * tweet lands as 4 assets that collapse to one tile with a `⧉ 4` chip and open in
 * the tweet's own order via the `carouselIndex` each child carries.
 *
 * It used to emit one card item per tweet: `mediaUrl` = the FIRST media, the other
 * images kept as bare URL references inside the `tweet` content payload — listed
 * in the UI, never downloaded. Only the first image was ever ingested as bytes.
 *
 * So a tweet WITH media no longer carries a `content` descriptor and ingests down
 * the plain image path — it is images now, not a card. The text and author are not
 * lost: `makeProvenance` writes them to `title` / `authorHandle` / `authorName` on
 * every child, which is where the app's provenance UI reads them. A tweet with NO
 * usable media (a text-only tweet, or one whose media entries carry no poster) is
 * still a single `tweet`-kind card — that is the case the card kind exists for.
 * If a one-image tweet should stay a card, the threshold is `medias.length > 1`
 * on the branch below.
 *
 * Video is per-child now rather than first-only: each video/gif child stashes its
 * OWN best progressive MP4 in `rawMetadata.videoUrl` (already in the response — no
 * syndication call), so a tweet with two videos resolves both under the opt-in
 * instead of just the first. With the opt-in OFF (default) each lands as its poster.
 *
 * Every item also carries `threadHint` — the underlying tweet, so the thread expander
 * can decide whether this tweet is worth a `TweetDetail` call without re-parsing the
 * page. It is a LOCAL field (like `cursor`): the relay sends only `sourceId` /
 * `provenance` / `content`, so it never reaches the wire, and `mapThread` strips it
 * from the items it produces so an expanded thread can't be expanded again.
 */
export function mapTweet(result, { host = "x.com", cursor = null } = {}) {
  const outer = unwrapTweet(result);
  if (!outer) return [];
  // A repost carries its content on the original — read media/text/author/id from it,
  // so a reposted tweet saves the original's media (not an empty "RT @user…").
  const tweet = underlyingTweet(outer);
  // …but WHO reposted it is provenance the original doesn't carry, and unwrapping used
  // to drop it entirely. A plain repost has no words of its own (`full_text` is only
  // the "RT @user: …" wrapper, which is why it isn't kept as text) — the reposter's
  // handle is the whole of what the repost adds, so it rides `rawMetadata.repostedBy`.
  const repostedBy = tweet !== outer ? tweetAuthor(outer).handle : null;

  const tweetId = tweet.rest_id || (tweet.legacy && tweet.legacy.id_str) || null;
  if (!tweetId) return [];

  const author = tweetAuthor(tweet);
  const originalURL = author.screenName
    ? `https://${host}/${author.screenName}/status/${tweetId}`
    : `https://${host}/i/status/${tweetId}`;

  // A QUOTE's substance is BOTH halves. Its text is the quoter's words followed by the
  // quoted byline + text (`combineQuoteText`), and its media is the quoter's own
  // followed by the quoted tweet's — all under the QUOTER's permalink, which is what
  // was bookmarked, so the two sets group into one tile the way a carousel does.
  // Borrowed media are namespaced by this tweet's id so their dedup key can't collide
  // with a direct save of the quoted tweet (see `collectMedia`). Retweets are already
  // unwrapped above, so a repost OF a quote reads the original's quote correctly.
  const quoted = quotedTweet(tweet);
  const quotedAuthor = quoted ? tweetAuthor(quoted) : null;
  const title = combineQuoteText(
    tweetText(tweet),
    quotedAuthor ? quotedAuthor.handle || quotedAuthor.name : null,
    quoted ? tweetText(quoted) : null,
  );

  const medias = [
    ...collectMedia(tweetMedia(tweet)),
    ...(quoted ? collectMedia(tweetMedia(quoted), { borrowedFrom: tweetId }) : []),
  ];

  // `repostedBy` is written only when there IS one — a plain tweet's stored metadata
  // stays exactly as it was rather than gaining a null key.
  const sharedRaw = repostedBy ? { repostedBy } : {};
  const shared = {
    platform: "twitter",
    originalURL,
    authorHandle: author.handle,
    authorName: author.name,
    title,
  };

  if (medias.length > 0) {
    return medias.map((media, index) => ({
      sourceId: media.mediaId || `${tweetId}-${index}`,
      mediaUrl: media.mediaUrl,
      mediaUrlFallback: media.mediaUrlFallback,
      cursor,
      threadHint: tweet,
      provenance: makeProvenance({
        ...shared,
        mediaUrl: media.mediaUrl,
        mediaUrlFallback: media.mediaUrlFallback,
        // `carouselIndex` is read by the app's post grouping to open the tweet in
        // ITS order rather than the feed's — the same field the IG driver writes.
        // Quoter's media take 0…n-1, the quoted tweet's continue from there.
        rawMetadata: {
          ...sharedRaw,
          tweetId, kind: media.kind, videoUrl: media.videoUrl, carouselIndex: index,
        },
      }),
    }));
  }

  // No usable media: a text-only tweet is still a first-class `tweet` card.
  const content = buildTweetPayload({
    tweetID: tweetId,
    mediaUrls: [],
    text: title,
    authorHandle: author.handle,
    authorName: author.name,
  });
  if (!content) return []; // no substance (no text AND no media) → skip

  return [{
    sourceId: tweetId,
    mediaUrl: null,
    mediaUrlFallback: null,
    cursor,
    threadHint: tweet,
    content,
    provenance: makeProvenance({
      ...shared,
      rawMetadata: { ...sharedRaw, tweetId, kind: "text", videoUrl: null },
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
