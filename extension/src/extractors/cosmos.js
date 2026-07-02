// Atelier Capture — Cosmos extractor.

import {
  hostname, hostIs, firstMeta, pathSegments, canonicalURL, ogImage,
} from "./base.js";

export const cosmos = {
  platform: "cosmos",

  match(url) {
    return hostIs(hostname(url), "cosmos.so");
  },

  extract(harvest) {
    const url = canonicalURL(harvest);
    const segments = pathSegments(url);
    // /e/{id} (element) or /{cluster}
    const elementId = segments[0] === "e" ? segments[1] || null : null;

    return {
      platform: "cosmos",
      originalURL: url,
      mediaUrl: ogImage(harvest),
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: elementId ? { elementId } : {},
    };
  },
};
