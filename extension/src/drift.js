// Atelier Capture — drift-check invariants (Phase 8, [T12][12A]).
//
// The platform response shapes drift (X rotates queryIds/features every few weeks;
// Pinterest bumps X-APP-VERSION). The committed fixtures are dated snapshots — when
// they go stale, a live sweep silently yields nothing. These pure checks run a
// response (a committed fixture, or a FRESH live capture the user saved) through the
// REAL parsers and assert the structural signals the drivers depend on still exist,
// reporting exactly what changed. The opt-in CLI (`scripts/drift-check.js`) wraps
// them with file loading + a capture-age warning; the checks themselves are Date-free
// so they're deterministically testable.

import { parseTimelinePage } from "./bulk-twitter.js";
import { collectConversationTweets, selfThreadChain, mapThread } from "./twitter-thread.js";
import { parseBoardFeedPage, parseBoardsPage, mapPinterestPin } from "./bulk-pinterest.js";
import {
  parseBoardFeedPage as parseRednoteBoardPage, detectRednoteChallenge, isBoardFeedRequest,
} from "./bulk-rednote.js";
// The origin host is IMPORTED, never re-typed: the check below asserts every swept
// mediaUrl lands on the host the rewrite targets, and a second copy of the string would
// keep this check green after the rewrite had moved somewhere else.
import { ORIGIN_HOST as REDNOTE_ORIGIN_HOST } from "./extractors/rednote.js";
import {
  parseSavedFeedPage, detectChallenge, isSavedFeedRequest, isCollectionFeedRequest, IG_MEDIA_TYPE,
} from "./bulk-instagram.js";

/** A `{ ok, problems, signals }` verdict. `ok` is false if any invariant broke;
 * `problems` names each break; `signals` reports the parsed counts for context. */
function verdict(problems, signals) {
  return { ok: problems.length === 0, problems, signals };
}

/** X `Bookmarks`/`Likes`: the timeline must still yield tweet entries, fan each out to
 * media-keyed items with a usable image, and expose a Bottom pagination cursor. (A
 * text-only tweet legitimately lands media-less, so drift is measured on "some item
 * has a mediaUrl", not a per-item URL requirement — unlike the IG check, where every
 * item is a media by construction.) */
export function checkTimeline(json, { host = "x.com" } = {}) {
  let page;
  try {
    page = parseTimelinePage(json, { host });
  } catch (error) {
    return verdict([`parseTimelinePage threw: ${String(error)}`], {});
  }
  const problems = [];
  if (page.tweetCount < 1) problems.push("no tweet entries found (shape moved?)");
  if (page.items.length < 1) problems.push("no tweets mapped from any entry");
  if (page.items.some((item) => !item.sourceId)) problems.push("a mapped tweet is missing its id");
  // Media extraction must still work: a bookmarks timeline is media-heavy, so ZERO
  // fetchable media across the whole page means the media_url_https shape moved.
  // Since 310 a tweet fans out to one ITEM per media, so the signal is items
  // carrying a `mediaUrl` — "some", not "every", because a text-only tweet
  // legitimately lands as a media-less card.
  const mediaItems = page.items.filter((item) => item.mediaUrl).length;
  if (page.items.length > 0 && mediaItems < 1) {
    problems.push("no media extracted from any tweet (media_url_https shape moved?)");
  }
  // Same weakness the board feed had: `items.length >= 1` passes while most tweets are
  // silently dropped. A tweet fans out to one item per media, so the per-TWEET key is the
  // status id in `originalURL`, not `sourceId` (which is per-media by design). Every
  // tweet entry must survive to at least one item.
  const tweetIds = new Set(page.items
    .map((item) => (String((item.provenance || {}).originalURL || "").match(/status\/(\d+)/) || [])[1])
    .filter(Boolean));
  if (page.tweetCount > 0 && tweetIds.size < page.tweetCount) {
    problems.push(`${page.tweetCount - tweetIds.size} of ${page.tweetCount} tweet entries`
      + ` mapped to no item (entry/legacy shape moved?)`);
  }
  // The fan-out key must stay per-MEDIA: a collision means the engine's skip set
  // ([P14]) would drop every sibling of a multi-image tweet as already-seen.
  const ids = new Set(page.items.map((item) => item.sourceId));
  if (ids.size !== page.items.length) {
    problems.push("duplicate per-media sourceIds (media_key/id_str shape moved?)");
  }
  if (!page.bottomCursor) problems.push("no Bottom cursor (pagination would stall)");
  return verdict(problems, {
    tweetCount: page.tweetCount,
    mappedTweets: tweetIds.size,
    mediaItems,
    hasCursor: !!page.bottomCursor,
  });
}

