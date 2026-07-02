// Atelier Capture — the extractor registry.
//
// The single place that knows every SiteExtractor. Adding a platform is one new
// module + one line here (mirrors the Swift SourceAdapter shape). `web` is the
// generic fallback for any other page carrying Open Graph tags.

import { hostname, canonicalURL, ogImage, firstMeta } from "./base.js";
import { twitter } from "./twitter.js";
import { pinterest } from "./pinterest.js";
import { instagram } from "./instagram.js";
import { cosmos } from "./cosmos.js";

/** A last-resort extractor for any page with an og:image → platform "web". */
export const web = {
  platform: "web",
  match() {
    return true;
  },
  extract(harvest) {
    return {
      platform: "web",
      originalURL: canonicalURL(harvest),
      mediaUrl: ogImage(harvest),
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]) || hostname(harvest.url),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: {},
    };
  },
};

/** Site extractors in match priority order; `web` is the catch-all fallback. */
export const extractors = [twitter, pinterest, instagram, cosmos, web];

/** The first extractor whose `match(url)` is true (never null — `web` matches). */
export function findExtractor(url) {
  return extractors.find((extractor) => {
    try {
      return extractor.match(url);
    } catch {
      return false;
    }
  }) || web;
}

/** Extract provenance for a harvested page. */
export function extractProvenance(harvest) {
  return findExtractor(harvest.url).extract(harvest);
}
