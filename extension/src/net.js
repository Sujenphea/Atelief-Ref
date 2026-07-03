// Atelier Capture — fetch with a deadline.
//
// Every outbound request in the service worker (image bytes, video download,
// syndication / pin-page resolution) targets a third-party CDN that can stall.
// Plain `fetch` has no timeout, so a hung socket wedges the whole capture: no
// badge ever flashes and the poster/image fallback never runs (it only fires on
// a thrown or non-ok response, not on a request that simply never settles). This
// wraps `fetch` in an AbortController so a hang becomes a clean rejection the
// caller can fall back from.

/** Default per-request deadline. Generous enough for a large image/video on a
 * slow connection, short enough that a truly stuck request gives up. */
export const DEFAULT_TIMEOUT_MS = 15000;

/**
 * `fetch(url, opts)` that rejects if no response arrives within `timeoutMs`.
 * Aborts the underlying request on timeout (frees the socket) and always clears
 * the timer once the request settles, so nothing leaks. `fetchImpl` is injectable
 * for tests. Returns the `Response` (or whatever `fetchImpl` resolves to).
 */
export async function fetchWithTimeout(
  url,
  opts = {},
  { timeoutMs = DEFAULT_TIMEOUT_MS, fetchImpl = fetch } = {}
) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, { ...opts, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}
