// Atelier Capture — Instagram saved-feed push→pull source (thin adapter, 002 · B3, [5A][3A]).
//
// Like X, the IG driver can't PULL pages (the feed is scroll-driven and the request is
// signed), so it rides the generic `createInterceptSource` over the PUSH stream of
// intercepted saved-feed responses (from instagram-hook.js). This file supplies only IG's
// page parser (`parseSavedFeedPage` → `{ items, endOfFeed, error }`). No scope matcher is
// needed: the hook's URL matcher only forwards the FLAT saved feed, so there are no
// other-feed pages in the buffer to drop (a saved COLLECTION loads from a different path
// and is unmatched — 6A). A challenge page hands back a fatal `error` the source re-raises
// so the engine halts resumable (3A). See intercept-source.js for the loop machinery.

import { parseSavedFeedPage } from "./bulk-instagram.js";
import { createInterceptSource, SourceStallError } from "./intercept-source.js";

/** IG's stall error (a named subclass for a legible message). Thrown when scrolling stops
 * producing new pages before a `more_available:false` end page → the engine halts the
 * sweep RESUMABLE, keeping the checkpoint. */
export class InstagramStallError extends SourceStallError {
  constructor(idleRounds) {
    super(idleRounds, "Instagram saved feed");
    this.name = "InstagramStallError";
  }
}

export function createInstagramSource({
  scroll,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  host = "www.instagram.com",
  settleMs = 3000,
  maxIdleRounds = 5,
} = {}) {
  return createInterceptSource({
    scroll, sleep, host, settleMs, maxIdleRounds,
    StallError: InstagramStallError,
    // parseSavedFeedPage never throws (a challenge comes back as `page.error`, which the
    // source re-raises; a malformed page ends the feed cleanly).
    parsePage: (json, { host: pageHost }) => {
      const page = parseSavedFeedPage(json, { host: pageHost });
      return { items: page.items, endOfFeed: page.endOfFeed, error: page.error };
    },
  });
}
