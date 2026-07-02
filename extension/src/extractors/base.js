// Atelier Capture — shared extractor helpers + the SiteExtractor shape.
//
// A SiteExtractor is `{ platform, match(url), extract(harvest) -> Provenance }`.
// `harvest` is the object produced by harvestSignals: { url, title, canonical,
// metas, media }. A Provenance is:
//   { platform, originalURL, mediaUrl, authorHandle, authorName, title, rawMetadata }
// `mediaUrl` is the image the extension will fetch; the rest is provenance.
//
// KEY PRINCIPLE (learned from real pages): on SPA sites (X, Pinterest, …) the
// meta tags + canonical are stale/generic, and location.href (kept correct by
// pushState) + the rendered DOM media are the reliable signals. So originalURL
// comes from the LIVE url, and mediaUrl comes from DOM `media` by host pattern,
// with og:image only as a fallback.

/** Lowercased hostname of `url`, or "" if unparseable. */
export function hostname(url) {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
}

/** True if `host` equals `domain` or is a subdomain of it. */
export function hostIs(host, domain) {
  return host === domain || host.endsWith("." + domain);
}

/** A meta value by property/name key (e.g. "og:image"), or null. */
export function meta(harvest, key) {
  return (harvest.metas && harvest.metas[key]) || null;
}

/** The first present meta value across `keys`, or null. */
export function firstMeta(harvest, keys) {
  for (const key of keys) {
    const value = meta(harvest, key);
    if (value) return value;
  }
  return null;
}

/** Non-empty path segments of `url` (e.g. "/a/b/" -> ["a","b"]). */
export function pathSegments(url) {
  try {
    return new URL(url).pathname.split("/").filter(Boolean);
  } catch {
    return [];
  }
}

/** `url` reduced to origin + pathname (drops query/hash), or `url` if unparseable. */
export function cleanURL(url) {
  try {
    const u = new URL(url);
    return u.origin + u.pathname;
  } catch {
    return url || null;
  }
}

/**
 * The canonical link back to the post. Prefer the LIVE url (location.href, kept
 * correct by SPA pushState) over `canonical`, which is frequently stale/root on
 * these sites. Cleaned of query/hash.
 */
export function liveURL(harvest) {
  return cleanURL(harvest.url || harvest.canonical || "");
}

/** The og:image (a fallback only — usually generic/stale on SPAs), or null. */
export function ogImage(harvest) {
  return firstMeta(harvest, ["og:image", "og:image:url", "twitter:image"]);
}

/** Harvested DOM media (always an array). */
export function mediaList(harvest) {
  return Array.isArray(harvest.media) ? harvest.media : [];
}

/** DOM media whose `src` matches `pattern` (a RegExp). */
export function mediaMatching(harvest, pattern) {
  return mediaList(harvest).filter((m) => m.src && pattern.test(m.src));
}

/** First (DOM order) media matching `pattern` — for feeds where the focused
 * item renders first (e.g. the primary tweet). */
export function firstMedia(harvest, pattern) {
  return mediaMatching(harvest, pattern)[0] || null;
}

/** Largest (by rendered area) media matching `pattern` — for closeup pages where
 * the main image is the biggest (e.g. a Pinterest pin). */
export function largestMedia(harvest, pattern) {
  const candidates = mediaMatching(harvest, pattern);
  candidates.sort((a, b) => b.width * b.height - a.width * a.height);
  return candidates[0] || null;
}
