// Atelier Capture — the extractor registry.
//
// The single place that knows every SiteExtractor. Adding a platform is one new
// module + one line here (mirrors the Swift SourceAdapter shape). `web` is the
// generic fallback for any other page carrying Open Graph tags.

import { hostname, cleanURL, liveURL, ogImage, firstMeta, largestMedia } from "./base.js";
import { twitter } from "./twitter.js";
import { pinterest } from "./pinterest.js";
import { instagram } from "./instagram.js";
import { cosmos } from "./cosmos.js";
import { rednote } from "./rednote.js";

/** A last-resort extractor for any other page → platform "web". Unlike the SPA
 * sites, a generic article's og:image is a reliable share image, so it is
 * preferred here; the right-clicked image and the largest DOM image are fallbacks. */
export const web = {
  platform: "web",
  match() {
    return true;
  },
  extract(harvest, context = {}) {
    const largest = largestMedia(harvest, /^https?:\/\//);
    return {
      platform: "web",
      originalURL: cleanURL(context.linkUrl || harvest.url || harvest.canonical || ""),
      mediaUrl: context.srcUrl || ogImage(harvest) || largest?.src || null,
      authorHandle: null,
      authorName: firstMeta(harvest, ["og:site_name"]) || hostname(harvest.url),
      title: firstMeta(harvest, ["og:title", "og:description"]) || harvest.title,
      rawMetadata: {},
    };
  },
};

/** Site extractors in match priority order; `web` is the catch-all fallback. */
export const extractors = [twitter, pinterest, instagram, cosmos, rednote, web];

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

/**
 * Extract provenance for a harvested page. `context` carries the right-clicked
 * element (from a context-menu invocation): `{ srcUrl, linkUrl, pageUrl }`.
 */
export function extractProvenance(harvest, context = {}) {
  return findExtractor(harvest.url).extract(harvest, context);
}
