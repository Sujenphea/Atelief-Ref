// Atelier Capture — Pinterest BulkSource driver (Phase 4, [9A][A2]).
//
// The first concrete `BulkSource` for the bulk engine: it walks a board's pins via
// Pinterest's own resource API (the same `/resource/BoardFeedResource/` calls the
// site makes), replaying the opaque `bookmark` cursor page by page until `-end-`.
// SW-side, no MAIN-world hook needed (unlike X): a page-context `fetch` with
// `credentials:'include'` carries the session, and the runtime-scraped
// `X-APP-VERSION` + `csrftoken` cookie authorize the resource endpoint.
//
// PURE + INJECTABLE: the network is a single `fetchJson(url, { headers })` dep, so
// the whole driver runs against committed fixtures under `node --test`. The URL /
// header BUILDERS and the JSON→BulkItem MAPPER are separately exported and tested
// so a Pinterest response-shape drift breaks a unit test, not a live sweep.
//
// A yielded `BulkItem` matches the engine seam:
//   { sourceId, mediaUrl, mediaUrlFallback, provenance, cursor }
// where `cursor` is the bookmark used to REQUEST this item's page — so a resume
// from it re-fetches the same page and re-yields its pins (the engine's dedup-skip
// makes the overlap idempotent). See bulk-engine.js for the checkpoint contract.

import { toOriginals, makeProvenance } from "./extractors/base.js";
import { fetchWithTimeout } from "./net.js";

/** Pinterest's end-of-feed sentinel bookmark. */
export const END_BOOKMARK = "-end-";

/** Default board-feed page size (mirrors the site's `page_size:25`). */
export const BOARD_FEED_PAGE_SIZE = 25;

/** A stop-gap against a pathological feed that returns empty pages with an ever-
 * changing bookmark (never `-end-`): give up after this many CONSECUTIVE empties. */
const MAX_EMPTY_PAGES = 3;

/** Raised when a resource response isn't a success — carries the http status so the
 * caller (and, later, the engine's halt) can reason about auth vs transient. */
export class PinterestResourceError extends Error {
  constructor(message, { httpStatus = null } = {}) {
    super(message);
    this.name = "PinterestResourceError";
    this.httpStatus = httpStatus;
  }
}

// ---------------------------------------------------------------------------
// Session bootstrap (pure — the content script feeds it page text / cookies)
// ---------------------------------------------------------------------------

/** Scrape Pinterest's REQUIRED `X-APP-VERSION` from a page's inline bootstrap
 * (Phase-0 finding: a bogus value 403s, so it must be the live one, not hardcoded).
 * Returns the version hash or null if the page didn't embed it. */
export function scrapePinterestAppVersion(text) {
  const match = /app_version"\s*:\s*"([a-f0-9]{6,12})"/.exec(text || "");
  return match ? match[1] : null;
}

/** Scrape the app_version from a live document, scanning inline `<script>` bodies FIRST
 * (14A) — the bootstrap JSON lives in one, and each script's `textContent` is far smaller
 * than serializing the ENTIRE DOM via `documentElement.innerHTML` (which on a big board
 * page is megabytes). Falls back to the full-page innerHTML only if no script carries it,
 * so a markup change that relocates the value still resolves. `doc` needs `.scripts`
 * (array-like of elements with `.textContent`) and `.documentElement.innerHTML`. */
export function scrapePinterestAppVersionFromDoc(doc) {
  for (const script of (doc && doc.scripts) || []) {
    const found = scrapePinterestAppVersion(script.textContent || "");
    if (found) return found;
  }
  return scrapePinterestAppVersion(doc && doc.documentElement ? doc.documentElement.innerHTML : "");
}

/** The value of cookie `name` from a `document.cookie` string, or null. Used to
 * read the non-HttpOnly `csrftoken` for `X-CSRFToken` (no `cookies` permission). */
export function readCookie(cookieString, name) {
  for (const part of (cookieString || "").split(";")) {
    const index = part.indexOf("=");
    if (index === -1) continue;
    if (part.slice(0, index).trim() === name) return part.slice(index + 1).trim();
  }
  return null;
}

// ---------------------------------------------------------------------------
// Pure mappers / parsers
// ---------------------------------------------------------------------------

