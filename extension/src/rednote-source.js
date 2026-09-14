// Atelier Capture — rednote push→pull source (thin adapter over intercept-source, 098 T3).
//
// The board feed cannot be pulled: every request is signed for the url it was issued for
// (098 D1), so the sweep scrolls and reads whatever the page fetches. All the queue /
// auto-scroll / stall / scope machinery lives in intercept-source.js; this file supplies
// only rednote's page parser and its scope matcher — the same shape as twitter-source.js.

import { parseBoardFeedPage, isFirstBoardFeedRequest, matchesScope } from "./bulk-rednote.js";
import { createInterceptSource, SourceStallError } from "./intercept-source.js";
import {
  FEED_RESET_GRACE_MS, FEED_RESET_TIMEOUT_MS, FEED_RESET_POLL_MS,
  NOTE_REACH_SETTLE_MS, NOTE_REACH_ROUNDS,
} from "./config.js";

/** rednote's stall: scrolling stopped producing pages before an `endOfFeed` one. Thrown
 * so the engine halts the sweep RESUMABLE instead of recording a partial board complete. */
export class RednoteStallError extends SourceStallError {
  constructor(idleRounds) {
    super(idleRounds, "rednote board");
    this.name = "RednoteStallError";
  }
}

/**
 * rednote's OTHER silent under-capture: the run never held the feed's first page, so a
 * whole page of notes was unreachable before it began (1A).
 *
 * Thrown from `enumerate`, which the engine treats exactly as it treats the stall and the
 * 461 refusal — a RESUMABLE halt, checkpoint kept, the job closed `paused`. That is the
 * whole point: the alternative this replaces is a sweep that ingests pages B·C·D, records
 * the board `complete`, clears the checkpoint and reports success having silently dropped
 * 38 of 116 notes.
 *
 * The message is USER-FACING copy, not a developer note: `terminalMessage` renders a
 * halted sweep's error verbatim in the popup, so the sentence has to end in something the
 * user can DO. It lives here rather than in a popup string table because there is exactly
 * one of it and a second copy could only ever disagree with this one.
 */
