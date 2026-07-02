// Atelier Capture — Instagram extractor.

import {
  hostname, hostIs, meta, firstMeta, pathSegments, canonicalURL, ogImage,
} from "./base.js";

export const instagram = {
  platform: "instagram",

  match(url) {
    return hostIs(hostname(url), "instagram.com");
  },

  extract(harvest) {
    const url = canonicalURL(harvest);
    const segments = pathSegments(url);
    // /p/{shortcode}/ or /reel/{shortcode}/
    const shortcode =
      segments[0] === "p" || segments[0] === "reel" ? segments[1] || null : null;

    // og:title is typically "Name (@handle) on Instagram: …".
    const ogTitle = meta(harvest, "og:title") || "";
    const handleMatch = ogTitle.match(/\(@([A-Za-z0-9._]+)\)/);

    return {
      platform: "instagram",
      originalURL: url,
      mediaUrl: ogImage(harvest),
      authorHandle: handleMatch ? "@" + handleMatch[1] : null,
      authorName: null,
      title: firstMeta(harvest, ["og:description"]) || harvest.title,
      rawMetadata: shortcode ? { shortcode } : {},
    };
  },
};
