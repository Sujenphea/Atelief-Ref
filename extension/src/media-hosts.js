// Atelier Capture — media-host allowlist (SSRF guard, decision 3A).
//
// A bulk sweep's media URLs come from PAGE-SUPPLIED JSON (the timeline / board-feed
// responses the page fetched), and the service worker fetches those bytes in the
// AUTHENTICATED session with host_permissions — a privileged position a compromised or
// hostile response must not be able to redirect. This pins each platform's media to its
// known CDNs; a URL on any other host is refused BEFORE the SW fetches it (recorded as a
// permanent per-item failure, never a network call). Deny-by-default: an unknown
// platform, an unparseable URL, or a look-alike host (`twimg.com.evil.com`) all fail.

import { hostname, hostIs } from "./extractors/base.js";

/** Per-platform CDN predicate. Twitter media rides pbs.twimg.com (images) and
 * video.twimg.com (clips); Pinterest rides i./v.pinimg.com; Instagram rides
 * scontent*.cdninstagram.com and the `instagram.f<edge>-<n>.fna.fbcdn.net` /
 * scontent*.fbcdn.net Meta CDN (both in the manifest host_permissions); rednote rides
 * rednotecdn.com, where the single apex entry covers `sns-i*` / `sns-web-i*` (images)
 * and `sns-v*` (video) at once. `hostIs` matches the apex or any subdomain, but NOT a
 * suffix-spoof (`hostIs("twimg.com.evil.com", "twimg.com")` is false — it ends with
 * `.evil.com`). */
const ALLOWED = {
  twitter: (host) => hostIs(host, "twimg.com"),
  pinterest: (host) => hostIs(host, "pinimg.com"),
  instagram: (host) => hostIs(host, "cdninstagram.com") || hostIs(host, "fbcdn.net"),
  rednote: (host) => hostIs(host, "rednotecdn.com"),
};

/** True if `url`'s host is an allowed media CDN for `platform`. A missing/garbage URL,
 * an empty host, or a platform with no entry all return false (deny-by-default). */
export function isAllowedMediaHost(platform, url) {
  const host = hostname(url);
  if (!host) return false;
  const allow = ALLOWED[platform];
  return allow ? allow(host) : false;
}

/** Static-asset CDNs a platform's JS BUNDLE may be fetched from (the SW route the
 * content script uses to read X's operation→queryId table). Separate from the media
 * allowlist because it grants a different thing — script text, not image bytes — and
 * should stay as small as the one platform that needs it. Deny-by-default, and the
 * same `hostIs` suffix-spoof safety as above. */
const ALLOWED_BUNDLE_HOSTS = ["abs.twimg.com"];

/** True if `url` is a platform JS bundle the SW may fetch on the content script's
 * behalf. Requires https — a bundle is code we regex for a request parameter, so it
 * must not be readable off a downgraded connection. */
export function isAllowedBundleHost(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol !== "https:") return false;
  return ALLOWED_BUNDLE_HOSTS.some((allowed) => hostIs(parsed.hostname, allowed));
}
