// Atelier Capture — X push→pull source (thin adapter over intercept-source, [5A][A2]).
//
// The X driver can't PULL pages (X paginates via scroll, and request signing is too
// volatile to forge), so it rides the generic `createInterceptSource` over the PUSH
// stream of intercepted timeline responses (from twitter-hook.js). This file supplies
// only X's page parser (adapting `parseTimelinePage` to the source's `{ items, endOfFeed }`
// shape — X's end signal is a 0-tweet page) and its scope matcher. See intercept-source.js
// for the queue / auto-scroll / stall machinery.

import { parseTimelinePage, matchesScope } from "./bulk-twitter.js";
import { createInterceptSource, SourceStallError } from "./intercept-source.js";

/** X's stall error (kept as a named subclass so existing callers/tests that reference
 * `TimelineStallError` are unchanged). Thrown when scrolling stops producing new pages
 * before a 0-tweet end-of-timeline page → the engine halts the sweep RESUMABLE. */
export class TimelineStallError extends SourceStallError {
  constructor(idleRounds) {
    super(idleRounds, "X timeline");
    this.name = "TimelineStallError";
  }
}

export function createTwitterSource({
  scroll,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  host = "x.com",
  settleMs = 2000,
  maxIdleRounds = 4,
  scope = null,
  // Optional `async (items) => items` that swaps a threaded tweet's items for its
  // whole thread's (twitter-thread.js). Omitted → tweets save exactly as swept.
  expandItems = null,
} = {}) {
  return createInterceptSource({
    scroll, sleep, host, settleMs, maxIdleRounds, scope, expandItems,
    matchesScope,
    StallError: TimelineStallError,
    // A tweet page ends the timeline when it carries ZERO tweet entries (X has no `-end-`
    // sentinel). `parseTimelinePage` never throws on garbage (findInstructions tolerates
    // it) — an empty page simply yields nothing and, being 0-tweet, also ends the feed,
    // which preserves the old "unparseable capture is ignored" behaviour.
    parsePage: (json, { host: pageHost }) => {
      const page = parseTimelinePage(json, { host: pageHost });
      return { items: page.items, endOfFeed: page.tweetCount === 0 };
    },
  });
}
