// Atelier Capture — rednote (Xiaohongshu) extractor.
//
// One product on TWO domains — `rednote.com` (international) and
// `xiaohongshu.com` (mainland) — so both are matched here and both appear in
// `manifest.json` host_permissions. Client-rendered like the other SPA sites:
// the note URL comes from the right-clicked link (`/explore/{noteId}`) when the
// capture starts from a feed or board, else the live URL; og:* is stale/generic.
//
// MEDIA (verified 2026-07-31 against a live note): the page renders a SIGNED,
// RESIZED webp —
//   https://sns-web-i10.rednotecdn.com/<ts>/<sig>/<key>!nc_n_webp_mw_1
// — typically a 270 px thumbnail. Dropping the timestamp/signature segments and
// the `!…` transform suffix, and asking a plain image node for the bare key —
//   http://sns-i27.rednotecdn.com/<key>
// — is PUBLIC, UNSIGNED, and returns the full-resolution original (2022×2696 and
// up). So the bare form is preferred and the signed webp is kept as
// `mediaUrlFallback`, the same prefer-original/keep-fallback rule Pinterest uses
// for `/originals/`.

import {
  hostname, hostIs, firstMeta, pathSegments, splitPathname, liveURL, firstPostURL,
  largestMedia, ogImage,
} from "./base.js";

/** The plain image node that serves unsigned, untransformed originals. */
const ORIGIN_HOST = "sns-i27.rednotecdn.com";

/** Any rednote CDN URL (images `sns-i*` / `sns-web-i*`, video `sns-v*`). */
const CDN = /(^|\/\/|\.)rednotecdn\.com\//;

/**
 * Rewrite a rednote CDN URL to its unsigned full-resolution original, or return
 * `src` unchanged when it is not a rednote CDN URL / is unparseable.
 *
 * The object key is the LAST path segment with any `!<transform>` suffix removed;
 * every preceding segment is signing material. Already-bare URLs rewrite to
 * themselves, so this is idempotent.
 */
export function toRednoteOriginal(src) {
  if (!src || !CDN.test(src)) return src || null;
  try {
    const url = new URL(src);
    if (!hostIs(url.hostname.toLowerCase(), "rednotecdn.com")) return src;
    const segments = splitPathname(url.pathname);
    const last = segments[segments.length - 1] || "";
    const key = last.split("!")[0];
    if (!key) return src;
    return `http://${ORIGIN_HOST}/${key}`;
  } catch {
    return src;
  }
}

export const rednote = {
  platform: "rednote",

  match(url) {
    const host = hostname(url);
    // `hostIs` matches the apex or a subdomain but NOT a suffix spoof
    // (`rednote.com.evil.com` ends with `.evil.com`).
    return hostIs(host, "rednote.com") || hostIs(host, "xiaohongshu.com");
  },

  extract(harvest, context = {}) {
    // A note lives at `/explore/{id}`, and — from a profile or a search result —
    // at `/discovery/item/{id}`. Both carry the same note id.
    const isNote = (u) => {
      const segments = pathSegments(u);
      return (segments[0] === "explore" && !!segments[1]) ||
        (segments[0] === "discovery" && segments[1] === "item" && !!segments[2]);
    };
    const url =
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], isNote) ||
      liveURL(harvest);
    const segments = pathSegments(url);
    const noteId =
      segments[0] === "explore" ? segments[1] || null :
      segments[0] === "discovery" && segments[1] === "item" ? segments[2] || null :
      null;

    // Exact clicked image, else the biggest rednote CDN image on the note page.
    const clicked = CDN.test(context.srcUrl || "") ? context.srcUrl : null;
    const rendered = clicked || largestMedia(harvest, CDN)?.src || null;
    const mediaUrl = toRednoteOriginal(rendered) || ogImage(harvest);
    // The signed webp always loads; the bare original is the one that could 404,
    // so keep the rendered URL as the fetch fallback.
    const mediaUrlFallback = rendered && mediaUrl !== rendered ? rendered : null;

    return {
      platform: "rednote",
      originalURL: url,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: noteId ? { noteId } : {},
    };
  },
};
