// Atelier Capture — Twitter / X extractor.
//
// X is client-rendered: og:image is generic/stale, so the real media is taken
// from the DOM. The focused tweet renders first, so the first `pbs.twimg.com/
// media/…` image (or a video poster) in DOM order is the post's media. The media
// URL is rewritten to full resolution (`name=orig`).

import {
  hostname, hostIs, firstMeta, pathSegments, liveURL, firstMedia, ogImage,
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

  extract(harvest) {
    const url = liveURL(harvest);
    const segments = pathSegments(url);
    // /{handle}/status/{id}
    const handle = segments[0] ? "@" + segments[0] : null;
    const tweetId = segments[1] === "status" ? segments[2] || null : null;

    const photo = firstMedia(harvest, /pbs\.twimg\.com\/media\//);
    const videoPoster = firstMedia(
      harvest,
      /pbs\.twimg\.com\/(ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)/
    );
    const mediaUrl =
      fullResolution(photo?.src) || videoPoster?.src || ogImage(harvest);

    return {
      platform: "twitter",
      originalURL: url,
      mediaUrl,
      authorHandle: handle,
      authorName: null,
      title: firstMeta(harvest, ["og:description", "twitter:description"]) || harvest.title,
      rawMetadata: tweetId ? { tweetId } : {},
    };
  },
};
