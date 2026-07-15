// Atelier Capture — Instagram saved-posts BulkSource (002 · O2, [1A][3A][7A]).
//
// Instagram serves the saved feed from `…/api/v1/feed/saved/posts/` (REST, verified live).
// We REPLAY that endpoint ourselves (service-worker cursor replay, O2) — a same-origin
// credentialled `fetch` paginated by `next_max_id` — rather than intercept the page's
// traffic: live testing proved IG's own saved-feed request bypasses the page's fetch/XHR
// (un-hookable) and its infinite scroll only fires on a trusted wheel (un-automatable), so
// the X-style interception can't work here. This file is BOTH halves: the PURE parser
// (`parseSavedFeedPage` → `BulkItem`s + cursor) and the PULL driver (`instagramSavedDriver`),
// mirroring the Pinterest driver's shape.
//
// FAN-OUT (decision 1A): unlike X (one tweet → one item with a media[] payload), a saved
// post fans out to ONE `BulkItem` PER MEDIA via the plain-image path — `sourceId` = IG's
// per-media `pk`, no `content` descriptor. This mirrors the Pinterest driver: for a
// design-reference library the images ARE the substance of a save, and per-media keying
// makes engine dedup-skip work at the picture level. A carousel → one item per child; a
// single image/reel → one item. A reel keeps its POSTER as the card (7A) and stashes the
// best progressive MP4 in `rawMetadata.videoUrl`, so the existing resolve-video toggle
// downloads it with no extra network call.
//
// A yielded `BulkItem` matches the engine seam (identical to Pinterest):
//   { sourceId, mediaUrl, mediaUrlFallback, provenance, cursor }
// where `cursor` is the page's `next_max_id` (the checkpoint token).

import { makeProvenance } from "./extractors/base.js";
import { fetchWithTimeout } from "./net.js";

/** IG `media_type` discriminants. */
export const IG_MEDIA_TYPE = Object.freeze({ image: 1, video: 2, carousel: 8 });

/** The saved-feed endpoint path and the ONE required request header value. Verified live
 * (2026-07-16, doc 002 §mechanism): `GET /api/v1/feed/saved/posts/` with
 * `x-ig-app-id: 936619743392459` + `credentials:'include'` returns 200 (the session
 * cookie authorizes it); NO header → 400; `x-csrftoken` / `x-ig-www-claim` / `x-asbd-id`
 * are NOT required. `x-ig-app-id` is the public IG-web app id — a constant, same for
 * every web session, so nothing needs scraping (contrast Pinterest's app-version). */
export const SAVED_FEED_PATH = "/api/v1/feed/saved/posts/";
export const IG_WEB_APP_ID = "936619743392459";

/** True for a saved-posts feed request URL (`…/api/v1/feed/saved/posts/`, ± `?max_id=`).
 * The route the driver builds + the drift canary verifies; a sanity check that the path
 * constant hasn't drifted. */
export function isSavedFeedRequest(url) {
  return typeof url === "string" && /\/api\/v1\/feed\/saved\/posts\//.test(url);
}

/** Thrown into the sweep when IG returns an account challenge (checkpoint / login /
 * rate-limit). The hook forwards the 4xx body status-blind (3A); the source re-raises
 * this from `enumerate` so the engine HALTS RESUMABLE — a challenge pauses the sweep
 * instead of hammering a flagged account. Carries the `kind` for honest UI copy. */
export class InstagramChallengeError extends Error {
  constructor(kind) {
    super(`Instagram challenge: ${kind}`);
    this.name = "InstagramChallengeError";
    this.challenge = true;
    this.kind = kind;
  }
}

/**
 * Recognize an anti-bot / challenge response → a challenge kind, or null for a normal
 * feed page. IG serves these with a 4xx the hook forwards status-blind (3A). The shapes
 * are the documented IG private-web-API failure bodies (`status:"fail"` + a `message` /
 * flag); matched permissively so a wording tweak still trips the halt rather than the
 * sweep charging on against a flagged account.
 */
