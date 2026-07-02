// Atelier Capture — shared extractor helpers + the SiteExtractor shape.
//
// A SiteExtractor is `{ platform, match(url), extract(harvest) -> Provenance }`.
// `harvest` is the object produced by harvestSignals: { url, title, canonical,
// metas }. A Provenance is:
//   { platform, originalURL, mediaUrl, authorHandle, authorName, title, rawMetadata }
// `mediaUrl` is the image the extension will fetch; the rest is provenance.

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

/** The canonical link when present, else the harvested url. */
export function canonicalURL(harvest) {
  return harvest.canonical || harvest.url;
}

/** The og:image (the media the extension fetches), or null. */
export function ogImage(harvest) {
  return firstMeta(harvest, ["og:image", "og:image:url", "twitter:image"]);
}
