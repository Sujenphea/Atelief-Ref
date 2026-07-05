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

/** The `window.postMessage` envelope tag the MAIN-world X hook uses to hand a
 * captured timeline response to the ISOLATED controller. Duplicated as a literal in
 * twitter-hook.js (a MAIN-world classic script can't import) — KEEP IN SYNC. */
export const TIMELINE_MESSAGE_SOURCE = "atelier-x-timeline";

/** True if a runtime message belongs to the bulk protocol (so the SW listener can
 * ignore anything else and let other handlers run). */
export function isBulkMessage(message) {
  return !!message && typeof message.type === "string" &&
    Object.values(BULK).includes(message.type);
}
