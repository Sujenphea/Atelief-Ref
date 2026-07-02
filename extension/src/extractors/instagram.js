// Atelier Capture — Instagram extractor.
//
// Client-rendered: prefer the live URL + the largest post image from the DOM
// (scontent.cdninstagram.com / fbcdn.net); og:image is a fallback.

import {
  hostname, hostIs, meta, firstMeta, pathSegments, liveURL, largestMedia, ogImage,
} from "./base.js";

export const instagram = {
  platform: "instagram",

  match(url) {
    return hostIs(hostname(url), "instagram.com");
  },

  extract(harvest) {
    const url = liveURL(harvest);
    const segments = pathSegments(url);
    // /p/{shortcode}/ or /reel/{shortcode}/
    const shortcode =
      segments[0] === "p" || segments[0] === "reel" ? segments[1] || null : null;

    // og:title is typically "Name (@handle) on Instagram: …".
    const ogTitle = meta(harvest, "og:title") || "";
    const handleMatch = ogTitle.match(/\(@([A-Za-z0-9._]+)\)/);

    const photo = largestMedia(harvest, /(cdninstagram\.com|fbcdn\.net)/);
    const mediaUrl = photo?.src || ogImage(harvest);

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
