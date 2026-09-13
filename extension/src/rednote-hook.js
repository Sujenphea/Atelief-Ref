// Atelier Capture — rednote MAIN-world response hook (thin config over hook-core, 098 T3/T5b).
//
// rednote signs every API call: `X-s` is derived from the request URL and `X-t` is a live
// millisecond timestamp, produced by obfuscated bundle code behind a second `x-rap-param`
// layer. Reproducing that was tried and refused — HTTP 461 — so the sweep never signs
// anything. The page makes its own board-feed calls while the controller scrolls, and
// this hook forwards the responses. A signature-scheme change cannot break a sweep that
// has no signature in it.
//
// DELIBERATELY NO PROXY and NO headerAllowlist. hook-core's request proxy replays stored
// headers onto a DIFFERENT url, which is sound for X (a bearer token is url-independent)
// and useless here (an `X-s` is valid only for the url it signed). Nothing to inherit
// means nothing to guard, so the whole credential surface stays absent rather than
// present-and-unused.
//
// It forwards TWO responses: the board feed the cover pass reads (K3a) and the note detail
// the expansion pass reads (K3b, 098 D4). Both ride the same envelope tag and are told
// apart by URL on the controller side — one hook, one message stream, two parsers.
//
// SELF-CONTAINED — a CLASSIC script (NO import/export): injected as a MAIN-world content
// script at document_start. The constants below are duplicated from bulk-messages.js and
// the matchers from bulk-rednote.js — a classic script cannot import. `hook-sync.test.js`
// asserts they still agree, so "KEEP IN SYNC" is a test rather than a hope.

/** postMessage envelope tag. Mirrors bulk-messages.js `REDNOTE_FEED_MESSAGE_SOURCE`. */
const REDNOTE_FEED_MESSAGE_SOURCE = "atelier-rednote-feed";

/** The controller posts this to ask for the buffered pages it missed. Mirrors
 * bulk-messages.js `REDNOTE_REPLAY_SOURCE`. */
const REDNOTE_REPLAY_SOURCE = "atelier-rednote-feed-replay";

/**
 * True for a board-feed request URL. Mirrors bulk-rednote.js `isBoardFeedRequest`.
 *
 * Pinned to the PATH and not to a host, because the live probe showed rednote calling its
 * own telemetry on hosts right next to the feed — `t2.rnote.com/api/v2/collect`,
 * `apm-fe.rnote.com/api/data`, `as.rednote.com/api/sec/v1/shield/webprofile`. A
 * host-shaped matcher would forward all of it. The URL also arrives PROTOCOL-RELATIVE
 * (`//webapi.rednote.com/...`) on the XHR path, which is why this is a substring regex
 * and not a `new URL()` parse — the latter throws on that form.
 */
function isBoardFeedRequest(url) {
  return typeof url === "string" && /\/api\/sns\/web\/v1\/board\/note(?:$|[/?])/.test(url);
}

/**
 * True for a note-detail request URL. Mirrors bulk-rednote.js `isNoteDetailRequest`.
 *
 * K3b's expansion (098 D4) opens each note through the SPA so the PAGE issues this POST
 * with its own signature; forwarding the response is the whole of what the extension does
 * about it. Matched on the path ENDING `…/v1/feed`, not merely containing it: rednote
 * ships a family of feed routes below that prefix (`/v1/feed/…`), whose payloads
 * `parseNoteDetail` cannot read. Forwarding one would not corrupt a sweep — the expander
 * discards a body that is not the note it opened — but it would evict a real detail
 * response from the replay buffer, which is the same thing as losing it.
 */
function isNoteDetailRequest(url) {
  return typeof url === "string" && /\/api\/sns\/web\/v1\/feed\/?(?:$|[?#])/.test(url);
}

/** What the hook forwards: the board feed (K3a) and the note detail (K3b). One matcher,
 * because hook-core takes one — and because the two responses arrive on the same envelope
 * tag and are routed by URL on the controller side, where `isNoteDetailRequest` is the
 * imported original rather than this copy. */
function isHookedRequest(url) {
  return isBoardFeedRequest(url) || isNoteDetailRequest(url);
}

// Auto-install when injected as a MAIN-world content script on either rednote domain
// (guarded so a `node --test` import — no `window` — does nothing). hook-core.js loads
// FIRST per the manifest order and publishes the installer; if it is missing the manifest
// order is wrong — fail LOUDLY but NEVER throw into the page.
if (typeof window !== "undefined" && window.location &&
    /(^|\.)(rednote|xiaohongshu)\.com$/.test(window.location.hostname)) {
  const installResponseHook = window.__atelierInstallResponseHook;
  if (typeof installResponseHook !== "function") {
    console.error("[Atelier] hook-core.js must load before rednote-hook.js (check manifest order)");
  } else {
    installResponseHook({
      target: window,
      isMatch: isHookedRequest,
      replaySource: REDNOTE_REPLAY_SOURCE,
      post: (message) =>
        window.postMessage({ source: REDNOTE_FEED_MESSAGE_SOURCE, ...message }, window.location.origin),
    });
  }
}
