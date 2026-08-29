// Atelier Capture — Twitter / X extractor.
//
// X is client-rendered: og:image is generic/stale, so the real media comes from
// the right-clicked image (context.srcUrl) or, failing that, the DOM (the focused
// tweet renders first). Media is rewritten to full resolution (`name=orig`), with
// the original kept as a fetch fallback in case `name=orig` is rejected.

import {
  hostname, hostIs, firstMeta, pathSegments, liveURL, firstPostURL, firstMedia,
  firstMediaOfKind, mediaMatching, ogImage, toOrigName,
} from "./base.js";

/**
 * A status URL reduced to its canonical permalink, `/{handle}/status/{id}`.
 *
 * X hangs sub-pages off a tweet — `/photo/1` on the image, `/analytics` on a promoted or
 * own post, `/history` on an edited one — and every one of them satisfies `isStatus`
 * (`pathSegments(u)[1] === "status"` is still true) and still yields the right id at
 * `segments[2]`. What they do NOT yield is the same `originalURL`, and 18A dedup keys on
 * provenance: right-click a tweet's IMAGE and you captured `…/status/{id}/photo/1`,
 * right-click its TEXT and you captured `…/status/{id}`, and the library forks one post
 * into two assets. Observed on a live feed, where a promoted post carried `/analytics` as
 * its ONLY status link — so this cannot be fixed by picking a better anchor, only by
 * normalizing the one there is.
 *
 * The bulk mapper never had this problem: `bulk-twitter.js:280` composes the permalink
 * from `screenName` + `tweetId` rather than reading it off the page. This is the DOM path
 * being brought into agreement with it, so the two producers of a `twitter` provenance
 * emit one URL for one tweet.
 *
 * A non-status URL (a profile, a search) is passed through untouched.
 */
export function toStatusPermalink(url) {
  const segments = pathSegments(url);
  if (segments[1] !== "status" || !segments[2]) return url;
  try {
    return `${new URL(url).origin}/${segments[0]}/status/${segments[2]}`;
  } catch {
    return url;
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
    // Normalized AFTER resolution rather than per candidate, so a sub-page URL from ANY
    // source — the right-clicked link, a live `/photo/1` lightbox URL, a stale canonical —
    // lands on the same permalink.
    const url = toStatusPermalink(
      firstPostURL([context.linkUrl, harvest.url, harvest.canonical], isStatus) ||
      liveURL(harvest)
    );
    const segments = pathSegments(url);
    const handle = segments[0] ? "@" + segments[0] : null;
    const tweetId = segments[1] === "status" ? segments[2] || null : null;

    // Scope DOM media to the FOCAL tweet (the first <article>, index 0) so a
    // text-only tweet doesn't borrow a REPLY's image. When the harvest carries no
    // article structure (an older snapshot / a non-tweet layout) we can't scope, so
    // fall back to the whole page. A right-clicked image (context.srcUrl) is the
    // user's explicit choice and stays UNSCOPED.
    const articlesPresent = harvest.media.some((m) => (m.articleIndex ?? -1) >= 0);
    const focal = articlesPresent
      ? { ...harvest, media: harvest.media.filter((m) => m.articleIndex === 0) }
      : harvest;

    // Priority: the exact right-clicked image → the focal tweet's photo → the live
    // video frame (canvas grab of what's on screen) → the video poster. For a video
    // tweet there is no still on the server, so the captured frame is the closest
    // thing to "the actual image"; the poster stays as a fetch fallback.
    const clicked = /pbs\.twimg\.com/.test(context.srcUrl || "") ? context.srcUrl : null;
    const domPhoto = firstMedia(focal, /pbs\.twimg\.com\/media\//)?.src || null;
    const videoFrame = firstMediaOfKind(focal, "video-frame")?.src || null;
    const videoPoster =
      firstMedia(focal, /pbs\.twimg\.com\/(ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)/)?.src || null;
    const rendered = clicked || domPhoto || videoFrame || videoPoster;
    // og:image is a last resort ONLY when we couldn't scope to a focal tweet. On a real
    // tweet page a focal tweet with no media is genuinely TEXT-ONLY, so it stays
    // image-less (→ a text card) rather than borrowing X's generic summary-card image.
    const mediaUrl = toOrigName(rendered) || (articlesPresent ? null : ogImage(harvest));
    // When the frame won: the poster is the network fallback. Otherwise: the
    // un-rewritten original (in case `name=orig` is rejected).
    const mediaUrlFallback =
      rendered === videoFrame ? videoPoster : rendered && mediaUrl !== rendered ? rendered : null;

    // payload.media[] (003 · C3): the focal tweet's photos — card first, deduped,
    // capped at X's max of 4, each rewritten to full-res. Only the FIRST is fetched as
    // the card blob; the rest ride as URL references (no extra network — decision 12A). A
    // video/text tweet has no /media/ photos, so this collapses to just the card (or
    // empty), matching the single-URL behaviour it replaces. Carried as a CLIENT HINT —
    // `normalizeProvenance` drops it, so only `payload.media[]` reaches the wire. (A rare
    // quoted-tweet photo inside the focal article can leak in; excluding it needs a
    // per-photo status-id signal — a separate change, TODO — not the overbroad
    // role="link" heuristic that dropped the tweet's OWN photos.)
    const focalPhotos = mediaMatching(focal, /pbs\.twimg\.com\/media\//).map((m) => toOrigName(m.src));
    const mediaUrls = [...new Set([mediaUrl, ...focalPhotos].filter(Boolean))].slice(0, 4);

    return {
      platform: "twitter",
      originalURL: url,
      mediaUrl,
      mediaUrlFallback,
      mediaUrls,
      authorHandle: handle,
      authorName: null,
      title: firstMeta(harvest, ["og:description", "twitter:description"]) || harvest.title,
      rawMetadata: tweetId ? { tweetId } : {},
    };
  },
};