/** The stable pin id (dedup + skip key): the canonical `id`, falling back to the
 * id embedded in `seo_url` (`/pin/{id}/`). Null if neither is present. */
export function pinIdFrom(pin) {
  if (pin && pin.id) return String(pin.id);
  const match = /\/pin\/(\d+)/.exec((pin && pin.seo_url) || "");
  return match ? match[1] : null;
}

/**
 * Choose the fetch URL + fallback for a pin's `images` map. Prefer the `orig`
 * full-resolution asset; otherwise take the largest sized variant and rewrite it to
 * `/originals/` (`toOriginals`), keeping the sized variant as a guaranteed-loadable
 * fallback (Pinterest doesn't always keep an original, so `/originals/` can 404 —
 * same fail-open rule as the DOM extractor). Returns `{ mediaUrl, mediaUrlFallback }`
 * with `mediaUrl: null` when the pin has no usable image.
 */
export function pickPinImages(images) {
  if (!images || typeof images !== "object") return { mediaUrl: null, mediaUrlFallback: null };

  const orig = images.orig && images.orig.url ? images.orig.url : null;
  const sized = Object.entries(images)
    .filter(([key, value]) => key !== "orig" && value && value.url)
    .map(([, value]) => value)
    .sort((a, b) => (b.width || 0) - (a.width || 0));
  const largest = sized.length ? sized[0].url : null;

  const mediaUrl = orig || (largest ? toOriginals(largest) : null);
  const mediaUrlFallback = mediaUrl && largest && mediaUrl !== largest ? largest : null;
  return { mediaUrl, mediaUrlFallback };
}

/**
 * Map one raw pin (a `BoardFeedResource` `data[]` entry) to a `BulkItem`, or `null`
 * if it has no id or no usable image (a doomed item is never enqueued). `cursor` is
 * threaded in by the paginator (the request bookmark for this pin's page).
 * `host` is the active tab's origin host so links match the session region.
 */
export function mapPinterestPin(pin, { host, cursor = null } = {}) {
  const pinId = pinIdFrom(pin);
  if (!pinId) return null;

  const { mediaUrl, mediaUrlFallback } = pickPinImages(pin.images);
  if (!mediaUrl) return null;

  const creator = pin.pinner || pin.native_creator || null;
  const seoUrl = pin.seo_url || `/pin/${pinId}/`;
  const originalURL = host ? `https://${host}${seoUrl}` : seoUrl;
  const isVideo = !!pin.is_video;

  const provenance = makeProvenance({
    platform: "pinterest",
    originalURL,
    mediaUrl,
    mediaUrlFallback,
    authorHandle: (creator && creator.username) || null,
    authorName: (creator && creator.full_name) || null,
    title: pin.title || pin.grid_title || pin.description || pin.auto_alt_text || null,
    rawMetadata: { pinId, isVideo, link: pin.link || null },
  });

  return { sourceId: pinId, mediaUrl, mediaUrlFallback, provenance, cursor };
}

/** Unwrap a resource response, throwing `PinterestResourceError` on any non-success
 * (auth 403, server error, malformed). Returns `{ items: rawData[], bookmark }`. */
function unwrapResource(json) {
  const response = json && json.resource_response;
  if (!response) throw new PinterestResourceError("missing resource_response");
  const httpStatus = response.http_status ?? null;
  if (response.status && response.status !== "success") {
    throw new PinterestResourceError(
      `resource ${response.status}: ${response.message || "error"}`, { httpStatus });
  }
  if (typeof httpStatus === "number" && httpStatus !== 200) {
    throw new PinterestResourceError(`resource http ${httpStatus}`, { httpStatus });
  }
  return {
    items: Array.isArray(response.data) ? response.data : [],
    bookmark: response.bookmark ?? null,
  };
}

/** Parse a `BoardFeedResource` page → `{ pins, bookmark }` (raw pins; the paginator
 * maps them so it can thread the per-page cursor). Throws on a non-success page. */
export function parseBoardFeedPage(json) {
  const { items, bookmark } = unwrapResource(json);
  return { pins: items, bookmark };
}

/** Parse a `BoardsResource` page → `{ boards: [{ id, name, url }], bookmark }`. For
 * a whole-account scope / a board-picker UI; a single-board sweep skips it. */
