// Atelier Capture — Pinterest extractor.
//
// Pinterest is client-rendered and often captured from the FEED (location.href =
// pinterest.com, not the pin). So the pin URL comes from the right-clicked link
// (context.linkUrl → /pin/{id}/) when present, and the image from the right-
// clicked src (or the largest i.pinimg image on a pin page), rewritten to
// `/originals/` with the rendered size kept as a fetch fallback.

import {
  hostname, hostIs, firstMeta, pathSegments, liveURL, firstPostURL, largestMedia,
  ogImage, toOriginals,
} from "./base.js";

export const pinterest = {
  platform: "pinterest",

  match(url) {
    const host = hostname(url);
    return hostIs(host, "pinterest.com") ||
      hostIs(host, "pinterest.co.uk") ||
      hostIs(host, "pin.it");
  },

  extract(harvest, context = {}) {
    const isPin = (u) => pathSegments(u)[0] === "pin";
    const url =
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], isPin) ||
      liveURL(harvest);
    const segments = pathSegments(url);
    const pinId = segments[0] === "pin" ? segments[1] || null : null;

    // Exact clicked pin image, else the biggest i.pinimg image on the page.
    // (s.pinimg.com share logos are excluded by the host pattern.)
    const clicked = /i\.pinimg\.com/.test(context.srcUrl || "") ? context.srcUrl : null;
    const rendered = clicked || largestMedia(harvest, /i\.pinimg\.com/)?.src || null;
    const mediaUrl = toOriginals(rendered) || ogImage(harvest);
    // `/originals/` can 404 (Pinterest doesn't always keep an original); the
    // rendered size is guaranteed loadable, so hand it back as a fetch fallback.
    const mediaUrlFallback = rendered && mediaUrl !== rendered ? rendered : null;

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
