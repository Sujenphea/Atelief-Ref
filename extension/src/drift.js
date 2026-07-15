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
import { parseBoardFeedPage, parseBoardsPage, mapPinterestPin } from "./bulk-pinterest.js";
import {
  parseSavedFeedPage, detectChallenge, isSavedFeedRequest, isCollectionFeedRequest, IG_MEDIA_TYPE,
} from "./bulk-instagram.js";

/** A `{ ok, problems, signals }` verdict. `ok` is false if any invariant broke;
 * `problems` names each break; `signals` reports the parsed counts for context. */
function verdict(problems, signals) {
  return { ok: problems.length === 0, problems, signals };
}

/** X `Bookmarks`/`Likes`: the timeline must still yield tweet entries, map each to a
 * tweet-id-keyed item, still extract media references where media exists, and expose a
 * Bottom pagination cursor. (A tweet is now ONE item carrying its whole media[]; a
 * text-only tweet legitimately has no media URL, so drift is measured on the media
 * REFERENCE count, not a per-item URL requirement.) */
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
  // Media extraction must still work: a bookmarks timeline is media-heavy, so a total of
  // ZERO media references across all tweets means the media_url_https shape moved.
  const mediaRefs = page.items.reduce(
    (n, item) => n + (item.content?.payload?.tweet?.media?.length || 0), 0);
  if (page.items.length > 0 && mediaRefs < 1) {
    problems.push("no media extracted from any tweet (media_url_https shape moved?)");
  }
  if (!page.bottomCursor) problems.push("no Bottom cursor (pagination would stall)");
  return verdict(problems, {
    tweetCount: page.tweetCount,
    mediaItems: mediaRefs,
    hasCursor: !!page.bottomCursor,
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
  const mapped = page.pins.map((pin) => mapPinterestPin(pin, { host })).filter(Boolean);
  if (page.pins.length > 0 && mapped.length < 1) {
    problems.push("no pin mapped to a BulkItem (id/images shape moved?)");
  }
  if (!page.bookmark) problems.push("no bookmark cursor (pagination would stall)");
  return verdict(problems, {
    pins: page.pins.length,
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
export const CHECKS = {
  x: { label: "X timeline (Bookmarks/Likes)", run: checkTimeline },
  "pinterest-board": { label: "Pinterest board feed", run: checkBoardFeed },
  "pinterest-boards": { label: "Pinterest boards list", run: checkBoards },
  instagram: { label: "Instagram saved feed", run: checkInstagramSaved },
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