export function parseBoardsPage(json) {
  const { items, bookmark } = unwrapResource(json);
  const boards = items
    .filter((board) => board && board.id)
    .map((board) => ({ id: String(board.id), name: board.name || null, url: board.url || null }));
  return { boards, bookmark };
}

// ---------------------------------------------------------------------------
// Request builders
// ---------------------------------------------------------------------------

/** The `/resource/{name}/get/` URL with `source_url` + `data` (URL-encoded JSON),
 * plus a paginating `bookmarks:[cursor]` inside `options` when resuming. */
function buildResourceURL({ host, name, sourceUrl, options }) {
  const url = new URL(`https://${host}/resource/${name}/get/`);
  url.searchParams.set("source_url", sourceUrl);
  url.searchParams.set("data", JSON.stringify({ options, context: {} }));
  return url.toString();
}

/** `BoardFeedResource` URL for a board page (with the paginating cursor when set). */
export function buildBoardFeedURL({ host, boardId, boardUrl, pageSize = BOARD_FEED_PAGE_SIZE, cursor = null }) {
  const options = {
    board_id: boardId,
    board_url: boardUrl,
    currentFilter: -1,
    field_set_key: "react_grid_pin",
    filter_section_pins: true,
    sort: "default",
    layout: "default",
    page_size: pageSize,
    redux_normalize_feed: true,
    ...(cursor ? { bookmarks: [cursor] } : {}),
  };
  return buildResourceURL({ host, name: "BoardFeedResource", sourceUrl: boardUrl, options });
}

/** `BoardsResource` URL for a user's boards (with the paginating cursor when set). */
export function buildBoardsURL({ host, username, sourceUrl, pageSize = 25, cursor = null }) {
  const options = {
    page_size: pageSize,
    privacy_filter: "all",
    sort: "last_pinned_to",
    username,
    ...(cursor ? { bookmarks: [cursor] } : {}),
  };
  return buildResourceURL({ host, name: "BoardsResource", sourceUrl: sourceUrl || `/${username}/`, options });
}

/**
 * Pinterest's server-route identifier per resource — the `x-pinterest-pws-handler`
 * header. Live bisection (019 §T10) proved this is the SOLE gatekeeper the resource
 * endpoint checks: without it the request 403s; with it, 200 — `x-app-version`,
 * `x-pinterest-appstate`, `x-pinterest-source-url`, and `accept` are all irrelevant to
 * the 403. The bracketed segments are LITERAL route placeholders, NOT interpolated
 * (`www/[username]/[slug].js` is sent verbatim for every board). Only `BoardFeed` is
 * verified live; add other resources here as real requests are captured. A resource
 * with no entry sends no handler and will 403 — acceptable while that path is deferred.
 */
export const PWS_HANDLERS = {
  BoardFeedResource: "www/[username]/[slug].js",
};

