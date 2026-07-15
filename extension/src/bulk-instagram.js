// Atelier Capture — Instagram saved-posts BulkSource parsing (002 · B3, [1A][3A][7A]).
//
// Instagram serves the saved feed from `…/api/v1/feed/saved/posts/` (REST, verified live
// 2026-07-15 — 002 §B0). The MAIN-world hook (instagram-hook.js) captures those RESPONSES
// and forwards them; this module is the PURE half: parse one intercepted saved-feed
// response into `BulkItem`s + the pagination signal.
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

/** IG `media_type` discriminants. */
export const IG_MEDIA_TYPE = Object.freeze({ image: 1, video: 2, carousel: 8 });

/** True for a saved-posts feed request URL (`…/api/v1/feed/saved/posts/`, ± `?max_id=`).
 * KEEP IN SYNC with instagram-hook.js `isSavedFeedRequest` — the same predicate the hook
 * uses to decide what to forward. Kept here too so the drift canary can verify it. */
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
export function parseSavedFeedPage(json, { host = "www.instagram.com" } = {}) {
  const challenge = detectChallenge(json);
  if (challenge) {
    return { items: [], endOfFeed: false, nextMaxId: null, error: new InstagramChallengeError(challenge) };
  }

  const rawItems = json && Array.isArray(json.items) ? json.items : [];
  const nextMaxId = json && json.next_max_id != null ? String(json.next_max_id) : null;
  const items = [];
  for (const wrapper of rawItems) {
    const media = wrapper && wrapper.media ? wrapper.media : wrapper;
    for (const item of mapSavedMedia(media, { host, cursor: nextMaxId })) items.push(item);
  }

  // End of feed when IG says no more (or the field is absent — a malformed/empty page
  // ends the sweep cleanly rather than looping, mirroring X's empty-page terminator).
  const endOfFeed = !(json && json.more_available);
  return { items, endOfFeed, nextMaxId, error: null };
}