export function detectChallenge(json) {
  if (!json || typeof json !== "object") return null;
  const message = typeof json.message === "string" ? json.message.toLowerCase() : "";
  if (json.checkpoint_required || json.checkpoint_url || message.includes("checkpoint")) {
    return "checkpoint_required";
  }
  if (json.require_login || message.includes("login_required")) return "login_required";
  if (message.includes("challenge_required")) return "challenge_required";
  // Rate-limit / spam feedback: "Please wait a few minutes before you try again." etc.
  if (json.spam || json.feedback_required ||
      message.includes("wait a few minutes") || message.includes("try again")) {
    return "rate_limited";
  }
  // A bare failure with no recognizable reason: treat as a challenge too (halt, don't
  // burn) — a `status:"fail"` on the saved feed is never a normal page.
  if (json.status === "fail") return "unknown_fail";
  return null;
}

/** Largest-by-width image candidate URL + a smaller guaranteed-loadable fallback, from an
 * `image_versions2`. Sorted defensively (candidates are observed largest-first, but IG
 * could reorder — 002 §B0). `{ mediaUrl: null }` when there's no usable image. */
export function pickImage(imageVersions2) {
  const candidates = (imageVersions2 && imageVersions2.candidates) || [];
  const usable = candidates.filter((c) => c && c.url);
  if (usable.length === 0) return { mediaUrl: null, mediaUrlFallback: null };
  const sorted = [...usable].sort((a, b) => (b.width || 0) - (a.width || 0));
  const mediaUrl = sorted[0].url;
  const mediaUrlFallback = sorted.length > 1 ? sorted[sorted.length - 1].url : null;
  return { mediaUrl, mediaUrlFallback };
}

/** The best (largest-by-width) progressive MP4 from a `video_versions[]`, or null. */
export function pickVideo(videoVersions) {
  const usable = (videoVersions || []).filter((v) => v && v.url);
  if (usable.length === 0) return null;
  return [...usable].sort((a, b) => (b.width || 0) - (a.width || 0))[0].url;
}

/** The post author `{ handle: "@name", name, username }` from `media.user`. */
function igAuthor(media) {
  const user = media.user || {};
  const username = user.username || null;
  return { handle: username ? `@${username}` : null, name: user.full_name || null, username };
}

/** Map ONE media node (a top-level single, or a carousel CHILD) to a `BulkItem`, or null
 * if it has no `pk` or no usable image (a doomed item is never enqueued). `ctx` carries
 * the post-level fields shared across a carousel's children (author, caption, permalink)
 * plus the child `index` and the page `cursor`. */
function mapSingleMedia(media, ctx) {
  const pk = media && media.pk != null ? String(media.pk) : null;
  if (!pk) return null;

  const { mediaUrl, mediaUrlFallback } = pickImage(media.image_versions2);
  if (!mediaUrl) return null;

  const isVideo = media.media_type === IG_MEDIA_TYPE.video ||
    (Array.isArray(media.video_versions) && media.video_versions.length > 0);
  const videoUrl = isVideo ? pickVideo(media.video_versions) : null;

  return {
    sourceId: pk,
    mediaUrl,
    mediaUrlFallback,
    cursor: ctx.cursor,
    provenance: makeProvenance({
      platform: "instagram",
      originalURL: ctx.postUrl,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: ctx.author.handle,
      authorName: ctx.author.name,
      title: ctx.caption,
      rawMetadata: {
        pk,
        shortcode: ctx.code || null,
        kind: isVideo ? "video" : "image",
        carouselIndex: ctx.index,
        videoUrl,
      },
    }),
  };
}

/**
 * Map one saved-feed post to `BulkItem`s — fanned out per media (1A). A carousel
 * (`media_type` 8) yields one item per `carousel_media[]` child (each its own `pk`); a
 * single image/reel yields one. `cursor` is threaded in by the parser (the page's
 * `next_max_id`). Returns `[]` for a tombstone / unusable post.
 */
