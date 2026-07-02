// Atelier Capture — Pinterest extractor.

import {
  hostname, hostIs, firstMeta, pathSegments, canonicalURL, ogImage,
} from "./base.js";

export const pinterest = {
  platform: "pinterest",

  match(url) {
    return hostIs(hostname(url), "pinterest.com") ||
      hostIs(hostname(url), "pinterest.co.uk") ||
      hostIs(hostname(url), "pin.it");
  },

  extract(harvest) {
    const url = canonicalURL(harvest);
    const segments = pathSegments(url);
    // /pin/{id}/
    const pinId = segments[0] === "pin" ? segments[1] || null : null;

    return {
      platform: "pinterest",
      originalURL: url,
      mediaUrl: ogImage(harvest),
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: pinId ? { pinId } : {},
    };
  },
};
