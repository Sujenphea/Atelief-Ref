// Atelier Capture — Cosmos extractor.
//
// Client-rendered: prefer the right-clicked link/image, else the live URL + the
// largest element image from the DOM (images.cosmos.so / cosmos CDN); og:image is
// a fallback.

import {
  hostname, hostIs, firstMeta, pathSegments, liveURL, firstPostURL, largestMedia, ogImage,
} from "./base.js";

export const cosmos = {
  platform: "cosmos",

  match(url) {
    return hostIs(hostname(url), "cosmos.so");
  },

  extract(harvest, context = {}) {
    const isElement = (u) => pathSegments(u)[0] === "e";
    const url =
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], isElement) ||
      liveURL(harvest);
    const segments = pathSegments(url);
    const elementId = segments[0] === "e" ? segments[1] || null : null;

    const clicked = /cosmos\.so/.test(context.srcUrl || "") ? context.srcUrl : null;
    const mediaUrl = clicked || largestMedia(harvest, /cosmos\.so/)?.src || ogImage(harvest);

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