export function mapSavedMedia(media, { host = "www.instagram.com", cursor = null } = {}) {
  if (!media || typeof media !== "object") return [];

  const author = igAuthor(media);
  const caption = media.caption && media.caption.text ? media.caption.text : null;
  const code = media.code || null;
  // A reel permalinks under /reel/, everything else under /p/ (both resolve, but the
  // honest path is nicer provenance). Carousel children share the POST's permalink.
  const segment = media.product_type === "clips" ? "reel" : "p";
  const postUrl = code ? `https://${host}/${segment}/${code}/` : `https://${host}/`;
  const ctx = { author, caption, code, postUrl };

  if (media.media_type === IG_MEDIA_TYPE.carousel && Array.isArray(media.carousel_media)) {
    const items = [];
    media.carousel_media.forEach((child, index) => {
      const item = mapSingleMedia(child, { ...ctx, cursor, index });
      if (item) items.push(item);
    });
    return items;
  }
  const item = mapSingleMedia(media, { ...ctx, cursor, index: 0 });
  return item ? [item] : [];
}

/**
 * Parse one intercepted saved-feed response into `{ items, endOfFeed, nextMaxId, error }`.
 *   · `items`     — the fanned-out `BulkItem`s (1A), each stamped with the page cursor.
 *   · `endOfFeed` — true when IG reports `more_available:false` (or omits it) — the
 *                   definitive end (there is no `-end-` sentinel). A stall while
 *                   `more_available` is still true is handled by the source, not here.
 *   · `nextMaxId` — the pagination / checkpoint cursor (null on the last page).
 *   · `error`     — an `InstagramChallengeError` when the body is a challenge (3A); the
 *                   source re-raises it so the engine halts resumable. Never throws.
 */
export function parseSavedFeedPage(json, { host = "www.instagram.com", cursor = null } = {}) {
  const challenge = detectChallenge(json);
  if (challenge) {
    return { items: [], endOfFeed: false, nextMaxId: null, error: new InstagramChallengeError(challenge) };
  }

  const rawItems = json && Array.isArray(json.items) ? json.items : [];
  const nextMaxId = json && json.next_max_id != null ? String(json.next_max_id) : null;
  const items = [];
  for (const wrapper of rawItems) {
    const media = wrapper && wrapper.media ? wrapper.media : wrapper;
    // Stamp each item with the cursor that REQUESTED this page (`cursor`), NOT next_max_id,
    // so a checkpointed resume re-fetches the SAME page and re-yields it (dedup makes the
    // overlap idempotent) — the Pinterest resume contract, never skipping a gap.
    for (const item of mapSavedMedia(media, { host, cursor })) items.push(item);
  }

  // End of feed when IG says no more (or the field is absent — a malformed/empty page
  // ends the sweep cleanly rather than looping, mirroring X's empty-page terminator).
  const endOfFeed = !(json && json.more_available);
  return { items, endOfFeed, nextMaxId, error: null };
}

// ---------------------------------------------------------------------------
// The saved-feed DRIVER (engine seam) — service-worker cursor replay (002 · O2).
//
// Unlike X (which we can't paginate — the request is un-hookable and infinite scroll
// needs a trusted wheel), IG's saved feed IS a plain credentialled REST endpoint we can
// replay ourselves: same-origin `fetch` with `credentials:'include'` carries the session,
// `x-ig-app-id` authorizes it, and `next_max_id` pages it. So this is a PULL driver
// (Pinterest-style), not a push→pull hook source — no MAIN-world hook, no auto-scroll.
// ---------------------------------------------------------------------------

/** Raised when a saved-feed request isn't a usable page (non-200, or a challenge the
 * body-shape recognizer didn't catch) — carries the http status so the engine's halt can
 * reason about it. Enumeration throws HALT the sweep resumable (never burn a flagged
 * account); the checkpoint is preserved so the user resumes after solving the challenge. */
export class InstagramSavedError extends Error {
  constructor(message, { httpStatus = null } = {}) {
    super(message);
    this.name = "InstagramSavedError";
    this.httpStatus = httpStatus;
  }
}

/** A stop-gap against a pathological feed that returns empty pages with an ever-changing
 * cursor (never `more_available:false`): give up after this many CONSECUTIVE empties. */
const MAX_EMPTY_PAGES = 3;