/**
 * X `TweetDetail`: a real conversation must still walk down to the author's own thread
 * and map to one grouped post ([090] 1A).
 *
 * This is the check the thread feature was missing. Every other X parser is pinned
 * against a real captured response; the conversation walk was pinned only against an
 * INVENTED body, so a shape change at X — a renamed reply link, a moved author, entries
 * nested one level deeper — would fail exactly the way this whole file exists to catch:
 * silently, yielding an unexpanded tweet that looks like a tweet that simply wasn't
 * threaded. Run it against a live capture of a conversation you know is a thread.
 *
 * `focalTweetId` is optional. Without one the check walks from EVERY tweet in the body
 * and keeps the longest chain, which is what a threaded conversation's spine is — so an
 * operator can save a response out of DevTools and check it without also having to dig
 * the focal id out of the request.
 */
export function checkThreadDetail(json, { host = "x.com", focalTweetId = null } = {}) {
  let tweets;
  try {
    tweets = collectConversationTweets(json);
  } catch (error) {
    return verdict([`collectConversationTweets threw: ${String(error)}`], {});
  }
  const problems = [];
  const idOf = (tweet) => tweet?.rest_id || tweet?.legacy?.id_str || null;

  if (tweets.length < 1) {
    return verdict(["no tweets in the conversation (tweet_results shape moved?)"], { tweets: 0 });
  }
  if (tweets.some((tweet) => !idOf(tweet))) problems.push("a conversation tweet has no id");

  // The reply link IS the walk. If nothing in a whole conversation carries one, the field
  // was renamed and every chain would silently collapse to a single tweet.
  const withParent = tweets.filter((tweet) => tweet?.legacy?.in_reply_to_status_id_str).length;
  if (withParent < 1) {
    problems.push("no tweet carries in_reply_to_status_id_str (the reply link moved?)");
  }

  // The author is the OTHER half of the walk — it's what separates the thread from the
  // strangers replying to it. Named explicitly (rather than inferred from a short chain)
  // because the two failures look identical from the outside and have different fixes:
  // a moved author path collapses every chain to one tweet, exactly like a tweet that
  // simply wasn't threaded.
  const authorOf = (tweet) => {
    const user = tweet?.core?.user_results?.result || null;
    return user?.core?.screen_name || user?.legacy?.screen_name || null;
  };
  const withAuthor = tweets.filter(authorOf).length;
  if (withAuthor < 1) {
    problems.push("no tweet yields an author (core.user_results.result.core.screen_name moved?)");
  }

  // The longest self-chain in the body — the thread, whichever tweet was bookmarked.
  let chain = [];
  const candidates = focalTweetId ? [String(focalTweetId)] : tweets.map(idOf).filter(Boolean);
  for (const id of candidates) {
    const walked = selfThreadChain(json, id);
    if (walked.length > chain.length) chain = walked;
  }
  if (chain.length < 2) {
    problems.push(focalTweetId
      ? `no self-thread chain from ${focalTweetId} (capture a THREADED conversation?)`
      : "no self-thread chain of 2+ tweets found (capture a THREADED conversation?)");
    return verdict(problems, {
      tweets: tweets.length, withParent, withAuthor, chain: chain.length,
    });
  }

  // The chain must still map to the grouped shape the app reads: one permalink across the
  // whole thread (the grouping key) and a contiguous index (the open order).
  let items = [];
  try {
    items = mapThread(chain, { host });
  } catch (error) {
    problems.push(`mapThread threw: ${String(error)}`);
    return verdict(problems, { tweets: tweets.length, chain: chain.length });
  }
  if (items.length < 1) problems.push("the chain mapped to no items (mapTweet shape moved?)");
  const permalinks = new Set(items.map((item) => item.provenance.originalURL));
  if (permalinks.size > 1) {
    problems.push(`${permalinks.size} permalinks across one thread (grouping key broken)`);
  }
  const indices = items.map((item) => item.provenance.rawMetadata.carouselIndex);
  if (indices.some((index, position) => index !== position)) {
    problems.push("carouselIndex is not 0…n-1 across the thread (open order broken)");
  }
  if (items.some((item) => !item.provenance.rawMetadata.threadId)) {
    problems.push("an item is missing threadId");
  }
  const ids = new Set(items.map((item) => item.sourceId));
  if (ids.size !== items.length) problems.push("duplicate sourceIds across the thread (dedup collision)");
  if (items.some((item) => "threadHint" in item)) {
    problems.push("an expanded item kept its threadHint (it would re-expand every sweep)");
  }
  if (!items[0].provenance.authorHandle) problems.push("no authorHandle (the author shape moved?)");

  return verdict(problems, {
    tweets: tweets.length,
    withParent,
    withAuthor,
    chain: chain.length,
    items: items.length,
  });
}

