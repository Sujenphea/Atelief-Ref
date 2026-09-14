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
 * @param opts.onExpandFailure optional `(error, items) => void` — called when `expandItems`
 *                           throws, so a DEGRADED page is counted and reported instead of
 *                           being invisible. Expansion stays fail-open (see below); this
 *                           only makes the loss observable. Guarded: a throw from it is
 *                           swallowed, because a reporting hook must never be able to kill
 *                           a sweep it exists to describe.
 * @param opts.isFatalExpandFailure optional `(error) => boolean`. Expansion is fail-open by
 *                           default (below), which is right for work that did not come
 *                           back and WRONG for work that was REFUSED: rednote's note-open
 *                           can come back as the same risk-control refusal the board feed
 *                           can (098 D8), and degrading past one keeps opening notes
 *                           against a flagged session. When this says an expansion error
 *                           is fatal it is RE-RAISED from `enumerate` — the same halt the
 *                           push-side `page.error` route takes — instead of degrading.
 *                           Omitted → nothing is fatal, which is exactly X's behaviour.
 * @param opts.expandItems   optional `async (items) => items` applied to a page's items
 *                           just before they're yielded. Runs on the PULL side, not in
 *                           `onResponse`: expansion can be async and can fail, and the
 *                           push path must stay synchronous and unwedgeable. A throw
 *                           here degrades to the unexpanded page rather than killing
 *                           the sweep — see X's thread expansion (twitter-detail-client.js).
 *
 *                           PAGE-AT-A-TIME, which is the whole of its reach: nothing scrolls
 *                           while it runs. That is fine for X, whose expansion ASKS for a
 *                           conversation over the network, and impossible for rednote, whose
 *                           expansion has to CLICK a card the virtualised grid only mounts
 *                           when the viewport is near it (098 2A). So rednote pulls `pages()`
 *                           and does its own per-note pass; this hook, and the two options
 *                           above it, are X's. They stay described here rather than pared
 *                           back to today's single caller because they are the contract a
 *                           page-at-a-time expansion has — and because the fail-open rule
 *                           they encode is the one thing about expansion that no consumer
 *                           should ever have to re-derive.
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
  onExpandFailure = null,
  isFatalExpandFailure = null,
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

  /**
   * The queue / auto-scroll / stall / fatal loop, one PAGE at a time.
   *
   * `enumerate` below is this plus X's per-page `expandItems` and the item-level yield, and
   * that split is the whole of the extraction: a consumer that needs to do its own work
   * BETWEEN one page and the next scroll — rednote's streaming note-expansion, which opens
   * a note while its card is still mounted and therefore has to interleave with the
   * scrolling (098 2A) — cannot express that through `expandItems`, because nothing scrolls
   * until `expandItems` has returned.
   *
   * So the part that is genuinely common is SHARED rather than copied. It is copying that
   * would be the defect here: the stall ("a wall is not an end") and the fatal route ("a
   * challenge halts resumable") are safety decisions, and a second copy of a safety
   * decision is the one that quietly stops agreeing with the first.
   *
   * Nothing about it is platform-specific and nothing about it changed in the extraction:
   * a page is yielded, the consumer's body runs, and an `endOfFeed` page ends the
   * generator afterwards — exactly the order the inline loop had.
   */
  async function* pages() {
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
      yield page;
      // AFTER the consumer's body has run, so a page that ends the feed still has its items
      // yielded (and, for rednote, still has its notes expanded) before the generator closes.
      if (page.endOfFeed) return;                 // exhausted feed → done
    }
  }

  async function* enumerate() {
    for await (const page of pages()) {
      let items = page.items;
      if (expandItems && items.length > 0) {
        try {
          items = (await expandItems(items)) || page.items;
        } catch (error) {
          // A REFUSAL is not a shortfall. Fail-open assumes the expansion merely did not
          // arrive; when the platform says the origin turned us away, degrading would keep
          // the sweep asking. Re-raised here rather than routed through `pendingError`
          // because the pull side is already where it belongs — the engine catches it,
          // halts RESUMABLE, and the checkpoint survives.
          if (isFatalExpandFailure && isFatalExpandFailure(error)) throw error;
          items = page.items;                     // expansion is a bonus, never a blocker
          // ...but a silent bonus is how a sweep reports success having captured strictly
          // less than it meant to (098 R7): for rednote a failed note-detail is 1 cover
          // instead of 9 images. Report it; do not change the fail-open rule.
          if (onExpandFailure) {
            try { onExpandFailure(error, page.items); } catch { /* never kill the sweep */ }
          }
        }
      }
      for (const item of items) yield item;
    }
  }

  // Conforms to the engine's BulkSource seam: `enumerate(input, { cursor })` — except
  // that `cursor` is IGNORED, because an intercept source cannot seek. It reads whatever
  // the page fetches, and the page is driven by scrolling, not by a cursor we choose.
  //
  // `resumable: "scroll"` says so out loud (098 R1). Without it the engine persisted a
  // cursor on every checkpoint that nothing would ever read back — a resume token that
  // looked like a resume token and was not one. Dedup-skip is the real safety net: a
  // resumed sweep re-walks from the top and re-skips what it already has.
  // `pages` rides out beside `enumerate` for the consumer that must interleave its own work
  // with the scrolling (rednote, 098 2A/3B). It is the SAME loop `enumerate` runs on, not a
  // second one: everything below the page — expansion, and the item-level yield — is the
  // caller's from here, and X's is `enumerate`, unchanged.
  return { enumerate: () => enumerate(), pages: () => pages(), onResponse, resumable: "scroll" };
}