/** The saved-feed request URL for a page (with the paginating `?max_id=` cursor when set). */
export function buildSavedFeedURL({ host = "www.instagram.com", cursor = null } = {}) {
  const url = new URL(SAVED_FEED_PATH, `https://${host}`);
  if (cursor) url.searchParams.set("max_id", cursor);
  return url.toString();
}

/** Headers for a saved-feed request. Only `x-ig-app-id` is required (verified live);
 * `x-requested-with` mirrors the real client cheaply. The session cookie rides via
 * `credentials:'include'` (set by the fetch wrapper), so nothing is scraped. */
export function savedFeedHeaders() {
  return { "x-ig-app-id": IG_WEB_APP_ID, "x-requested-with": "XMLHttpRequest" };
}

/** A `fetchJson(url)` backed by the real `fetch` (via `fetchWithTimeout`), sending the
 * saved-feed headers with `credentials:'include'`. Returns `{ httpStatus, json }` (the
 * body is read even on a 4xx so a challenge body can be classified). Injected in tests.
 * `log` is an optional diagnostic sink (the content script wires it to console). */
export function makeSavedFeedFetch({ fetchImpl = fetch, log = () => {} } = {}) {
  return async (url) => {
    let response;
    try {
      response = await fetchWithTimeout(
        url, { headers: savedFeedHeaders(), credentials: "include" }, { fetchImpl });
    } catch (error) {
      log("IG fetch THREW (network/CORS/abort):", String(error));
      throw error;
    }
    let json = {};
    try { json = await response.json(); } catch { json = {}; }
    log("IG fetch status", response.status,
      "items", Array.isArray(json.items) ? json.items.length : "none",
      "more", json.more_available, json.message ? "msg=" + json.message : "");
    return { httpStatus: response.status, json };
  };
}

/**
 * Walk the saved feed, yielding a `BulkItem` per media (fanned out, 1A). `fetchJson(url)`
 * returns `{ httpStatus, json }`. Each item carries the cursor that REQUESTED its page, so
 * a checkpointed resume re-fetches that page. Terminates at `more_available:false` (or an
 * absent `next_max_id`). A challenge / non-200 THROWS — the engine catches it and halts
 * the sweep resumable, preserving the checkpoint (halt, don't burn — 3A).
 */
export async function* enumerateSavedFeed(
  fetchJson, { host = "www.instagram.com" } = {}, { cursor = null } = {}
) {
  let requestCursor = cursor;      // the max_id used to fetch the CURRENT page
  const seenCursors = new Set();   // loop guard: never re-request the same cursor
  let emptyPages = 0;

  while (true) {
    if (requestCursor) {
      if (seenCursors.has(requestCursor)) return;  // cursor repeated → stop
      seenCursors.add(requestCursor);
    }

    const url = buildSavedFeedURL({ host, cursor: requestCursor });
    const { httpStatus, json } = await fetchJson(url);

    // A challenge body (checkpoint / login / rate-limit) → halt resumable (3A).
    const challenge = detectChallenge(json);
    if (challenge) throw new InstagramChallengeError(challenge);
    // Any other non-200 is an error we halt on rather than silently ending the sweep.
    if (httpStatus !== 200) throw new InstagramSavedError(`saved feed http ${httpStatus}`, { httpStatus });

    const page = parseSavedFeedPage(json, { host, cursor: requestCursor });
    let yielded = 0;
    for (const item of page.items) { yield item; yielded += 1; }

    if (page.endOfFeed || !page.nextMaxId) return;  // IG says no more, or no cursor to continue
    emptyPages = yielded === 0 ? emptyPages + 1 : 0;
    if (emptyPages >= MAX_EMPTY_PAGES) return;
    requestCursor = page.nextMaxId;
  }
}

/**
 * A saved-feed driver conforming to the engine's `BulkSource` seam. Bind the session
 * context (`fetchJson`, `host`) once; `enumerate(input, { cursor })` then walks the feed.
 * `input` is ignored (there's one flat saved feed — 6A), mirroring how the X driver
 * ignores its input.
 */
export function instagramSavedDriver({ fetchJson, host = "www.instagram.com" }) {
  return {
    enumerate(_input, { cursor = null } = {}) {
      return enumerateSavedFeed(fetchJson, { host }, { cursor });
    },
  };
}
