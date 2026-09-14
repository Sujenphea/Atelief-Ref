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
// `isBoardEntry` is IMPORTED, never re-typed, for the reason `ORIGIN_HOST` is below: the
// check counts its board denominator with the same predicate `parseBoardsPage` filters
// on, and a second copy here would keep passing after that one moved.
import {
  parseBoardFeedPage, parseBoardsPage, mapPinterestPin, isBoardEntry,
} from "./bulk-pinterest.js";
import {
  parseBoardFeedPage as parseRednoteBoardPage, parseNoteDetail as parseRednoteNoteDetail,
  detectRednoteChallenge, detectRednoteDetailChallenge, isBoardFeedRequest,
  isNoteDetailRequest, videoSourceId,
} from "./bulk-rednote.js";
// The origin host is IMPORTED, never re-typed: the check below asserts every swept
// mediaUrl lands on the host the rewrite targets, and a second copy of the string would
// keep this check green after the rewrite had moved somewhere else.
import {
  ORIGIN_HOST as REDNOTE_ORIGIN_HOST, toRednoteOriginal, hasTransform as rednoteHasTransform,
} from "./extractors/rednote.js";
import {
  STREAM_REFUSAL, readVideoCandidates, selectStreamRung, videoCandidates, videoLadder,
} from "./rednote-video.js";
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

/**
 * Pinterest `BoardsResource`: the response must still BE a boards list — entries that
 * parse to `{ id, name, url }` with all three present, not merely with an id.
 *
 * The weak version asserted only "at least one board, each with an id" and could not tell
 * a boards list from a response that is not one. A user supplied the wrong Pinterest file
 * by accident — the `board_ideas_preview_detailed` placeholder a board page opens with
 * (`endpoint_name: v3_board_pins`, one `type: "story"` container in `data[]`, zero
 * boards) — and got `✔ Pinterest boards list — boards=1`, because the story's id
 * satisfied the only per-entry rule there was. Same verdict as the real list, opposite
 * truth. The story is now dropped by `parseBoardsPage` (it declares a non-board `type`);
 * the rules below are what makes the REMAINING entries answerable for, and they hold
 * independently of that filter — a Pinterest rename of `url` produces url-less entries
 * that still declare `type: "board"`.
 *
 * `url` is the load-bearing field, not a nicety: it is the only thing that makes a board
 * sweepable. `buildBoardFeedURL` puts it in both `source_url` and `board_url`, and a null
 * stringifies to the literal "null" — a malformed request, no throw, nothing to see.
 * `name` is the other half of the parser's stated contract and the only human label the
 * response carries; a picker cannot show a board it cannot name, and the popup has no
 * fallback to invent one (`popup-view.js` labels rednote off the id precisely because
 * that platform sends no name — "an id is honest; an invented name is not").
 *
 * Both are required of EVERY board rather than "some" — unlike `checkTimeline`'s media
 * rule, where a text-only tweet legitimately lands media-less. Every board in the live
 * capture carries both, and a Pinterest board cannot exist without a name and the slug
 * url derived from it.
 *
 * The denominator is computed from the RAW `data[]`, the way `checkInstagramSaved`
 * computes its fan-out from Instagram's own declared count — through `isBoardEntry`,
 * IMPORTED from the parser so the two cannot disagree about what a board entry is. That
 * is what keeps "the parser dropped 3 of 4 boards" from reading as "a 1-board account".
 */
