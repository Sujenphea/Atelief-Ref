// Atelier Capture — rednote (Xiaohongshu) extractor.
//
// One product on TWO domains — `rednote.com` (international) and
// `xiaohongshu.com` (mainland) — so both are matched here and both appear in
// `manifest.json` host_permissions. Client-rendered like the other SPA sites:
// the note URL comes from the right-clicked link (`/explore/{noteId}`) when the
// capture starts from a feed or board, else the live URL; og:* is stale/generic.
//
// MEDIA (verified 2026-07-31 against a live note, re-verified 2026-09-13 against
// two live captures): the page renders a SIGNED, RESIZED webp —
//   https://sns-web-i10.rednotecdn.com/<ts>/<sig>/<key>!nc_n_webp_mw_1
// — typically a 270 px thumbnail. Dropping the timestamp/signature segments and
// the `!…` transform suffix, and asking a plain image node for the bare key —
//   http://sns-i27.rednotecdn.com/<key>
// — is PUBLIC, UNSIGNED, and returns the full-resolution original (2022×2696 and
// up). So the bare form is preferred and the signed webp is kept as
// `mediaUrlFallback`, the same prefer-original/keep-fallback rule Pinterest uses
// for `/originals/`.
//
// `<key>` IS NOT ALWAYS ONE SEGMENT — a note's `image_list` images are keyed
// `oss-sg/spectrum/<id>`. See `toRednoteOriginal` below; getting this wrong is a
// silent 404 masked by the fallback, not a visible failure.

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
 * `src` unchanged when it is not a signed rednote CDN URL / is unparseable.
 *
 * A signed URL is `/<timestamp>/<signature>/<key>` — the first TWO segments are
 * signing material and everything after them is the object key. The key is NOT
 * always one segment: a note's `image_list` images are keyed
 * `oss-sg/spectrum/<id>` (three segments in the path, two of them part of the
 * key), while a board-feed cover is keyed `<id>` (one). Reading only the LAST
 * segment silently dropped the `oss-sg/spectrum/` prefix and built a 404, which
 * `mediaUrlFallback` then masked as a 5x quality loss (240 KB original -> 47 KB
 * signed webp) with no error — see 098 D2 / changelog 467.
 *
 * Verified over 184 URLs from two live captures (2026-09-13): dropping the two
 * signing segments agrees with the API's own `file_id` on all 184, where the
 * last-segment rule disagrees on 36. `file_id` is therefore not read here — it
 * would corroborate, not correct, and it is absent (`""`) on every board cover.
 *
 * Idempotent: output always lands on `ORIGIN_HOST`, and a URL already there is
 * returned untouched rather than re-parsed (its path is a bare key, so dropping
 * two segments would mangle a multi-segment one). A path too short to hold a
 * signing prefix AND a key (`/avatar/<id>`) is likewise left alone.
 */
export function toRednoteOriginal(src) {
  if (!src || !CDN.test(src)) return src || null;
  try {
    const url = new URL(src);
    const host = url.hostname.toLowerCase();
    if (!hostIs(host, "rednotecdn.com")) return src;
    // Already canonical — the only URLs on this host are bare keys.
    if (host === ORIGIN_HOST) return src;
    const segments = splitPathname(url.pathname);
    // Fewer than three segments cannot be `<timestamp>/<signature>/<key>`, so
    // there is no signing prefix to strip and nothing to canonicalize.
    if (segments.length < 3) return src;
    const key = segments.slice(2).join("/").split("!")[0];
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
