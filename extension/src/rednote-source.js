// Atelier Capture — rednote push→pull source (thin adapter over intercept-source, 098 T3).
//
// The board feed cannot be pulled: every request is signed for the url it was issued for
// (098 D1), so the sweep scrolls and reads whatever the page fetches. All the queue /
// auto-scroll / stall / scope machinery lives in intercept-source.js; this file supplies
// only rednote's page parser and its scope matcher — the same shape as twitter-source.js.

import { parseBoardFeedPage, isFirstBoardFeedRequest, matchesScope } from "./bulk-rednote.js";
import { createInterceptSource, SourceStallError } from "./intercept-source.js";

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
  // this file is exactly what it was. `isFatalExpandFailure` is what keeps the two kinds
  // of expansion failure apart — a note that would not open degrades to its cover, a note
  // rednote REFUSED halts the sweep resumable.
  expandItems = null,
  isFatalExpandFailure = null,
} = {}) {
  const source = createInterceptSource({
    scroll, sleep, host, settleMs, maxIdleRounds, scope, onExpandFailure,
    expandItems, isFatalExpandFailure,
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
    if (sawFirstPage) return;
    if (scope && !matchesScope(url, scope)) return;
    if (isFirstBoardFeedRequest(url)) sawFirstPage = true;
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
    let judged = false;
    const judge = () => {
      judged = true;
      if (!sawFirstPage) throw new RednoteFeedStartError();
    };
    for await (const item of source.enumerate()) {
      if (!judged) judge();
      yield item;
    }
    if (!judged) judge();
  }

  return {
    enumerate: () => enumerate(),
    onResponse: (json, url) => { observe(url); source.onResponse(json, url); },
    // Passed through, not restated: this source resumes the way every intercept source
    // does, and a second literal here could drift from the one the seam declares.
    resumable: source.resumable,
  };
}
