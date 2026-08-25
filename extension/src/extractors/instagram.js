// Atelier Capture — Instagram extractor.
//
// Client-rendered: prefer the right-clicked link/image, else the live URL + the
// largest post image from the DOM (scontent.cdninstagram.com / fbcdn.net);
// og:image is a fallback.

import {
  hostname, hostIs, meta, firstMeta, pathSegments, liveURL, firstPostURL, largestMedia, ogImage,
} from "./base.js";

/**
 * A post URL reduced to its canonical permalink, `/{p|reel}/{code}/`.
 *
 * The same defect [432](../../.change-log/432-the-tweet-with-only-an-analytics-link.md)
 * found on X, and worse here: measured on a live mobile-width feed, **every** post link
 * was a `/liked_by/` link and not one bare `/p/{code}/` appeared. `isPost` accepts it
 * (`pathSegments(u)[0]` is still `p`) and `shortcode` still resolves at `segments[1]`, so
 * the capture looks entirely successful — but `originalURL` carries the sub-page, and 18A
 * dedup keys on provenance. Every feed capture would fork, not merely the occasional one.
 *
 * The trailing slash is deliberate and is NOT a mistake copied from X's version, which has
 * none: each platform normalizes to the form its OWN bulk mapper composes, so the two
 * producers agree per platform. `bulk-instagram.js:179` builds
 * `https://{host}/{p|reel}/{code}/`; `bulk-twitter.js:280` builds a slash-less status URL.
 *
 * A non-post URL (a profile, the feed root) is passed through untouched.
 */
export function toPostPermalink(url) {
  const segments = pathSegments(url);
  if (!["p", "reel"].includes(segments[0]) || !segments[1]) return url;
  try {
    return `${new URL(url).origin}/${segments[0]}/${segments[1]}/`;
  } catch {
    return url;
  }
}

export const instagram = {
  platform: "instagram",

  match(url) {
    return hostIs(hostname(url), "instagram.com");
  },

  extract(harvest, context = {}) {
    const isPost = (u) => ["p", "reel"].includes(pathSegments(u)[0]);
    // Normalized AFTER resolution, so a sub-page URL from any source lands on the
    // permalink — the same shape twitter.js uses, for the same reason.
    const url = toPostPermalink(
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], isPost) ||
      liveURL(harvest)
    );
    const segments = pathSegments(url);
    const shortcode =
      segments[0] === "p" || segments[0] === "reel" ? segments[1] || null : null;

    // og:title is typically "Name (@handle) on Instagram: …".
    const ogTitle = meta(harvest, "og:title") || "";
    const handleMatch = ogTitle.match(/\(@([A-Za-z0-9._]+)\)/);

    const clicked = /(cdninstagram\.com|fbcdn\.net)/.test(context.srcUrl || "") ? context.srcUrl : null;
    const mediaUrl =
      clicked || largestMedia(harvest, /(cdninstagram\.com|fbcdn\.net)/)?.src || ogImage(harvest);

    return {
      platform: "instagram",
      originalURL: url,
      mediaUrl,
      authorHandle: handleMatch ? "@" + handleMatch[1] : null,
      authorName: null,
      title: firstMeta(harvest, ["og:description"]) || harvest.title,
      rawMetadata: shortcode ? { shortcode } : {},
    };
  },
};
