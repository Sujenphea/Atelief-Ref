// Atelier Capture — resolve a Twitter/X video tweet to a downloadable MP4.
//
// A video tweet has no still on the server and no plain video URL in the DOM
// (the <video> is a blob:/MediaSource). Twitter's public **syndication** endpoint,
// however, returns the tweet's media including progressive MP4 variants — one
// unauthenticated JSON fetch, no HLS reassembly. We pick the highest-bitrate MP4.
//
// The variant SELECTION is pure (tested against a saved response); the fetch is a
// thin wrapper (fetch injectable for tests). The `token` query param is a value
// the endpoint derives from the id — the formula is Twitter's and may change; if
// it does, resolution fails cleanly and the SW falls back to the poster frame.

import { fetchWithTimeout } from "./net.js";

const SYNDICATION_BASE = "https://cdn.syndication.twimg.com/tweet-result";

/**
 * The `token` query param the syndication endpoint derives from the tweet id.
 * This mirrors Twitter's own front-end formula EXACTLY, including its `Number(id)`
 * coercion: a 19-digit snowflake id exceeds Number.MAX_SAFE_INTEGER so precision
 * is lost, but the endpoint applies the same lossy math, so the two agree. The
 * radix is 36 (digits 0-9a-z); the `.replace` strips the leading "0." and any
 * run of zeros, matching their output. If Twitter changes this, resolution fails
 * cleanly and the SW falls back to the poster frame.
 */
export function deriveSyndicationToken(tweetId) {
  return ((Number(tweetId) / 1e15) * Math.PI)
    .toString(36)
    .replace(/(0+|\.)/g, "");
}

/** The syndication request URL for `tweetId` (incl. the derived `token`). */
export function syndicationURL(tweetId) {
  const token = deriveSyndicationToken(tweetId);
  return `${SYNDICATION_BASE}?id=${encodeURIComponent(tweetId)}&lang=en&token=${token}`;
}

/** Every video variant carried by a tweet-result payload, from any of the shapes
 * it uses (top-level `video`, or per-item `mediaDetails[].video_info`). */
function collectVariants(result) {
  const out = [];
  const push = (info) => {
    if (info && Array.isArray(info.variants)) out.push(...info.variants);
  };
  if (result && result.video) push(result.video);
  if (result && Array.isArray(result.mediaDetails)) {
    for (const media of result.mediaDetails) push(media.video_info);
  }
  return out;
}

/** The highest-bitrate progressive MP4 URL in a tweet-result payload, or null
 * (no video / only HLS `application/x-mpegURL` variants). */
export function selectBestVideo(result) {
  const mp4s = collectVariants(result).filter(
    (v) => v && v.url && (v.content_type || v.type) === "video/mp4"
  );
  if (!mp4s.length) return null;
  mp4s.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
  return mp4s[0].url;
}

/** Whether the SW should try to resolve a video for this capture. Syndication is
 * the source of truth for "is there a video" (so we don't rely on fragile DOM
 * heuristics); this only screens on cheap signals: a Twitter status with a tweet
 * id, and NOT an explicit right-click on a photo (a `/media/` image — respect that
 * the user pointed at a still). A non-video tweet simply yields no MP4 variant and
 * falls back to the image path. */
export function shouldResolveVideo(provenance, context = {}) {
  if (provenance.platform !== "twitter") return false;
  if (!provenance.rawMetadata || !provenance.rawMetadata.tweetId) return false;
  if (/pbs\.twimg\.com\/media\//.test(context.srcUrl || "")) return false;
  return true;
}

/** Resolve `tweetId` to a downloadable MP4 URL via the syndication API. Throws if
 * the request fails or the payload carries no MP4 variant. */
export async function resolveTwitterVideo(tweetId, { fetchImpl = fetch, timeoutMs } = {}) {
  const response = await fetchWithTimeout(
    syndicationURL(tweetId),
    { headers: { Accept: "application/json" } },
    { fetchImpl, timeoutMs }
  );
  if (!response.ok) throw new Error(`syndication HTTP ${response.status}`);
  const url = selectBestVideo(await response.json());
  if (!url) throw new Error("no MP4 variant in syndication response");
  return url;
}