/** Pinterest `BoardFeedResource`: pins must still carry an id + a usable image, and
 * the response must expose a `bookmark` cursor. */
export function checkBoardFeed(json, { host = "www.pinterest.com" } = {}) {
  let page;
  try {
    page = parseBoardFeedPage(json);
  } catch (error) {
    return verdict([`parseBoardFeedPage threw: ${String(error)}`], {});
  }
  const problems = [];
  if (page.pins.length < 1) problems.push("no pins in the board feed");
  // The bound used to be `mapped >= 1`, which could not tell "24 of 25 mapped, the 25th
  // is an injected story card" from "3 of 25 mapped, the parser is broken" — the second
  // reads as a small board rather than as drift, which is the silent degradation this
  // file exists to catch. Pinterest interleaves NON-PIN modules into `data[]`
  // (`type: "story"`, e.g. `related_interests_module`), so they are excluded from the
  // denominator rather than tolerated in the numerator: every entry that CLAIMS to be a
  // pin must map. An entry with no `type` counts as a pin — if we cannot tell what it
  // is, it has to map or we hear about it.
  const isPinEntry = (pin) => !pin || pin.type == null || pin.type === "pin";
  const pinEntries = page.pins.filter(isPinEntry);
  const modules = page.pins.length - pinEntries.length;
  const mapped = pinEntries.map((pin) => mapPinterestPin(pin, { host })).filter(Boolean);
  if (page.pins.length > 0 && pinEntries.length < 1) {
    problems.push(`every one of ${page.pins.length} entries is a non-pin module (type shape moved?)`);
  }
  if (mapped.length < pinEntries.length) {
    problems.push(`${pinEntries.length - mapped.length} of ${pinEntries.length} pin entries`
      + ` failed to map (id/images shape moved?)`);
  }
  if (!page.bookmark) problems.push("no bookmark cursor (pagination would stall)");
  return verdict(problems, {
    pins: page.pins.length,
    pinEntries: pinEntries.length,
    modules,
    mapped: mapped.length,
    hasBookmark: !!page.bookmark,
  });
}

/** Pinterest `BoardsResource`: boards must still parse to `{ id, name, url }`. */
export function checkBoards(json) {
  let page;
  try {
    page = parseBoardsPage(json);
  } catch (error) {
    return verdict([`parseBoardsPage threw: ${String(error)}`], {});
  }
  const problems = [];
  if (page.boards.length < 1) problems.push("no boards found");
  if (page.boards.some((board) => !board.id)) problems.push("a board is missing its id");
  return verdict(problems, { boards: page.boards.length });
}

/** Instagram saved feed: posts must still fan out per media to `pk`-keyed items with a
 * usable image, a video/reel must still expose its `videoUrl` (7A), the challenge
 * recognizer must NOT misfire on a normal page, and the saved-feed route matcher must
 * still match. Fan-out is asserted STRUCTURALLY (carousel → child-count items), so the
 * invariant holds against any capture, committed or live. */
