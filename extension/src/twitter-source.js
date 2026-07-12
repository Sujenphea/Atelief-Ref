// Atelier Capture — X timeline push→pull source (Phase 6, [A2]).
//
// The X driver can't PULL pages (X paginates via scroll, and the request signing is
// too volatile to forge). So this adapts the PUSH stream of intercepted timeline
// responses (from twitter-hook.js, relayed as `postMessage`s the controller feeds
// to `onResponse`) into the engine's PULL async-iterator seam:
//   · `onResponse(json)` parses a captured response and queues its page.
//   · `enumerate()` yields the queued items; when the queue drains it AUTO-SCROLLS
//     to make the page fetch more, waits for the response to settle, and repeats.
//   · it COMPLETES only when a page reports `tweetCount === 0` (X has no `-end-`
//     sentinel — a truly exhausted timeline stops returning tweets).
//   · if instead `maxIdleRounds` consecutive scrolls yield NO new response, that's a
//     STALL, not the end (a DOM wall, a rate-limit, a slow network) — the source can't
//     tell "no more items" from "couldn't load more". It THROWS a `TimelineStallError`
//     [2A] so the engine HALTS RESUMABLE (closes the job "paused", keeps the checkpoint)
//     rather than the old silent `return`, which the engine read as a clean "complete"
//     and then DELETED the checkpoint — stranding a half-swept timeline as done.
//
// Pure/injectable: `scroll` + `sleep` are deps, so a test drives the whole loop with
// no browser (a fake `scroll` that feeds `onResponse` simulates the page loading).

import { parseTimelinePage, matchesScope } from "./bulk-twitter.js";

/** Thrown by `enumerate()` when scrolling stops producing new pages before a 0-tweet
 * end-of-timeline page. Distinct from a clean finish: the engine catches an enumeration
 * throw and halts the sweep RESUMABLE, so the user can continue where the wall stopped
 * it instead of the timeline being falsely recorded complete. */
export class TimelineStallError extends Error {
  constructor(idleRounds) {
    super(`X timeline stalled: no new page after ${idleRounds} scroll attempt(s)`);
    this.name = "TimelineStallError";
    this.stalled = true;
  }
}

export function createTwitterSource({
  scroll,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  host = "x.com",
  settleMs = 2000,
  maxIdleRounds = 4,
  scope = null,
} = {}) {
  const queue = [];

  /** Feed one intercepted timeline response (called by the controller's message
   * listener with the response's request `url`). Parsed eagerly so a malformed page
   * can't wedge the iterator.
   *
   * The hook forwards EVERY timeline the page fetched — main bookmarks, Likes, other
   * folders — and the replay buffer (075) re-emits the pre-sweep ones. When `scope`
   * is set we drop any response whose `url` is outside it, so a folder sweep never
   * ingests tweets from another feed. `scope` unset (tests / a scope-agnostic caller)
   * accepts everything, preserving the old behaviour. */
  function onResponse(json, url) {
    if (scope && !matchesScope(url, scope)) return; // outside this sweep's scope
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
        // Scrolling produced nothing new. This is a STALL, not a confirmed end (only a
        // 0-tweet page below confirms that) — throw so the engine halts RESUMABLE and the
        // checkpoint survives, instead of falsely completing a half-swept timeline.
        if (idleRounds >= maxIdleRounds) throw new TimelineStallError(idleRounds);
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
