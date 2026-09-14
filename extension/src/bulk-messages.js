// Atelier Capture — the content-script ↔ service-worker bulk message protocol.
//
// The durable sweep loop (the engine) runs in the CONTENT SCRIPT so it survives the
// SW being torn down mid-sweep (MV3's ~30s idle limit). But only the SW can reach
// the loopback app (127.0.0.1) without CORS, so every localhost op — open a job,
// load the known-source set, relay an item, close the job — is proxied to the SW
// over `chrome.runtime` messaging. This one module names those message types so the
// content and SW sides can't drift on a string literal.

export const BULK = Object.freeze({
  open: "atelier-bulk-open",       // → { jobId, caps }
  known: "atelier-bulk-known",     // → string[] (sourceIds)
  relay: "atelier-bulk-relay",     // → an ingestOne result (classified content-side)
  complete: "atelier-bulk-complete", // → true
  // → { text } — a platform JS bundle, fetched BY THE SW. Not a localhost op: it is
  // here because a content script's cross-origin fetch is bound by the page's CORS,
  // while the SW's is covered by `host_permissions`. Host-allowlisted SW-side.
  bundle: "atelier-bulk-bundle",
});

/** The runtime-message type that launches a sweep on a tab's content-script
 * controller. Named here (not a bare literal) so its two producers — the popup UI and
 * any console/agent trigger — and its one consumer (the controller bootstrap) can't
 * drift on the string. Paired with `buildStartMessage` / `readStartMessage` below so
 * the message SHAPE is defined once too. */
export const START = "atelier-bulk-start";

/** The sweep-spec fields the controller acts on. One list, referenced by both the
 * builder and the reader, so a rename can't desync the popup from the controller. */
const START_FIELDS = Object.freeze([
  "platform", "input", "scope",
  // The two user TOGGLES, folded in by the popup rather than by the resolver (see
  // bulk-context.js's header): `resolveVideo` relays the resolved MP4 instead of the
  // poster, `expandNotes` opens each rednote note for the rest of its images (098 R13 —
  // opt-in, cover-only by default, because it costs one note-open per note).
  "resolveVideo", "expandNotes",
]);

/** Build the `START` runtime message from a resolved sweep spec. The popup sends the
 * result; the controller reads it back with `readStartMessage`. */
export function buildStartMessage(spec) {
  const message = { type: START };
  for (const field of START_FIELDS) message[field] = spec[field];
  return message;
}

/** The inverse of `buildStartMessage`: pull the sweep spec back out of a `START`
 * message. The controller bootstrap uses this instead of reading fields ad hoc, so a
 * round-trip test (`readStartMessage(buildStartMessage(spec))`) pins the contract. */
export function readStartMessage(message) {
  const spec = {};
  for (const field of START_FIELDS) spec[field] = message[field];
  return spec;
}

/** The `window.postMessage` envelope tag the MAIN-world X hook uses to hand a
 * captured timeline response to the ISOLATED controller. Duplicated as a literal in
 * twitter-hook.js (a MAIN-world classic script can't import) — KEEP IN SYNC. */
export const TIMELINE_MESSAGE_SOURCE = "atelier-x-timeline";

/** Envelope tag the ISOLATED controller posts to ASK the hook to re-emit the timeline
 * responses it buffered before the sweep's listener existed (the first page, loaded on
 * navigation). Without the replay, a short timeline — e.g. a small bookmark folder whose
 * items all fit on page 1 — captures nothing (the auto-scroll only hits the empty tail).
 * Duplicated as a literal in twitter-hook.js — KEEP IN SYNC. */
export const TIMELINE_REPLAY_SOURCE = "atelier-x-timeline-replay";

/** The request/reply tag pair for the hook's REQUEST PROXY ([090] 3A). The controller
 * posts `{ source: HOOK_PROXY_REQUEST_SOURCE, id, url }`; the MAIN-world hook replays its
 * stored auth headers onto that url and posts back `{ source: HOOK_PROXY_REPLY_SOURCE,
 * id, status, json }`. This pair exists so the credentials never have to: the hook holds
 * them, the controller holds a correlation id, and only the BODY crosses. Duplicated as
 * literals in twitter-hook.js (a MAIN-world classic script can't import) — KEEP IN SYNC. */
export const HOOK_PROXY_REQUEST_SOURCE = "atelier-x-proxy-request";
export const HOOK_PROXY_REPLY_SOURCE = "atelier-x-proxy-reply";
// (Instagram uses NO MAIN-world hook — its saved feed is replayed directly from the
// content script via a credentialled fetch, 002 · O2 — so it needs no message tags.)

/** rednote's envelope tags (098 T3). Same push→replay pair as X, and DELIBERATELY no
 * proxy pair: the hook's request proxy replays stored headers onto a different URL, which
 * works for X's URL-independent bearer token and cannot work for rednote, whose `X-s` is
 * signed over the URL it was issued for (098 D1 — a hand-signed request came back 461).
 * Duplicated as literals in rednote-hook.js (a MAIN-world classic script can't import) —
 * KEEP IN SYNC, and `hook-sync.test.js` now enforces that rather than trusting it. */
export const REDNOTE_FEED_MESSAGE_SOURCE = "atelier-rednote-feed";
export const REDNOTE_REPLAY_SOURCE = "atelier-rednote-feed-replay";

/** True if a runtime message belongs to the bulk protocol (so the SW listener can
 * ignore anything else and let other handlers run). */
export function isBulkMessage(message) {
  return !!message && typeof message.type === "string" &&
    Object.values(BULK).includes(message.type);
}