export function checkInstagramSaved(json, { host = "www.instagram.com" } = {}) {
  let page;
  try {
    page = parseSavedFeedPage(json, { host });
  } catch (error) {
    return verdict([`parseSavedFeedPage threw: ${String(error)}`], {});
  }
  const problems = [];
  if (page.error) problems.push(`challenge recognizer misfired on a normal page (${page.error.kind})`);

  // Expected fan-out: sum over posts of (carousel ? child count : 1). The parser must
  // produce exactly this many items (1A); a broken carousel walk shows up as a mismatch.
  const rawItems = json && Array.isArray(json.items) ? json.items : [];
  let expected = 0;
  let videosSeen = 0;
  for (const wrapper of rawItems) {
    const media = wrapper && wrapper.media ? wrapper.media : wrapper;
    if (!media) continue;
    if (media.media_type === IG_MEDIA_TYPE.carousel) {
      // Expected from IG's OWN declared count (not carousel_media.length) — so a rename /
      // drop of the `carousel_media` array the parser walks DIVERGES from the count and is
      // caught, rather than expected and actual dropping together and hiding the drift.
      expected += media.carousel_media_count ||
        (Array.isArray(media.carousel_media) ? media.carousel_media.length : 1);
    } else {
      expected += 1;
    }
    if (media.media_type === IG_MEDIA_TYPE.video ||
        (Array.isArray(media.video_versions) && media.video_versions.length > 0)) {
      videosSeen += 1;
    }
  }

  if (rawItems.length > 0 && page.items.length < 1) {
    problems.push("no items mapped from any saved post (items[].media shape moved?)");
  }
  if (page.items.length !== expected) {
    problems.push(`fan-out count ${page.items.length} ≠ expected ${expected} (carousel walk / pk shape moved?)`);
  }
  const ids = new Set(page.items.map((item) => item.sourceId));
  if (ids.size !== page.items.length) problems.push("duplicate per-media pk sourceIds (fan-out key collision)");
  if (page.items.some((item) => !item.mediaUrl)) {
    problems.push("a mapped item has no mediaUrl (image_versions2 shape moved?)");
  }
  const videoUrls = page.items.filter((item) => item.provenance.rawMetadata.videoUrl).length;
  if (videosSeen > 0 && videoUrls < 1) {
    problems.push("a video/reel yielded no videoUrl (video_versions shape moved?)");
  }
  // A normal page must NOT trip the challenge recognizer (no false positives).
  if (detectChallenge(json)) problems.push("detectChallenge fired on a normal saved page");
  // The route matchers the driver depends on must still match their canonical URLs (and not
  // each other): the flat saved feed and a specific collection's feed.
  if (!isSavedFeedRequest("https://www.instagram.com/api/v1/feed/saved/posts/")) {
    problems.push("isSavedFeedRequest no longer matches the saved-feed route");
  }
  if (!isCollectionFeedRequest("https://www.instagram.com/api/v1/feed/collection/1021461010622913/posts/")) {
    problems.push("isCollectionFeedRequest no longer matches the collection-feed route");
  }
  return verdict(problems, {
    posts: rawItems.length,
    items: page.items.length,
    videos: videoUrls,
    endOfFeed: page.endOfFeed,
  });
}

/** The registered checks, by the `--<name>` flag the CLI accepts. */
/** rednote board feed: every row must still map to ONE cover-keyed item with a usable
 * unsigned-original mediaUrl and a signed fallback, the challenge recognizer must not
 * misfire on a normal page, the terminator must still terminate, and the route matcher
 * must still tell the feed apart from the telemetry that rides beside it.
 *
 * The fan-out here is 1:1 by construction (a feed row holds ONE cover — no image list to
 * walk), so unlike Instagram the interesting drift is not a count mismatch but a row that
 * stops yielding an image at all: `cover.url` is `""` on every live row, so the usable
 * URLs are `url_pre` / `url_default` / `info_list[]`, and a rename of those is exactly the
 * change that would silently empty a sweep. */
