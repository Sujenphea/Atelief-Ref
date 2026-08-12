// Atelier Capture — generic push→pull intercept source (Phase 6, [5A][A2]).
//
// A MAIN-world hook (hook-core.js) can only PUSH intercepted responses; the bulk engine
// PULLS an async iterator. This adapts one to the other, platform-agnostically:
//   · `onResponse(json, url)` parses a captured response (via the injected `parsePage`)
//     and queues its page; a response outside `scope` (per the injected `matchesScope`)
//     is dropped, so a scoped sweep never ingests another feed's replayed pages.
//   · `enumerate()` yields the queued items; when the queue drains it AUTO-SCROLLS to
//     make the page fetch more, waits for the response to settle, and repeats.
//   · it COMPLETES only when a page reports `endOfFeed` (each platform decides what that
//     means — X: a 0-tweet page; IG: `more_available` false / no `next_max_id`).
//   · if instead `maxIdleRounds` consecutive scrolls yield NO new response, that's a
//     STALL, not the end (a DOM wall, a rate-limit, a slow network) — it THROWS `StallError`
//     so the engine HALTS RESUMABLE (keeps the checkpoint) rather than falsely completing.
//   · a page may carry a fatal `error` (e.g. an Instagram challenge, [3A]) which arrives
//     over the PUSH channel; `enumerate` re-raises it on the PULL side so the engine halts
//     resumable — a challenge pauses the sweep instead of hammering a flagged account.
//
// Pure/injectable: `scroll` + `sleep` are deps, so a test drives the whole loop with no
// browser (a fake `scroll` that feeds `onResponse` simulates the page loading).

/** Thrown by `enumerate()` when scrolling stops producing new pages before an
 * `endOfFeed` page. Distinct from a clean finish: the engine catches an enumeration
 * throw and halts the sweep RESUMABLE, so the user continues where the wall stopped it
 * instead of the feed being falsely recorded complete. `label` names the platform for a
 * legible message. */
export class SourceStallError extends Error {
  constructor(idleRounds, label = "source") {
    super(`${label} stalled: no new page after ${idleRounds} scroll attempt(s)`);
    this.name = "SourceStallError";
    this.stalled = true;
    this.idleRounds = idleRounds;
  }
}

/**
 * @param opts.parsePage     `(json, { host }) => { items, endOfFeed, error? }`. `error`,
 *                           when present, is an Error to re-raise from `enumerate` (a
 *                           fatal challenge routed from the push channel); a THROW from
 *                           parsePage is treated as an unparseable page and ignored.
 * @param opts.matchesScope  `(url, scope) => boolean`; when `scope` is set, a response
 *                           whose url fails this is dropped. Omit to accept everything.
 * @param opts.scroll        `() => void|Promise` — nudge the page to fetch the next slice.
 * @param opts.sleep         injected timer (tests pass a no-op).
 * @param opts.host          threaded into `parsePage` for origin-relative URLs.
 * @param opts.settleMs      how long to wait after a scroll for the response.
 * @param opts.maxIdleRounds consecutive empty scrolls before a `StallError`.
 * @param opts.scope         the sweep's scope token (or null → accept all).
 * @param opts.StallError    the stall error class to throw (per-platform subclass).
 * @param opts.expandItems   optional `async (items) => items` applied to a page's items
 *                           just before they're yielded. Runs on the PULL side, not in
 *                           `onResponse`: expansion can be async and can fail, and the
 *                           push path must stay synchronous and unwedgeable. A throw
 *                           here degrades to the unexpanded page rather than killing
 *                           the sweep — see X's thread expansion (twitter-thread.js).
 */
export function createInterceptSource({
  parsePage,
  matchesScope = null,
  scroll,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  host = null,
  settleMs = 2000,
  maxIdleRounds = 4,
  scope = null,
  StallError = SourceStallError,
  expandItems = null,
} = {}) {
  if (typeof parsePage !== "function") throw new Error("createInterceptSource requires parsePage");

  const queue = [];
  let pendingError = null;   // a fatal page.error routed from onResponse → thrown by enumerate

  /** Feed one intercepted response (called by the controller's message listener with the
   * response's request `url`). Parsed eagerly so a malformed page can't wedge the iterator.
   * Outside-scope responses are dropped; a page carrying a fatal `error` arms `pendingError`. */
  function onResponse(json, url) {
    if (scope && matchesScope && !matchesScope(url, scope)) return; // outside this sweep's scope
    let page;
    try {
      page = parsePage(json, { host });
    } catch {
      return; /* unparseable capture — ignore, the sweep continues on the next response */
    }
    if (page && page.error) { pendingError = page.error; return; }
    if (page) queue.push(page);
  }

  async function* enumerate() {
    let idleRounds = 0;
    while (true) {
      if (pendingError) throw pendingError;       // a challenge/fatal arrived via the push channel
      if (queue.length === 0) {
        // Nudge the page to request the next slice, then let the response arrive.
        if (typeof scroll === "function") await scroll();
        await sleep(settleMs);
      }
      if (pendingError) throw pendingError;       // re-check: it may have arrived during the settle
      if (queue.length === 0) {
        idleRounds += 1;
        // Scrolling produced nothing new. A STALL, not a confirmed end (only an endOfFeed
        // page confirms that) — throw so the engine halts RESUMABLE and the checkpoint survives.
        if (idleRounds >= maxIdleRounds) throw new StallError(idleRounds);
        continue;
      }
      idleRounds = 0;
      const page = queue.shift();
      let items = page.items;
      if (expandItems && items.length > 0) {
        try {
          items = (await expandItems(items)) || page.items;
        } catch {
          items = page.items;                     // expansion is a bonus, never a blocker
        }
      }
      for (const item of items) yield item;
      if (page.endOfFeed) return;                 // exhausted feed → done
    }
  }

  // Conforms to the engine's BulkSource seam: `enumerate(input, { cursor })`. (Resume is
  // scroll-driven; the cursor is informational — dedup-skip is the real resume safety net.)
  return { enumerate: () => enumerate(), onResponse };
}
