// Atelier Capture — rednote push→pull source (thin adapter over intercept-source, 098 T3).
//
// The board feed cannot be pulled: every request is signed for the url it was issued for
// (098 D1), so the sweep scrolls and reads whatever the page fetches. All the queue /
// auto-scroll / stall / scope machinery lives in intercept-source.js; this file supplies
// only rednote's page parser and its scope matcher — the same shape as twitter-source.js.

import { parseBoardFeedPage, matchesScope } from "./bulk-rednote.js";
import { createInterceptSource, SourceStallError } from "./intercept-source.js";

/** rednote's stall: scrolling stopped producing pages before an `endOfFeed` one. Thrown
 * so the engine halts the sweep RESUMABLE instead of recording a partial board complete. */
export class RednoteStallError extends SourceStallError {
  constructor(idleRounds) {
    super(idleRounds, "rednote board");
    this.name = "RednoteStallError";
  }
}

export function createRednoteSource({
  scroll,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  host = "www.rednote.com",
  settleMs = 2000,
  maxIdleRounds = 4,
  scope = null,
  onExpandFailure = null,
} = {}) {
  return createInterceptSource({
    scroll, sleep, host, settleMs, maxIdleRounds, scope, onExpandFailure,
    matchesScope,
    StallError: RednoteStallError,
    // `parseBoardFeedPage` never throws — a refusal comes back as `error`, which the
    // source re-raises on the pull side so the engine halts resumable. Returning it (not
    // throwing it) is load-bearing: a throw from here is swallowed as an unparseable
    // capture and the sweep would carry on against a flagged account (098 R10).
    parsePage: (json, { host: pageHost }) => {
      const page = parseBoardFeedPage(json, { host: pageHost });
      return { items: page.items, endOfFeed: page.endOfFeed, error: page.error };
    },
  });
}