export function checkBoards(json) {
  let page;
  try {
    page = parseBoardsPage(json);
  } catch (error) {
    return verdict([`parseBoardsPage threw: ${String(error)}`], {});
  }
  const raw = json && json.resource_response ? json.resource_response.data : null;
  const entries = Array.isArray(raw) ? raw : [];
  const boardEntries = entries.filter(isBoardEntry);
  const modules = entries.length - boardEntries.length;

  const problems = [];
  if (page.boards.length < 1) {
    problems.push(entries.length > 0
      ? `no boards among ${entries.length} entries — every one is a non-board module`
        + ` (is this a boards list at all?)`
      : "no boards found");
  }
  if (page.boards.length < boardEntries.length) {
    problems.push(`${boardEntries.length - page.boards.length} of ${boardEntries.length}`
      + ` board entries failed to parse (the id shape moved?)`);
  }
  if (page.boards.some((board) => !board.id)) problems.push("a board is missing its id");
  const named = page.boards.filter((board) => board.name).length;
  const addressable = page.boards.filter((board) => board.url).length;
  if (named < page.boards.length) {
    problems.push(`${page.boards.length - named} of ${page.boards.length} boards have no name`
      + ` (nothing could label them — board.name renamed?)`);
  }
  if (addressable < page.boards.length) {
    problems.push(`${page.boards.length - addressable} of ${page.boards.length} boards have no url`
      + ` (unsweepable — buildBoardFeedURL needs it for source_url AND board_url)`);
  }
  // `bookmark` is reported but NOT required: unlike the board feed, a boards list
  // legitimately fits on one page, and `enumerateBoards` reads its absence as end-of-feed.
  return verdict(problems, {
    entries: entries.length,
    modules,
    boards: page.boards.length,
    named,
    addressable,
    hasBookmark: !!page.bookmark,
  });
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
  // BOTH transform spellings, asked of the module that strips them rather than of a
  // second copy of the shapes: `!nd_dft_…` on the path and `?imageView2/2/w/540/…` in
  // the query. This check tested only the `!` form while a live `board/info` response
  // was serving the query form on every cover — a 35-57x quality loss the canary was
  // structurally unable to see (496).
  if (page.items.some((item) => rednoteHasTransform(item.mediaUrl))) {
    problems.push("a transform directive survived the rewrite (`!` suffix or ?imageView2 query)");
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

/** rednote note detail (K3b): the note-open response must still fan out to ONE item per
 * `image_list[]` entry, positionally keyed, each landing on the unsigned origin host.
 *
 * The drift that matters here is different from the board's. There the fan-out is 1:1 and
 * a moved field empties a row; here the fan-out IS the feature — `image_list` is the only
 * place a note's carousel exists at all — so the signal is a count that stops matching the
 * array it came from, and a `<note_id>:<index>` key that stops being positional (which
 * would re-key every image of every note and defeat dedup-skip wholesale).
 *
 * Registered as its own check, beside `x-thread` rather than folded into `rednote`, for
 * the same reason: it is a SECOND endpoint on a different clock, and a board capture
 * cannot answer for it. */
export function checkRednoteNoteDetail(json, { host = "www.rednote.com" } = {}) {
  let page;
  try {
    page = parseRednoteNoteDetail(json, { host });
  } catch (error) {
    return verdict([`parseNoteDetail threw: ${String(error)}`], {});
  }
  const problems = [];
  if (page.error) problems.push(`challenge recognizer misfired on a normal note (${page.error.kind})`);

  const items = (json && json.data && Array.isArray(json.data.items)) ? json.data.items : [];
  const card = items.length > 0 && items[0] ? items[0].note_card : null;
  const images = card && Array.isArray(card.image_list) ? card.image_list : [];
  if (images.length === 0) {
    problems.push("the capture carries no image_list (note_card.image_list renamed, or a video note?)");
  }
  if (images.length > 0 && page.items.length === 0) {
    problems.push(`no items fanned out from ${images.length} images (${page.unsupported || "unknown"})`);
  }
  if (images.length > 0 && page.items.length !== images.length) {
    problems.push(`fanned out ${page.items.length} of ${images.length} images (an entry lost its url)`);
  }
  if (page.noteId && page.items.some((item, index) => item.sourceId !== `${page.noteId}:${index}`)) {
    problems.push("a sourceId is not <note_id>:<position> (dedup against a prior sweep would break)");
  }
  const urls = new Set(page.items.map((item) => item.mediaUrl));
  if (urls.size !== page.items.length) {
    problems.push("two images resolved to the SAME mediaUrl (the key rule collapsed them)");
  }
  const onOriginHost = (url) => String(url || "").startsWith(`http://${REDNOTE_ORIGIN_HOST}/`);
  if (page.items.some((item) => !onOriginHost(item.mediaUrl))) {
    problems.push(`a mediaUrl is not an unsigned origin-host url`
      + ` (expected ${REDNOTE_ORIGIN_HOST} — the key rule moved?)`);
  }
  // Both transform spellings — `!` suffix and `?imageView2` query — see `checkRednoteBoard`.
  if (page.items.some((item) => rednoteHasTransform(item.mediaUrl))) {
    problems.push("a transform directive survived the rewrite (`!` suffix or ?imageView2 query)");
  }
  if (page.items.some((item) => !item.mediaUrlFallback)) {
    problems.push("an item lost its signed fallback (the bare original can 404)");
  }
  // `nickname` here, `nick_name` on the feed — the 098 D6 trap, which fails as a null
  // author rather than as an error.
  if (page.items.some((item) => !item.provenance.authorName)) {
    problems.push("an item has no authorName (user.nickname renamed to something else?)");
  }
  // A note that yields nothing must always say why, or expansion replaces a good cover
  // with nothing.
  const mute = parseRednoteNoteDetail(
    { code: 0, success: true, data: { items: [] } }, { host });
  if (mute.error || !mute.unsupported) {
    problems.push("an absent note no longer degrades with a stated reason");
  }
  if (!detectRednoteDetailChallenge({ code: 0, success: true, msg: "" })) {
    problems.push("the 461-shaped refusal is no longer recognised on the detail endpoint");
  }
  if (!isNoteDetailRequest("https://webapi.rednote.com/api/sns/web/v1/feed")) {
    problems.push("isNoteDetailRequest no longer matches the note-detail route");
  }
  if (isNoteDetailRequest("https://webapi.rednote.com/api/sns/web/v1/board/note")) {
    problems.push("isNoteDetailRequest now matches the board feed");
  }
  return verdict(problems, {
    images: images.length,
    items: page.items.length,
    noteType: card && card.type != null ? String(card.type) : null,
  });
}

/** rednote VIDEO note (K4): the note's stream ladder must still yield an ordered list of
 * fetchable mp4 urls, and the rung we would take must not be an obfuscated one.
 *
 * **This is the check that would have caught `ef51` before a live run** (020's test-strategy
 * note asked for it by name). 020's manual harvest took the largest file, got a `_330`
 * variant whose MP4 sample entry was fourcc `ef51`, and only found out when nothing could
 * decode it. The codec assertion below is the JSON-layer half of that lesson: the rung we
 * hand to `/ingest-video` must not carry a fourcc-shaped label, and an `ef*`-ONLY ladder
 * must still refuse in a way the sweep can report rather than crash on.
 *
 * A SEPARATE entry from `rednote-detail`, not an extension of it, for the reason `x-thread`
 * is separate from `x`: it is a different capture on its own clock, and it is the only one
 * of the two that can answer for a `type: "video"` note. Running the video capture through
 * `checkRednoteNoteDetail` would fail on a rule that is correct there — a video note's
 * one-entry `image_list` is a poster, not a carousel, and `parseNoteDetail` deliberately
 * refuses to fan it out (098 T5a).
 *
 * What it deliberately CANNOT check: whether the chosen url decodes. No JSON signal is
 * trustworthy enough for that — the HTTP 422 from `/ingest-video` is the designed backstop,
 * which is why `videoCandidates` is ordered and plural. */
export function checkRednoteVideo(json, { host = "www.rednote.com" } = {}) {
  const items = (json && json.data && Array.isArray(json.data.items)) ? json.data.items : [];
  const card = items.length > 0 && items[0] ? items[0].note_card : null;
  if (!card) return verdict(["the capture carries no note_card (data.items[0] moved?)"], {});

  const problems = [];
  const ladder = videoLadder(card);
  if (!ladder) {
    problems.push("no video.media.stream on the note (the ladder path moved, or this is not a video note)");
    return verdict(problems, { noteType: card.type != null ? String(card.type) : null });
  }

  const selected = selectStreamRung(ladder);
  const { candidates, rungs, refusal } = videoCandidates(ladder);
  if (!selected.ok) problems.push(`no usable rung in the ladder (${selected.reason})`);
  if (refusal) problems.push(`no candidate urls (${refusal})`);

  if (selected.ok) {
    if (String(selected.rung.format || "").toLowerCase() !== "mp4") {
      problems.push(`the chosen rung is not an mp4 (${selected.rung.format}) — /ingest-video takes raw bytes`);
    }
    if (candidates[0] !== selected.rung.urls[0]) {
      problems.push("the candidate list does not start at the chosen rung's master_url (ordering moved)");
    }
  }
  for (const url of candidates) {
    if (!/^https?:\/\/[^/]*rednotecdn\.com\//.test(url)) {
      problems.push(`a candidate is not on the rednote CDN (${url}) — media-hosts would refuse it`);
    }
    // 487: rednote serves streams ALREADY UNSIGNED, with real route where a signing prefix
    // would sit. A rewrite firing here would rehost a working 206 into a 404.
    if (toRednoteOriginal(url) !== url) {
      problems.push(`toRednoteOriginal rewrote an unsigned stream url (${url}) — 487 regressed`);
    }
  }
  if (new Set(candidates).size !== candidates.length) problems.push("the candidate list repeats a url");

  // The poster still has to be there: the cover pass already ingested it under `<note_id>`,
  // and T6c must not enqueue it a second time (098 T5a's reason for refusing video notes).
  const posters = Array.isArray(card.image_list) ? card.image_list : [];
  if (posters.length === 0) {
    problems.push("a video note carries no image_list (the poster the cover pass keys on is gone)");
  }
  if (posters.length > 1) {
    problems.push(`a video note carries ${posters.length} image_list entries — the one-entry`
      + " shape T6c's refusal-to-fan-out rests on has changed");
  }

  // THE CODEC ASSERTION — the rules themselves, pinned independently of what this capture
  // happens to hold, the same way `checkRednoteBoard` re-checks the terminator against a
  // synthetic last page. It has to be written this way round: asserting that the CHOSEN
  // rung is not an `ef??` fourcc would be unreachable, because `selectStreamRung` filters
  // those out before it chooses — an assertion that can never fire is not an assertion.
  // What can be checked is that it still filters. A capture whose own labels have changed
  // shows up in the `codecs` signal below.
  const efOnly = selectStreamRung({ EF4: [{ video_codec: "ef51", format: "mp4", master_url: "http://sns-v11.rednotecdn.com/stream/1/110/330/x_330.mp4" }] });
  if (efOnly.ok || efOnly.reason !== STREAM_REFUSAL.undecodableCodec) {
    problems.push("an ef*-only ladder no longer refuses — 020's cover-still-only case would ship an undecodable file");
  }
  const empty = selectStreamRung({ EF4: [], EF5: [], EF6: [], EF7: [] });
  if (empty.ok || empty.reason !== STREAM_REFUSAL.emptyLadder) {
    problems.push("an all-empty ladder no longer refuses with a stated reason");
  }

  // THE T6c HALF: what the sweep actually enqueues for this note, under both settings of
  // the video toggle. Everything above checks the ladder; this checks that the ladder
  // reaches an item — and, just as load-bearing, that the POSTER never does.
  const covered = parseRednoteNoteDetail(json, { host });
  if (covered.unsupported !== "video" || covered.items.length !== 0) {
    problems.push(
      `with video off, a video note must still refuse with "video" and fan out NOTHING `
      + `(got ${covered.items.length} items / ${covered.unsupported}) — its image_list is `
      + "the poster the cover pass already ingested as <note_id>");
  }

  const resolved = parseRednoteNoteDetail(json, { host, resolveVideo: true });
  if (resolved.unsupported || resolved.error) {
    problems.push(`with video on, the note yielded no stream (${resolved.unsupported || resolved.error})`);
  } else if (resolved.items.length !== 1) {
    problems.push(`a video note fanned out ${resolved.items.length} items — it must contribute ONE stream`);
  } else {
    const stream = resolved.items[0];
    if (stream.sourceId !== videoSourceId(resolved.noteId)) {
      problems.push(`the stream item is keyed ${stream.sourceId}, not ${videoSourceId(resolved.noteId)}`
        + " — knownNoteIndex counts a note as expanded by the colon, so this is what stops"
        + " every video note being re-opened on every sweep");
    }
    if (stream.mediaUrl || stream.mediaUrlFallback) {
      problems.push("the stream item carries a still — the poster would ingest twice, once"
        + " as <note_id> and once as <note_id>:v (the duplicate 098 T5a refused video notes for)");
    }
    if (!posters.some((image) => image.url_default || image.url_pre)) {
      problems.push("the poster carries no usable url — the cover the stream falls back to is gone");
    }
    const attached = readVideoCandidates(stream);
    if (!attached || attached.join("|") !== candidates.join("|")) {
      problems.push("the stream item's attached candidate list is not the ladder's ordered urls");
    }
    // 020 B3, enforced where it would actually bite: `provenance` is what ships to the app
    // and what a checkpointed item would carry, and a stored stream url comes back 404 or
    // points at a rung that has rotated away.
    const stored = JSON.stringify(stream.provenance);
    if (candidates.some((url) => stored.includes(url)) || /rednotecdn\.com\/stream\//.test(stored)) {
      problems.push("a stream url reached the item's PROVENANCE — 020 B3 says never store one");
    }
  }

  return verdict(problems, {
    noteType: card.type != null ? String(card.type) : null,
    buckets: Object.keys(ladder).length,
    populated: Object.values(ladder).filter((b) => Array.isArray(b) && b.length > 0).length,
    rungs: rungs.length,
    candidates: candidates.length,
    // Reported so a label change is VISIBLE in the canary line even when nothing breaks:
    // `EF4`…`EF7` today, and the day one of these reads as a four-character fourcc the
    // rungs/candidates counts beside it will have dropped.
    codecs: [...new Set(rungs.map((rung) => rung.codec))].join("|") || null,
    bucket: selected.ok ? selected.bucket : null,
    streamType: selected.ok ? selected.rung.streamType : null,
    posters: posters.length,
  });
}

export const CHECKS = {
  x: { label: "X timeline (Bookmarks/Likes)", run: checkTimeline },
  "x-thread": { label: "X thread (TweetDetail)", run: checkThreadDetail },
  "pinterest-board": { label: "Pinterest board feed", run: checkBoardFeed },
  "pinterest-boards": { label: "Pinterest boards list", run: checkBoards },
  instagram: { label: "Instagram saved feed", run: checkInstagramSaved },
  rednote: { label: "rednote board feed", run: checkRednoteBoard },
  "rednote-detail": { label: "rednote note detail", run: checkRednoteNoteDetail },
  "rednote-video": { label: "rednote video ladder", run: checkRednoteVideo },
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
