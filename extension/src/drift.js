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

/** A `{ ok, problems, signals }` verdict. `ok` is false if any invariant broke;
 * `problems` names each break; `signals` reports the parsed counts for context. */
function verdict(problems, signals) {
  return { ok: problems.length === 0, problems, signals };
}

/** X `Bookmarks`/`Likes`: the timeline must still yield tweet entries, map media to
 * `media_key`-keyed items with a URL, and expose a Bottom pagination cursor. */
export function checkTimeline(json, { host = "x.com" } = {}) {
  let page;
  try {
    page = parseTimelinePage(json, { host });
  } catch (error) {
    return verdict([`parseTimelinePage threw: ${String(error)}`], {});
  }
  const problems = [];
  if (page.tweetCount < 1) problems.push("no tweet entries found (shape moved?)");
  if (page.items.length < 1) problems.push("no media items mapped from any tweet");
  const usable = page.items.filter((item) => item.sourceId && item.mediaUrl);
  if (page.items.length > 0 && usable.length !== page.items.length) {
    problems.push("some items missing media_key or media_url_https");
  }
  if (!page.bottomCursor) problems.push("no Bottom cursor (pagination would stall)");
  return verdict(problems, {
    tweetCount: page.tweetCount,
    mediaItems: page.items.length,
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

/** The registered checks, by the `--<name>` flag the CLI accepts. */
export const CHECKS = {
  x: { label: "X timeline (Bookmarks/Likes)", run: checkTimeline },
  "pinterest-board": { label: "Pinterest board feed", run: checkBoardFeed },
  "pinterest-boards": { label: "Pinterest boards list", run: checkBoards },
};
