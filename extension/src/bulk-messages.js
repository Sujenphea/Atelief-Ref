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
});

/** The runtime-message type that launches a sweep on a tab's content-script
 * controller. Named here (not a bare literal) so its two producers — the popup UI and
 * any console/agent trigger — and its one consumer (the controller bootstrap) can't
 * drift on the string. Paired with `buildStartMessage` / `readStartMessage` below so
 * the message SHAPE is defined once too. */
export const START = "atelier-bulk-start";

/** The sweep-spec fields the controller acts on. One list, referenced by both the
 * builder and the reader, so a rename can't desync the popup from the controller. */
const START_FIELDS = Object.freeze(["platform", "input", "scope", "resolveVideo"]);

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

/** True if a runtime message belongs to the bulk protocol (so the SW listener can
 * ignore anything else and let other handlers run). */
export function isBulkMessage(message) {
  return !!message && typeof message.type === "string" &&
    Object.values(BULK).includes(message.type);
}
