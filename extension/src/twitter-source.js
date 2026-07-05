// Atelier Capture — X timeline push→pull source (Phase 6, [A2]).
//
// The X driver can't PULL pages (X paginates via scroll, and the request signing is
// too volatile to forge). So this adapts the PUSH stream of intercepted timeline
// responses (from twitter-hook.js, relayed as `postMessage`s the controller feeds
// to `onResponse`) into the engine's PULL async-iterator seam:
//   · `onResponse(json)` parses a captured response and queues its page.
//   · `enumerate()` yields the queued items; when the queue drains it AUTO-SCROLLS
//     to make the page fetch more, waits for the response to settle, and repeats.
//   · it ENDS when a page reports `tweetCount === 0` (X has no `-end-` sentinel — an
//     exhausted timeline just stops returning tweets) OR after `maxIdleRounds`
//     consecutive scrolls yield no new response (the bottom, or a DOM wall).
//
// Pure/injectable: `scroll` + `sleep` are deps, so a test drives the whole loop with
// no browser (a fake `scroll` that feeds `onResponse` simulates the page loading).

import { parseTimelinePage } from "./bulk-twitter.js";

export function createTwitterSource({
  scroll,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  host = "x.com",
  settleMs = 1500,
  maxIdleRounds = 3,
} = {}) {
  const queue = [];

  /** Feed one intercepted timeline response (called by the controller's message
   * listener). Parsed eagerly so a malformed page can't wedge the iterator. */
  function onResponse(json) {
    try {
      queue.push(parseTimelinePage(json, { host }));
    } catch {
      /* ignore an unparseable capture — the sweep continues on the next response */
    }
  }

  async function* enumerate() {
    let idleRounds = 0;
    while (true) {
      if (queue.length === 0) {
        // Nudge the page to request the next slice, then let the response arrive.
        if (typeof scroll === "function") await scroll();
        await sleep(settleMs);
      }
      if (queue.length === 0) {
        idleRounds += 1;
        if (idleRounds >= maxIdleRounds) return;   // bottom / wall → done
        continue;
      }
      idleRounds = 0;
      const page = queue.shift();
      for (const item of page.items) yield item;
      if (page.tweetCount === 0) return;           // exhausted timeline → done
    }
  }

  // Conforms to the engine's BulkSource seam: `enumerate(input, { cursor })`.
  // (X resume is scroll-driven; the cursor is informational — dedup-skip is the
  // real resume safety net. See bulk-twitter.js.)
  return { enumerate: () => enumerate(), onResponse };
}
