// Atelier Capture — Cosmos extractor.
//
// Client-rendered: prefer the live URL + the largest element image from the DOM
// (images.cosmos.so / cosmos CDN); og:image is a fallback.

import {
  hostname, hostIs, firstMeta, pathSegments, liveURL, largestMedia, ogImage,
} from "./base.js";

export const cosmos = {
  platform: "cosmos",

  match(url) {
    return hostIs(hostname(url), "cosmos.so");
  },

  extract(harvest) {
    const url = liveURL(harvest);
    const segments = pathSegments(url);
    // /e/{id} (element) or /{cluster}
    const elementId = segments[0] === "e" ? segments[1] || null : null;

    const photo = largestMedia(harvest, /cosmos\.so/);
    const mediaUrl = photo?.src || ogImage(harvest);

    return {
      platform: "cosmos",
      originalURL: url,
      mediaUrl,
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: elementId ? { elementId } : {},
    };
  },
};
