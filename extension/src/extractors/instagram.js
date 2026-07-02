// Atelier Capture — Instagram extractor.
//
// Client-rendered: prefer the right-clicked link/image, else the live URL + the
// largest post image from the DOM (scontent.cdninstagram.com / fbcdn.net);
// og:image is a fallback.

import {
  hostname, hostIs, meta, firstMeta, pathSegments, liveURL, firstPostURL, largestMedia, ogImage,
} from "./base.js";

export const instagram = {
  platform: "instagram",

  match(url) {
    return hostIs(hostname(url), "instagram.com");
  },

  extract(harvest, context = {}) {
    const isPost = (u) => ["p", "reel"].includes(pathSegments(u)[0]);
    const url =
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], isPost) ||
      liveURL(harvest);
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