export function checkRednoteBoard(json, { host = "www.rednote.com" } = {}) {
  let page;
  try {
    page = parseRednoteBoardPage(json, { host });
  } catch (error) {
    return verdict([`parseBoardFeedPage threw: ${String(error)}`], {});
  }
  const problems = [];
  if (page.error) problems.push(`challenge recognizer misfired on a normal page (${page.error.kind})`);

  const notes = (json && json.data && Array.isArray(json.data.notes)) ? json.data.notes : [];
  if (notes.length > 0 && page.items.length === 0) {
    problems.push("no items mapped from any note (data.notes[].cover shape moved?)");
  }
  if (page.items.length !== notes.length) {
    problems.push(`mapped ${page.items.length} of ${notes.length} notes (a row stopped yielding a cover)`);
  }
  const ids = new Set(page.items.map((item) => item.sourceId));
  if (ids.size !== page.items.length) problems.push("duplicate note_id sourceIds (key collision)");
  if (page.items.some((item) => !item.mediaUrl)) {
    problems.push("a mapped item has no mediaUrl (cover.url_pre/url_default/info_list moved?)");
  }
  // The rewrite is the whole value of the cover pass: the signed webp is a ~47 KB
  // thumbnail, the unsigned original a ~240 KB full-res asset.
  const onOriginHost = (url) => String(url || "").startsWith(`http://${REDNOTE_ORIGIN_HOST}/`);
  if (page.items.some((item) => !onOriginHost(item.mediaUrl))) {
    problems.push(`a mediaUrl is not an unsigned origin-host url`
      + ` (expected ${REDNOTE_ORIGIN_HOST} — the key rule moved?)`);
  }
  if (page.items.some((item) => (item.mediaUrl || "").includes("!"))) {
    problems.push("a transform suffix survived the rewrite");
  }
  if (page.items.some((item) => !item.mediaUrlFallback)) {
    problems.push("an item lost its signed fallback (the bare original can 404)");
  }
  if (page.items.some((item) => !item.provenance.authorName)) {
    problems.push("an item has no authorName (user.nick_name renamed?)");
  }
  // The terminator, checked against the LIVE shape rather than a belief about it.
  const last = { code: 0, success: true, msg: "成功", data: { has_more: false, notes: [], cursor: "" } };
  const lastPage = parseRednoteBoardPage(last, { host });
  if (lastPage.error) problems.push("the genuine last page reads as a challenge");
  if (!lastPage.endOfFeed) problems.push("has_more:false / cursor:\"\" no longer ends the feed");
  const looping = parseRednoteBoardPage(
    { code: 0, success: true, data: { has_more: true, notes: [], cursor: "" } }, { host });
  if (!looping.endOfFeed) problems.push("an empty cursor with has_more:true no longer terminates (loop risk)");
  // A refusal must still be recognised: rednote answers a rejected request with a success
  // -shaped body, so the missing `data.notes` array is the load-bearing signal.
  if (!detectRednoteChallenge({ code: 0, success: true, msg: "" })) {
    problems.push("the 461-shaped refusal is no longer recognised as a challenge");
  }
  if (!isBoardFeedRequest("//webapi.rednote.com/api/sns/web/v1/board/note?board_id=x")) {
    problems.push("isBoardFeedRequest no longer matches the board-feed route");
  }
  if (isBoardFeedRequest("https://t2.rnote.com/api/v2/collect")) {
    problems.push("isBoardFeedRequest now matches telemetry traffic");
  }
  return verdict(problems, {
    notes: notes.length,
    items: page.items.length,
    hasMore: !!(json && json.data && json.data.has_more),
  });
}

export const CHECKS = {
  x: { label: "X timeline (Bookmarks/Likes)", run: checkTimeline },
  "x-thread": { label: "X thread (TweetDetail)", run: checkThreadDetail },
  "pinterest-board": { label: "Pinterest board feed", run: checkBoardFeed },
  "pinterest-boards": { label: "Pinterest boards list", run: checkBoards },
  instagram: { label: "Instagram saved feed", run: checkInstagramSaved },
  rednote: { label: "rednote board feed", run: checkRednoteBoard },
};

/**
 * Whether the committed drift fixtures are past their refresh window (G18).
 * Pure — `nowMs` is injectable for tests. Returns a short operator message when
 * stale, otherwise `null`.
 */
export function fixtureStaleReminder(baseline, nowMs = Date.now()) {
  if (!baseline || !baseline.capturedAt || baseline.staleAfterDays == null) {
    return "drift baseline missing capturedAt/staleAfterDays — re-seed fixtures.";
  }
  const then = new Date(baseline.capturedAt).getTime();
  if (Number.isNaN(then)) {
    return `drift baseline capturedAt is unparseable (${baseline.capturedAt}).`;
  }
  const ageDays = Math.floor((nowMs - then) / 86_400_000);
  if (ageDays <= baseline.staleAfterDays) return null;
  return (
    `Drift fixtures are ${ageDays}d old (limit ${baseline.staleAfterDays}d). ` +
    `Run \`npm run drift-check\` with a fresh live capture before the ~2-week ` +
    `X queryId rotation window.`
  );
}
