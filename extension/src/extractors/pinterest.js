// Atelier Capture — Pinterest extractor.
//
// Pinterest is client-rendered: canonical is frequently the site root and
// og:image is the generic Pinterest share logo (s.pinimg.com), so we take the
// live URL for the pin and the largest `i.pinimg.com` image from the DOM (the
// closeup pin is the biggest), rewritten to `/originals/` for full resolution.

import {
  hostname, hostIs, firstMeta, pathSegments, liveURL, largestMedia, ogImage,
} from "./base.js";

/** Rewrite an i.pinimg sized path (…/474x/…) to full resolution (…/originals/…). */
function fullResolution(src) {
  if (!src) return null;
  return src.replace(/i\.pinimg\.com\/\d+x(?:\d+)?\//, "i.pinimg.com/originals/");
}

export const pinterest = {
  platform: "pinterest",

  match(url) {
    const host = hostname(url);
    return hostIs(host, "pinterest.com") ||
      hostIs(host, "pinterest.co.uk") ||
      hostIs(host, "pin.it");
  },

  extract(harvest) {
    const url = liveURL(harvest);
    const segments = pathSegments(url);
    // /pin/{id}/
    const pinId = segments[0] === "pin" ? segments[1] || null : null;

    // The closeup pin is the biggest i.pinimg.com image; related-pin thumbnails
    // are smaller. (s.pinimg.com share logos are excluded by the host pattern.)
    const pin = largestMedia(harvest, /i\.pinimg\.com/);
    const rendered = pin?.src || null;
    const mediaUrl = fullResolution(rendered) || ogImage(harvest);
    // `/originals/` can 404 (Pinterest doesn't always keep an original); the
    // rendered size is guaranteed loadable, so hand it back as a fetch fallback.
    const mediaUrlFallback =
      rendered && mediaUrl !== rendered ? rendered : null;

    return {
      platform: "pinterest",
      originalURL: url,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: pinId ? { pinId } : {},
    };
  },
};
