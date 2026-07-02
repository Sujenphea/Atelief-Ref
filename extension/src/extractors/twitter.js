// Atelier Capture — Twitter / X extractor.

import {
  hostname, hostIs, firstMeta, pathSegments, canonicalURL, ogImage,
} from "./base.js";

export const twitter = {
  platform: "twitter",

  match(url) {
    const host = hostname(url);
    return hostIs(host, "x.com") || hostIs(host, "twitter.com");
  },

  extract(harvest) {
    const url = canonicalURL(harvest);
    const segments = pathSegments(url);
    // /{handle}/status/{id}
    const handle = segments[0] ? "@" + segments[0] : null;
    const tweetId = segments[1] === "status" ? segments[2] || null : null;

    return {
      platform: "twitter",
      originalURL: url,
      mediaUrl: ogImage(harvest),
      authorHandle: handle,
      authorName: null,
      title: firstMeta(harvest, ["og:description", "twitter:description"]) || harvest.title,
      rawMetadata: tweetId ? { tweetId } : {},
    };
  },
};
