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

/** Non-empty segments of a PATHNAME string (e.g. "/a/b/" -> ["a","b"]). The shared
 * primitive (6A) — bulk-context.js reuses it so the "split a path" rule lives once. */
export function splitPathname(pathname) {
  return (pathname || "").split("/").filter(Boolean);
}

/** Non-empty path segments of a URL string (e.g. "https://x/a/b/" -> ["a","b"]). */
export function pathSegments(url) {
  try {
    return splitPathname(new URL(url).pathname);
  } catch {
    return [];
  }
}

/**
 * The first candidate URL that is a real post (per the `isPost` predicate),
 * cleaned. Used to prefer the right-clicked link (context.linkUrl) over the page
 * url — so capturing a pin from the feed still yields the pin's URL, not the feed.
 */
export function firstPostURL(candidates, isPost) {
  for (const candidate of candidates) {
    if (!candidate) continue;
    const clean = cleanURL(candidate);
    if (clean && isPost(clean)) return clean;
  }
  return null;
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

/** Rewrite a pbs.twimg media URL to original resolution (`name=orig`). Shared by
 * the Twitter DOM extractor AND the bulk tweet→provenance mapper (decision 6A) —
 * the resolution rule lives once. A `data:` src (a captured video frame) is
 * already full-res, so it's returned unchanged; an unparseable src is passed back.
 *
 * The DOM extractor (default) only rewrites a URL that ALREADY carries a `name=`
 * param — a bare URL is left alone. The bulk mapper passes `{ addIfAbsent: true }`
 * because X's timeline JSON gives a BARE `media_url_https` (no query) and we still
 * want to request the original, so `name=orig` is ADDED. */
export function toOrigName(src, { addIfAbsent = false } = {}) {
  if (!src) return null;
  if (src.startsWith("data:")) return src;
  try {
    const url = new URL(src);
    if (url.searchParams.has("name") || addIfAbsent) {
      url.searchParams.set("name", "orig");
      // **`name=orig` cannot serve webp** — twimg 404s the pair, and a caller that falls
      // back then captures the RENDERED size while looking entirely successful. This path
      // rarely sees webp, because a browser capture starts from a right-clicked `srcUrl`
      // (jpg); it bites whenever an extractor reads a rendered `<img>`, whose `currentSrc`
      // the browser has negotiated to webp. Observed on iOS, whose share extension has no
      // right-click and only ever reads the DOM (422).
      if (url.searchParams.get("format") === "webp") url.searchParams.set("format", "jpg");
    }
    return url.toString();
  } catch {
    return src;
  }
}

/** Rewrite an i.pinimg sized path (…/474x/…) to full resolution (…/originals/…).
 * Shared by the Pinterest DOM extractor AND the bulk pin→provenance mapper (6A). */
export function toOriginals(src) {
  if (!src) return null;
  return src.replace(/i\.pinimg\.com\/\d+x(?:\d+)?\//, "i.pinimg.com/originals/");
}

/**
 * Build a normalized `Provenance` (decision 6A) — the one shape both the single-
 * item DOM extractors and the bulk JSON mappers emit, so the app decodes an
 * identical `SourceDraft` no matter the capture path. Every optional field
 * defaults to `null` (and `rawMetadata` to `{}`), so a caller passes only what it
 * has and the wire shape is always complete. `platform` + `mediaUrl` are the load-
 * bearing fields; the rest is provenance the app stores but doesn't require.
 */
export function makeProvenance({
  platform,
  originalURL = null,
  mediaUrl = null,
  mediaUrlFallback = null,
  authorHandle = null,
  authorName = null,
  title = null,
  rawMetadata = {},
} = {}) {
  return {
    platform,
    originalURL,
    mediaUrl,
    mediaUrlFallback,
    authorHandle,
    authorName,
    title,
    rawMetadata: rawMetadata || {},
  };
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

/** First (DOM order) media of a given `kind` (e.g. "video-frame", whose data-URL
 * `src` can't be matched by host pattern). */
export function firstMediaOfKind(harvest, kind) {
  return mediaList(harvest).find((m) => m.kind === kind && m.src) || null;
}

/** Largest (by rendered area) media matching `pattern` — for closeup pages where
 * the main image is the biggest (e.g. a Pinterest pin). */
export function largestMedia(harvest, pattern) {
  const candidates = mediaMatching(harvest, pattern);
  candidates.sort((a, b) => b.width * b.height - a.width * a.height);
  return candidates[0] || null;
}
