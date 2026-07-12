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
 * video.twimg.com (clips); Pinterest rides i./v.pinimg.com. `hostIs` matches the apex
 * or any subdomain, but NOT a suffix-spoof (`hostIs("twimg.com.evil.com","twimg.com")`
 * is false — it ends with `.evil.com`). */
const ALLOWED = {
  twitter: (host) => hostIs(host, "twimg.com"),
  pinterest: (host) => hostIs(host, "pinimg.com"),
};

/** True if `url`'s host is an allowed media CDN for `platform`. A missing/garbage URL,
 * an empty host, or a platform with no entry all return false (deny-by-default). */
export function isAllowedMediaHost(platform, url) {
  const host = hostname(url);
  if (!host) return false;
  const allow = ALLOWED[platform];
  return allow ? allow(host) : false;
}