export class RednoteFeedStartError extends Error {
  constructor() {
    super(
      "The sweep did not start at the top of this board. rednote's board feed only pages "
      + "FORWARD, so notes above where the page was already scrolled cannot be fetched at "
      + "all — sweeping from here would silently miss them. Reload the board page, then "
      + "start the sweep again without scrolling first.",
    );
    this.name = "RednoteFeedStartError";
    this.missedFirstPage = true;
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
  // K3b's note-open expansion (098 D4), OPT-IN: omitted, the sweep is the cover pass and
  // every line below that mentions a note is skipped. `isFatalExpandFailure` is what keeps
  // the two kinds of expansion failure apart — a note that would not open degrades to its
  // cover, a note rednote REFUSED halts the sweep resumable.
  //
  // Since 2A this is the EXPANDER ITSELF (`createNoteExpander`), not its `expandItems`
  // hook, because the pass is no longer page-at-a-time: it needs `attemptNote` and
  // `retireNote` per note, interleaved with `scrollStep`. See `expandPage` below.
  expander = null,
  isFatalExpandFailure = null,
  // `() => boolean` — walk the board down one screen so the virtualised grid mounts its
  // next band of cards; false when the viewport was already at the foot. Omitted, the pass
  // gets exactly ONE attempt per note per page, which is what expansion did before 2A.
  scrollStep = null,
  reachSettleMs = NOTE_REACH_SETTLE_MS,
  maxReachRounds = NOTE_REACH_ROUNDS,
  // 2A's in-page feed reset (changelog 494). `resetFeed` is the live page driver
  // (`createPageFeedResetter`) — OMITTED, this file behaves exactly as 493 left it, which
  // is what every test that predates the reset relies on.
  resetFeed = null,
  graceMs = FEED_RESET_GRACE_MS,
  resetTimeoutMs = FEED_RESET_TIMEOUT_MS,
  resetPollMs = FEED_RESET_POLL_MS,
  log = () => {},
} = {}) {
  const source = createInterceptSource({
    scroll, sleep, host, settleMs, maxIdleRounds, scope,
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

  // ── 1A: refuse a run that cannot prove it started at the feed's beginning ──────────
  //
  // Two wrappers, and NOTHING in intercept-source.js: the seam is shared with X and the
  // rule is rednote's alone. `parsePage` never sees the request url, and the url is the
  // only place the evidence exists (`cursor=` empty ⇒ the opening slice), so the
  // observation has to happen where the url still is — `onResponse` — and the JUDGEMENT
  // has to happen on the pull side, where a throw becomes a resumable halt.
  //
  // Scoped exactly as `onResponse` scopes ingestion. Another board's first page is a first
  // page of the WRONG feed; letting it vouch for this run would license the very sweep the
  // rule refuses, out of a stale replay-buffer entry.
  let sawFirstPage = false;

  function observe(url) {
    if (scope && !matchesScope(url, scope)) return;
    if (!isFirstBoardFeedRequest(url)) return;
    // The RESET's own refetch (below) — so everything still held from before it belongs to
    // a page session that no longer exists, and is dropped. See `held`. Guarded on
    // `sawFirstPage` as well as on `resetting`: only the FIRST opening slice of the reset
    // divides the sessions, and a second one arriving behind it must not then discard it.
    if (resetting && !sawFirstPage) held.length = 0;
    sawFirstPage = true;
  }

  /** 493's refusal, in ONE place, reached from both the moment below and the generator's
   * judge. Same evidence, same error, same resumable halt — the reset does not get its own
   * rule, it gets judged by the existing one. */
  function refuseUnlessStarted() {
    if (!sawFirstPage) throw new RednoteFeedStartError();
  }

  // ── 2A: put the feed back at its start before enumerating ─────────────────────────
  //
  // 493 refuses a run that cannot prove it holds the opening slice. That is a guard, not a
  // fix: the user still has to reload by hand. This drives the SPA — forward to the board's
  // profile link, then BACK — which was verified live to make the board refetch with an
  // empty `cursor` (see `createPageFeedResetter`). 493's rule then becomes the assertion
  // that the reset worked, which is why nothing here weakens or bypasses it.
  //
  // A response that arrives before the decision is HELD rather than forwarded. Not
  // fastidiousness: a board scrolled to its very bottom replays the exhausted TAIL page
  // (`has_more:false`), and a tail queued ahead of the refetched page A would END the
  // enumeration before page A was ever yielded — a `complete` sweep missing the opening
  // slice, which is the exact defect being fixed, rebuilt out of its own repair. A reset
  // discards what the previous page session fetched; the board re-serves all of it from the
  // top, so nothing is lost and no extra fetch is spent. The hold is bounded by `graceMs` +
  // `resetTimeoutMs` and by the hook's own replay cap.
  const held = [];
  let holding = typeof resetFeed === "function";
  let resetting = false;
  let startPromise = null;

  const flush = () => {
    holding = false;
    while (held.length > 0) source.onResponse(...held.shift());
  };

  /** Poll `ready` until it is true or `budgetMs` is spent. The expander's `awaitDetail`
   * idiom, for the same reason: the injected `sleep` is what tests drive, so a fake one
   * that delivers the response it is waited on is indistinguishable from a real wait. */
  async function waitFor(ready, budgetMs) {
    for (let waited = 0; ; waited += Math.max(1, resetPollMs)) {
      if (ready()) return true;
      if (waited >= budgetMs) return false;
      await sleep(resetPollMs);
    }
  }

  /**
   * ONCE per source, whatever pulls it (a resumed sweep, a retried start, two enumerates).
   * Memoised rather than flagged, so a second caller awaits the first attempt instead of
   * racing a second navigation onto the page.
   *
   * The GRACE is 493's timing argument, moved earlier. The controller posts the replay
   * request and returns; the buffered responses land asynchronously. Deciding without
   * waiting for them would navigate a freshly-loaded board for nothing — and an unnecessary
   * navigation is real automation footprint against a site running an active risk-control
   * layer (`xhsFingerprintV3`), one that already answered a scripted request with HTTP 461.
   * The common case — a board the user just opened — therefore drives NOTHING, and pays only
   * as long as its replay takes to arrive.
   */
  async function start() {
    if (typeof resetFeed !== "function") return;
    await waitFor(() => sawFirstPage, graceMs);
    if (sawFirstPage) { flush(); return; }

    resetting = true;
    try {
      log("rednote: this board is not at the start of its feed — restarting it in page");
      if (await resetFeed()) await waitFor(() => sawFirstPage, resetTimeoutMs);
    } catch (error) {
      // A driver that threw is a driver that did not reset. Same outcome as one that
      // returned false: 493 refuses, and the user is told to reload the board.
      log("rednote: restarting the feed threw:", String(error));
    } finally {
      resetting = false;
    }
    flush();
    // The reset was ATTEMPTED and the opening slice still did not arrive, so there is
    // nothing left to wait for — the grace and the timeout have both been spent. Refusing
    // HERE rather than at the first yield is what closes 493's wasted-work window: with
    // note-opening on, the judge inside the loop fires only after the first queued page has
    // been expanded, which is up to a page of note-opens spent on a sweep that was always
    // going to halt. Nothing is pulled from the seam at all now, so nothing is expanded.
    refuseUnlessStarted();
  }

  // ── 098 2A + 3B (changelog 497): open each note while its card is still mounted ────
  //
  // THE TWO DEFECTS, both measured on a live 116-note board.
  //
  // 2A. The board grid is VIRTUALISED: 13 note cards in the DOM against 37-38 notes in a
  // feed page. `createPageNoteDriver` can only click a card that exists, and expansion used
  // to run over a whole page AFTER it arrived — by which time the grid had scrolled on and
  // most of those cards were gone. So 103 of 116 notes returned "no card on the page" and
  // degraded to their covers (changelog 495 made that visible; it did not fix it).
  //
  // 3B. Nothing was yielded until the WHOLE page had been expanded: `items = await
  // expandItems(items)` and only then the yields. At ~2.4 s pacing plus up to 8 s of
  // waiting per note, that is two to five minutes before the first item reaches the app.
  //
  // ONE cause, one fix. The scroll already mounts cards as it goes, so expansion RIDES the
  // scroll instead of fighting it: work the page's notes in feed order, open the ones whose
  // cards are mounted NOW, yield each note the moment it is answered, step the viewport
  // down, ask the rest again. A note is conceded to its cover only when the pass has walked
  // the whole page and so has demonstrably passed it.
  //
  // THE TRAP, and it is the important one. Expansion REPLACES a note's cover with its
  // children, so a note must yield its cover OR its children, never both and never twice —
  // for a video note the cover and the poster are one picture, and `<note_id>` beside
  // `<note_id>:0` is one image ingested under two keys with a dedup-skip that cannot see
  // it. A single pass could not make that mistake; a pass that asks a note again after
  // every scroll, and meets repeated rows across a page boundary, can. It is prevented in
  // the expander's ledger (`done`), not here: this loop's own guarantee is narrower and
  // structural — an entry leaves `pending` at the instant it is settled, and only a settled
  // entry produces items.
  const inReach = typeof scrollStep === "function";

  /**
   * Expand ONE board page, streaming, and yield what each note turns out to be.
   *
   * The rounds terminate on the page itself, not on a clock: the walk stops when the
   * viewport reaches the foot of the document (`scrollStep` false — every card of this page
   * has now been scrolled past) or when the ceiling of rounds is spent. Whatever is still
   * pending then gets its cover. Without a `scrollStep` there is exactly one round, which is
   * the pre-2A behaviour and what a caller with no page to drive can do.
   */
  async function* expandPage(items) {
    let pending = items;
    for (let round = 0; ; round += 1) {
      const stillPending = [];
      for (const item of pending) {
        let verdict;
        try {
          verdict = await expander.attemptNote(item);
        } catch (error) {
          // A REFUSAL is not a shortfall. Fail-open assumes the expansion merely did not
          // arrive; when the platform says the origin turned us away, degrading would keep
          // the sweep asking — so it is re-raised, the engine halts RESUMABLE, and the
          // checkpoint survives. Everything already yielded stays ingested, which is the
          // same trade the board feed's own fatal route makes one page higher up: what
          // arrived before the refusal is kept, and nothing is relayed after it.
          if (isFatalExpandFailure && isFatalExpandFailure(error)) throw error;
          // ...and a silent bonus is how a sweep reports success having captured strictly
          // less than it meant to (098 R7). The note degrades to its cover — by itself now,
          // not dragging the other 37 notes of its page down with it.
          if (onExpandFailure) {
            try { onExpandFailure(error, [item]); } catch { /* never kill the sweep */ }
          }
          verdict = expander.failNote(item, error);
        }
        if (!verdict.settled) { stillPending.push(item); continue; }
        yield* verdict.items;
      }
      pending = stillPending;
      if (pending.length === 0) return;
      if (round + 1 >= maxReachRounds) break;
      if (!inReach) break;
      if (!(await scrollStep())) break;      // at the foot: we have passed every card
      await sleep(reachSettleMs);
    }
    // The pass has walked the page and these notes never had a card. They keep the cover the
    // board pass captured — exactly once, and counted `unreachable` exactly once.
    for (const item of pending) yield* expander.retireNote(item).items;
  }

  /** The item stream when notes are being opened: the seam's pages, each one expanded in
   * scroll order. The seam's own `expandItems` hook cannot serve this and is left to X —
   * nothing scrolls while it runs, which is the whole of 2A. */
  async function* expandingItems() {
    for await (const page of source.pages()) {
      if (page.items.length > 0) yield* expandPage(page.items);
    }
  }

  /**
   * WHEN the rule fires is the whole of its correctness, and it is NOT at construction.
   * The controller posts the replay request and returns immediately; the hook's buffered
   * responses come back asynchronously, one `postMessage` task each, and land during the
   * source's first settle. A check at construction — or on the first response parsed —
   * would refuse a perfectly good sweep for the crime of not having received its replay
   * yet, and would also mis-read a replay that arrived out of order.
   *
   * So it fires at the first moment there is anything to judge: the first item about to be
   * yielded. By then the queue has been filled by the whole replay burst, and a first page
   * that arrived third still counts.
   *
   * The trailing call is the same rule for the feed that yields NOTHING — a run whose only
   * response is the cursored empty tail page. That path returns without yielding, and
   * without this it would close `complete` having captured nothing at all, which is the
   * silent success this decision exists to abolish.
   *
   * Two things deliberately win over it, because they are checked earlier in the seam: a
   * 461 refusal (`pendingError`, thrown at the top of the loop) and a stall. Both are
   * halts of their own with better-fitting messages, and all three are resumable.
   */
  async function* enumerate() {
    startPromise = startPromise || start();
    await startPromise;
    let judged = false;
    const judge = () => {
      judged = true;
      refuseUnlessStarted();
    };
    // The cover pass is the seam's own `enumerate`, byte for byte what it was: with no
    // expander nothing below is reached, and the pass verified live against a 116-note
    // board is not touched by any of 2A.
    for await (const item of (expander ? expandingItems() : source.enumerate())) {
      if (!judged) judge();
      yield item;
    }
    if (!judged) judge();
  }

  return {
    enumerate: () => enumerate(),
    onResponse: (json, url) => {
      observe(url);
      if (holding) held.push([json, url]);
      else source.onResponse(json, url);
    },
    // Passed through, not restated: this source resumes the way every intercept source
    // does, and a second literal here could drift from the one the seam declares.
    resumable: source.resumable,
  };
}