/** The `/resource/{Name}/get/` name embedded in a resource URL, or null. */
export function resourceNameFromURL(url) {
  const match = new URL(url).pathname.match(/\/resource\/([^/]+)\/get\//);
  return match ? match[1] : null;
}

/**
 * Headers for a resource request. `x-pinterest-pws-handler` is REQUIRED (see
 * ``PWS_HANDLERS`` — the live gatekeeper). `X-APP-VERSION` (runtime-scraped) is also
 * app-identifying; `X-CSRFToken` comes from the `csrftoken` cookie;
 * `credentials:'include'` (set by the fetch wrapper) carries the HttpOnly session.
 * `appState` + `sourceUrl` are sent to mirror the real client (not strictly required
 * per the bisection, but cheap fidelity against Pinterest tightening its checks).
 */
export function boardFeedHeaders({ appVersion, csrfToken, pwsHandler, sourceUrl }) {
  const headers = {
    "X-APP-VERSION": appVersion,
    "X-CSRFToken": csrfToken,
    "X-Requested-With": "XMLHttpRequest",
    "x-pinterest-appstate": "active",
    Accept: "application/json, text/javascript, */*; q=0.01",
  };
  if (pwsHandler) headers["x-pinterest-pws-handler"] = pwsHandler;
  if (sourceUrl) headers["x-pinterest-source-url"] = sourceUrl;
  return headers;
}

// ---------------------------------------------------------------------------
// Paginators (async generators)
// ---------------------------------------------------------------------------

/** A `fetchJson` backed by the real `fetch` (via `fetchWithTimeout`), sending the
 * resource headers with `credentials:'include'`. Injected in tests. */
export function makeResourceFetch({ appVersion, csrfToken, fetchImpl = fetch } = {}) {
  return async (url) => {
    // The pws-handler + source-url are per-request: the handler maps to the resource
    // type, the source-url is the request's own `source_url` param.
    const parsed = new URL(url);
    const pwsHandler = PWS_HANDLERS[resourceNameFromURL(url)] || null;
    const sourceUrl = parsed.searchParams.get("source_url");
    const headers = boardFeedHeaders({ appVersion, csrfToken, pwsHandler, sourceUrl });
    const response = await fetchWithTimeout(
      url, { headers, credentials: "include" }, { fetchImpl });
    if (!response.ok) throw new PinterestResourceError(`http ${response.status}`, { httpStatus: response.status });
    return response.json();
  };
}

/**
 * Walk a board's pins, yielding a `BulkItem` per pin. `fetchJson(url)` returns the
 * parsed resource JSON. Each pin carries the bookmark that REQUESTED its page as its
 * `cursor`, so a checkpointed resume re-fetches that page. Terminates at `-end-` (or
 * an empty/absent bookmark). A fetch/parse error propagates — the engine catches it
 * and halts gracefully, preserving the checkpoint.
 */
export async function* enumerateBoardFeed(
  fetchJson, { host, boardId, boardUrl, pageSize = BOARD_FEED_PAGE_SIZE }, { cursor = null } = {}
) {
  let requestCursor = cursor;      // the bookmark used to fetch the CURRENT page
  const seenCursors = new Set();   // loop guard: never re-request the same bookmark
  let emptyPages = 0;

  while (true) {
    if (requestCursor) {
      if (seenCursors.has(requestCursor)) return;  // bookmark repeated → stop
      seenCursors.add(requestCursor);
    }

    const url = buildBoardFeedURL({ host, boardId, boardUrl, pageSize, cursor: requestCursor });
    const { pins, bookmark } = parseBoardFeedPage(await fetchJson(url));

    let yielded = 0;
    for (const pin of pins) {
      const item = mapPinterestPin(pin, { host, cursor: requestCursor });
      if (item) { yield item; yielded += 1; }
    }

    if (!bookmark || bookmark === END_BOOKMARK) return;  // end of feed
    // An empty page mid-stream is tolerated (Pinterest occasionally returns one),
    // but not forever — bail if the feed only ever returns empties.
    emptyPages = yielded === 0 ? emptyPages + 1 : 0;
    if (emptyPages >= MAX_EMPTY_PAGES) return;

    requestCursor = bookmark;
  }
}

/** Walk a user's boards, yielding `{ id, name, url }` (for a whole-account scope /
 * board-picker). Same cursor/termination contract as `enumerateBoardFeed`. */
export async function* enumerateBoards(
  fetchJson, { host, username, sourceUrl, pageSize = 25 }, { cursor = null } = {}
) {
  let requestCursor = cursor;
  const seenCursors = new Set();

  while (true) {
    if (requestCursor) {
      if (seenCursors.has(requestCursor)) return;
      seenCursors.add(requestCursor);
    }
    const url = buildBoardsURL({ host, username, sourceUrl, pageSize, cursor: requestCursor });
    const { boards, bookmark } = parseBoardsPage(await fetchJson(url));
    for (const board of boards) yield board;
    if (!bookmark || bookmark === END_BOOKMARK) return;
    requestCursor = bookmark;
  }
}

// ---------------------------------------------------------------------------
// The BulkSource driver (engine seam)
// ---------------------------------------------------------------------------

/**
 * A Pinterest board driver conforming to the engine's `BulkSource` seam. Bind the
 * session context (`fetchJson`, `host`, page size) once; `enumerate(board, { cursor })`
 * then walks that board's feed. `board` = `{ boardId, boardUrl }`.
 */
export function pinterestBoardDriver({ fetchJson, host, pageSize = BOARD_FEED_PAGE_SIZE }) {
  return {
    enumerate({ boardId, boardUrl }, { cursor = null } = {}) {
      return enumerateBoardFeed(fetchJson, { host, boardId, boardUrl, pageSize }, { cursor });
    },
  };
}
