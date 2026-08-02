// Atelier Capture — which loopback port the app is actually on (301).
//
// The extension used to hard-code `http://127.0.0.1:47321`. Change 299 split the
// app into two installable builds — stable (`sujenphea.AtelierRefs`) and dev
// (`sujenphea.AtelierRefs.dev`) — and, because both would otherwise race for one
// bind, `IngestionModel.capturePort(bundleID:)` offsets the DEV build to 47322.
// The extension was never told, so with only the dev app running every request
// hit a closed port and Chrome reported the refused connection as the opaque
// `TypeError: Failed to fetch` (a sweep died on its opening `POST /jobs`).
//
// So: probe instead of assume. `GET /health` on each candidate, first answer
// wins, result cached so a sweep pays the probe once. STABLE IS TRIED FIRST —
// 299's rule is that the shipping bundle owns 47321, so when both apps are up the
// shipping one receives. A user who wants the other can pin it in the options.
//
// "Answers" means ANY HTTP response, including 401/403: `/health` is token-gated,
// so an unpaired extension still proves the app is listening. Only a thrown fetch
// (refused / DNS / abort) means "nothing there".

import { browser } from "./browser.js";

/** The shipping build's port — the historical hard-coded value. */
export const STABLE_BASE = "http://127.0.0.1:47321";
/** The `.dev` build's port (`CaptureServer.defaultPort + 1`). */
export const DEV_BASE = "http://127.0.0.1:47322";
/** Probe order. Stable first, deliberately (see the header). */
export const CANDIDATE_BASES = Object.freeze([STABLE_BASE, DEV_BASE]);

/** Options-page pin: `"auto"` (or unset) probes; a base URL forces that one. */
export const BASE_OVERRIDE_KEY = "atelierBaseOverride";
/** Where the winning base is remembered between calls. */
export const BASE_CACHE_KEY = "atelierBaseCache";

// --- Pure helpers (unit-tested without a browser API or a network) ----------

/**
 * The bases to try, in order, for a stored `override`. `"auto"`, `null`, or
 * anything not recognizable as a URL falls back to the full candidate list — a
 * garbage pin must not brick capture, it should just be ignored.
 */
export function candidateOrder(override) {
  if (typeof override === "string" && /^https?:\/\/\S+$/.test(override)) {
    return [override.replace(/\/+$/, "")];
  }
  return [...CANDIDATE_BASES];
}

/**
 * Whether `error` means "nothing answered" rather than "the app said no".
 *
 * This is the distinction the retry hangs on: a refused connection (Chrome's
 * `TypeError: Failed to fetch`) or an abort means the app may have moved to the
 * other port and re-resolving is worth it. An `Error` thrown by our own response
 * handling (`open job failed (HTTP 409)`) must NOT trigger a port hunt.
 */
export function isNetworkError(error) {
  if (!error) return false;
  if (error.name === "AbortError" || error.name === "TimeoutError") return true;
  return error instanceof TypeError ||
    /failed to fetch|networkerror|load failed|connection refused/i.test(String(error.message || error));
}

// --- Storage ---------------------------------------------------------------

/** An in-memory `{ load, save, remove }` — the fallback outside an extension
 * (tests, node) so nothing here needs a browser global to run. */
export function makeMemoryStorage(seed = {}) {
  const map = new Map(Object.entries(seed));
  return {
    async load(key) { return map.has(key) ? map.get(key) : null; },
    async save(key, value) { map.set(key, value); },
    async remove(key) { map.delete(key); },
  };
}

/** The real extension `storage.local` store, or an in-memory one when neither
 * browser global is present. Same `{ load, save, remove }` shape as
 * `bulk-controller.makeChromeStorage`, so the two are interchangeable. */
let fallbackStorage = null;
export function defaultStorage() {
  if (browser.storage) {
    const area = browser.storage.local;
    return {
      async load(key) { return (await area.get(key))[key] ?? null; },
      async save(key, value) { await area.set({ [key]: value }); },
      async remove(key) { await area.remove(key); },
    };
  }
  // One shared instance, so a cache written by one call is seen by the next.
  fallbackStorage = fallbackStorage || makeMemoryStorage();
  return fallbackStorage;
}

// --- Resolution ------------------------------------------------------------

/**
 * Is the app listening at `base`? Any HTTP reply counts (see the header note on
 * 401/403); a thrown fetch does not. Never throws.
 */
export async function probeBase(base, { token = null, fetchImpl = fetch } = {}) {
  try {
    const headers = token ? { "X-Atelier-Token": token } : {};
    await fetchImpl(`${base}/health`, { method: "GET", headers });
    return true;
  } catch {
    return false;
  }
}

/**
 * The base URL to send to. Returns the cached winner when there is one (a sweep
 * pays the probe once, not per item); otherwise probes `candidateOrder` and
 * caches the first that answers.
 *
 * With NOTHING reachable it returns the first candidate rather than throwing, so
 * the caller's own request produces the real, attributable error instead of this
 * resolver inventing one.
 */
export async function resolveBase({
  token = null, fetchImpl = fetch, storage = defaultStorage(), skipCache = false,
} = {}) {
  const override = await storage.load(BASE_OVERRIDE_KEY);
  const candidates = candidateOrder(override);
  // A pin is absolute — no probing, no cache, so switching apps takes effect at once.
  if (candidates.length === 1 && override && override !== "auto") return candidates[0];

  if (!skipCache) {
    const cached = await storage.load(BASE_CACHE_KEY);
    if (cached && candidates.includes(cached)) return cached;
  }
  for (const base of candidates) {
    if (await probeBase(base, { token, fetchImpl })) {
      await storage.save(BASE_CACHE_KEY, base);
      return base;
    }
  }
  return candidates[0];
}

/** Forget the cached base so the next `resolveBase` re-probes (the app restarted,
 * or moved builds). */
export async function invalidateBase(storage = defaultStorage()) {
  await storage.remove(BASE_CACHE_KEY);
}

/**
 * Run `attempt(base)` against the resolved base, and on a NETWORK failure only,
 * re-probe once and retry — which is what makes "I just switched from the stable
 * app to the dev one" self-heal instead of failing until the extension reloads.
 * A non-network error (the app answered, unhappily) propagates untouched.
 */
export async function withBase(attempt, opts = {}) {
  const base = await resolveBase(opts);
  try {
    return await attempt(base);
  } catch (error) {
    if (!isNetworkError(error)) throw error;
    await invalidateBase(opts.storage || defaultStorage());
    const next = await resolveBase({ ...opts, skipCache: true });
    // Nothing new to try — surface the original failure, not a duplicate attempt.
    if (next === base) throw error;
    return attempt(next);
  }
}
