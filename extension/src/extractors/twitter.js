// Atelier Capture — Twitter / X extractor.
//
// X is client-rendered: og:image is generic/stale, so the real media comes from
// the right-clicked image (context.srcUrl) or, failing that, the DOM (the focused
// tweet renders first). Media is rewritten to full resolution (`name=orig`), with
// the original kept as a fetch fallback in case `name=orig` is rejected.

import {
  hostname, hostIs, firstMeta, pathSegments, liveURL, firstPostURL, firstMedia, ogImage,
} from "./base.js";

/** Rewrite a pbs.twimg media URL to original resolution (`name=orig`). */
function fullResolution(src) {
  if (!src) return null;
  try {
    const url = new URL(src);
    if (url.searchParams.has("name")) url.searchParams.set("name", "orig");
    return url.toString();
  } catch {
    return src;
  }
}

export const twitter = {
  platform: "twitter",

  match(url) {
    const host = hostname(url);
    return hostIs(host, "x.com") || hostIs(host, "twitter.com");
  },

  extract(harvest, context = {}) {
    const isStatus = (u) => pathSegments(u)[1] === "status";
    const url =
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], isStatus) ||
      liveURL(harvest);
    const segments = pathSegments(url);
    const handle = segments[0] ? "@" + segments[0] : null;
    const tweetId = segments[1] === "status" ? segments[2] || null : null;

    // Priority: the exact right-clicked image → the focused tweet's photo → a
    // video poster. og:image is a last resort.
    const clicked = /pbs\.twimg\.com/.test(context.srcUrl || "") ? context.srcUrl : null;
    const domPhoto = firstMedia(harvest, /pbs\.twimg\.com\/media\//)?.src || null;
    const videoPoster =
      firstMedia(harvest, /pbs\.twimg\.com\/(ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)/)?.src || null;
    const rendered = clicked || domPhoto || videoPoster;
    const mediaUrl = fullResolution(rendered) || ogImage(harvest);
    const mediaUrlFallback = rendered && mediaUrl !== rendered ? rendered : null;

    return {
      platform: "twitter",
      originalURL: url,
      mediaUrl,
      mediaUrlFallback,
      authorHandle: handle,
      authorName: null,
      title: firstMeta(harvest, ["og:description", "twitter:description"]) || harvest.title,
      rawMetadata: tweetId ? { tweetId } : {},
    };
  },
};
