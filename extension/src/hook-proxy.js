// Atelier Capture — the ISOLATED-world client for hook-core's request proxy ([090] 3A).
//
// The MAIN-world hook holds the page's auth headers in a closure and will not hand them
// out (they would be readable by every script on the page). What it WILL do is make one
// narrow request on our behalf and post back the body. This module is the other end of
// that conversation: it turns the message pair into something `fetch`-shaped, so the
// callers that used to be handed a credentialled `fetch` don't need to know a message
// boundary is involved at all.
//
// The contract in one line: a correlation id goes out with the url, the same id comes
// back with the body, and nothing that authorized the request is ever in either message.
//
// Two things are ours to own rather than the hook's:
//   · the TIMEOUT — a request the page never answers must fail here, not strand a promise
//     inside the page's listener (a hook-side timer would also have to survive the page
//     navigating, which it can't);
//   · DISPOSAL — the sweep's listener has to come off the window when the sweep settles,
//     the same discipline the timeline listener already follows.

import { HOOK_PROXY_REQUEST_SOURCE, HOOK_PROXY_REPLY_SOURCE } from "./bulk-messages.js";

/** How long to wait for the hook to answer before giving up on one proxied request.
 * Generous: it covers a real network round-trip to X on a slow connection, and the only
 * cost of waiting is one unexpanded thread. */
export const HOOK_PROXY_TIMEOUT_MS = 20_000;

/** Raised when a proxied request could not be completed — a refused url, a hook with no
 * credentials yet, a network throw, or a timeout. Typed (rather than a bare Error) so a
 * caller can tell "the proxy said no" from "the server said no". */
export class HookProxyError extends Error {
  constructor(reason) {
    super(`hook proxy: ${reason}`);
    this.name = "HookProxyError";
    this.reason = reason;
  }
}

/**
 * A `fetch`-shaped function that routes through the MAIN-world hook, plus the `dispose`
 * that unhooks its listener.
 *
 * `proxyFetch(url)` resolves to `{ status, json() }` — the subset of the Response
 * interface its callers use — so an existing `fetchImpl` seam takes it unchanged. Any
 * `init` is IGNORED on purpose: headers are the hook's business, and silently accepting
 * an init that names some would be a lie about where auth lives.
 *
 * Replies are correlated by id, so several conversations can be in flight and a stale
 * answer (or a page script echoing an id we've already settled) is dropped rather than
 * resolving the wrong request.
 */
export function createHookProxyFetch({
  win,
  requestSource = HOOK_PROXY_REQUEST_SOURCE,
  replySource = HOOK_PROXY_REPLY_SOURCE,
  timeoutMs = HOOK_PROXY_TIMEOUT_MS,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (handle) => clearTimeout(handle),
  random = Math.random,
} = {}) {
  // A per-instance prefix so two sweeps on one page (or a leftover listener) can't
  // collide on `1`, `2`, `3`. Not a secret — ids authorize nothing.
  const prefix = `atelier-${Math.floor(random() * 1e9).toString(36)}`;
  const pending = new Map();
  let counter = 0;

  const onMessage = (event) => {
    if (event.source !== win) return;
    const data = event.data;
    if (!data || data.source !== replySource) return;
    const entry = pending.get(data.id);
    if (!entry) return;                       // unknown or already-settled id → ignore
    pending.delete(data.id);
    clearTimer(entry.timer);
    if (data.error) {
      entry.reject(new HookProxyError(String(data.error)));
      return;
    }
    entry.resolve({
      status: Number(data.status) || 0,
      json: async () => data.json,
    });
  };
  win.addEventListener("message", onMessage);

  const proxyFetch = (url) => new Promise((resolve, reject) => {
    counter += 1;
    const id = `${prefix}-${counter}`;
    const timer = setTimer(() => {
      pending.delete(id);
      reject(new HookProxyError("timeout"));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    try {
      win.postMessage({ source: requestSource, id, url }, win.location.origin);
    } catch (error) {
      pending.delete(id);
      clearTimer(timer);
      reject(new HookProxyError(String(error)));
    }
  });

  return {
    proxyFetch,
    dispose: () => {
      win.removeEventListener("message", onMessage);
      // Nothing may be left waiting on a listener that no longer exists.
      for (const entry of pending.values()) {
        clearTimer(entry.timer);
        entry.reject(new HookProxyError("disposed"));
      }
      pending.clear();
    },
  };
}
