// Atelier Capture — rednote note-open expansion (098 T5b, K3b's driving half).
//
// The counterpart to twitter-detail-client.js, and deliberately shaped like it: everything
// the expansion feature needs from the OUTSIDE world lives here, while the shape logic it
// hands the answers to is pure and lives next door in bulk-rednote.js (`parseNoteDetail`).
//
// The difference between the two files is the whole of 098 D1. X's expander ASKS for a
// conversation — it scrapes a queryId, inherits a features blob, and issues a request
// through the hook's proxy. rednote cannot be asked: `X-s` is signed over the url it was
// issued for and `x-rap-param` sits under that, a hand-signed request was refused with
// HTTP 461, and the signer's `XYW_` prefix does not even match the `XYS_` the page sends.
// So this expander never issues anything. It DRIVES: it opens the note the way a reader
// does, the SPA makes its own correctly signed `POST /api/sns/web/v1/feed`, the MAIN-world
// hook forwards the response, and the expander reads it off a buffer. The page signs, we
// listen — generalised from "scroll to fetch more" to "open to fetch detail". A signature
// rotation cannot break it, because there is no signature on our side to rotate.
//
// Four things that are easy to get wrong, and each of which is a silent failure:
//
//   · CORRELATION. The hook's replay buffer can hand back an EARLIER note's detail — the
//     same hazard `matchesScope` guards on the board pass, which cannot be reused here
//     (a detail response carries no `board_id`). So a response is accepted only when
//     `parseNoteDetail`'s `noteId` equals the note we opened; anything else is discarded.
//   · THE RETURN. A note left open is not merely untidy: the board grid is behind an
//     overlay, the source's `scrollTo(0, scrollHeight)` then pages nothing, and the sweep
//     ends early reporting a complete board. Closing is in a `finally` for that reason.
//   · THE REFUSAL. `expandItems` degrades gracefully on a throw, which is right for a note
//     that would not open and wrong for a 461. A challenge is marked fatal so the seam
//     re-raises it (`isFatalExpandFailure`) and the sweep halts RESUMABLE.
//   · THE BUDGET. One open per note, ~400 on a large board, each one paced. The ceiling is
//     enforced here; hitting it finishes the cover pass cleanly and reports PARTIAL.
//
// Everything browser-shaped (`openNote` / `closeNote`) is injected, so the whole expander
// runs under `node --test` with no DOM. `createPageNoteDriver` at the foot is the live
// implementation of those two and is the only part that needs a real page.
//
// The foot of the file holds a SECOND live driver that is not expansion at all —
// `createPageFeedResetter` (changelog 494), which puts a mid-scrolled board back at the top
// of its feed. It lives here because it is made of exactly the moves `createPageNoteDriver`
// is made of: find an anchor the page rendered, click it rather than navigating, let the SPA
// settle, `history.back()`, put the scroll back. Those moves are now four shared functions
// below, used by both drivers. A private second copy next door is the defect — the two would
// drift, and the one that drifts is the one that silently stops working on a live page.

import { parseNoteDetail } from "./bulk-rednote.js";
import { rednoteNoteId } from "./extractors/rednote.js";
import { STREAM_REFUSAL } from "./rednote-video.js";
import {
  NOTE_OPEN_BUDGET, NOTE_OPEN_PACING_MS, NOTE_OPEN_PACING_JITTER_MS,
  NOTE_OPEN_TIMEOUT_MS, NOTE_OPEN_POLL_MS, NOTE_OPEN_SETTLE_MS, FEED_RESET_SETTLE_MS,
} from "./config.js";

/** How many un-consumed detail bodies to keep. Small on purpose: the expander opens notes
 * SERIALLY, so at most one response is genuinely awaited at a time and the rest are stale
 * replay entries. Bounded for the reason hook-core's buffer is (098 R15) — an unbounded
 * one on a 400-note sweep retains 400 whole note bodies. */
export const DETAIL_BUFFER_LIMIT = 8;

/**
 * The inbox for intercepted note-detail responses.
 *
 * Deliberately dumb: it holds bodies and hands them to a matcher. It does NOT know what a
 * note is, because knowing would mean parsing, and the parse needs the cover item's
 * `xsecToken` — which only the expander has (a detail body carries no note-level token,
 * only `user.xsec_token`, which authorizes the AUTHOR's profile and must never be used in
 * its place).
 */
export function createNoteDetailWaiter({ limit = DETAIL_BUFFER_LIMIT } = {}) {
  const buffer = [];
  return {
    /** Feed one intercepted detail response (the controller's message listener). */
    onDetail(json, url = null) {
      if (!json || typeof json !== "object") return;
      buffer.push({ json, url });
      while (buffer.length > limit) buffer.shift();
    },
    /**
     * The first body `match` accepts, or null — DISCARDING everything it rejects on the
     * way. Discarding is the point: a rejected body is a stale replay entry for a note
     * that is not the one we are waiting for, and keeping it would make every later poll
     * re-parse it. Bodies after the match are left alone.
     */
    take(match) {
      while (buffer.length > 0) {
        const entry = buffer.shift();
        const verdict = match(entry.json, entry.url);
        if (verdict) return verdict;
      }
      return null;
    },
    get size() { return buffer.length; },
  };
}

/** The note a cover item is about, or null. The cover pass keys an item by `note_id` and
 * also records it in `rawMetadata`; both are read so neither is load-bearing alone. */
export function noteIdOf(item) {
  const raw = item && item.provenance && item.provenance.rawMetadata;
  const id = (raw && raw.noteId) || (item && item.sourceId) || null;
  return id ? String(id) : null;
}

/**
 * The note-level known index, derived from the engine's known-source set (098 R14).
 *
 * R14 settled on `new Set([...knownSet].map((id) => id.split(":")[0]))` — every known id,
 * mapped to its note. That is O(n) once and O(1) per note, which is the part that matters,
 * and it is **not** what this returns, for a reason R14 could not have seen from where it
 * was written:
 *
 * A cover item is keyed `<note_id>`; an expanded child is keyed `<note_id>:<index>`. Map
 * both to their note and the two become indistinguishable — so a note that only ever
 * produced a COVER (the cover-only default, an expansion that degraded, a note the budget
 * never reached) reads as "already done" and is never opened. After the default cover-only
 * sweep that is EVERY note on the board: the toggle would silently do nothing on any board
 * already swept, which inverts the failure R14 existed to cure — that one wasted budget
 * loudly, this one is silent.
 *
 * So only ids that ARE an expanded child contribute. A note is skipped when a previous
 * sweep ingested at least one of its images, and never merely because its cover exists.
 *
 * **What counts as a child is the `:`, not the digit** — which is what let 098 T6c key a
 * video note's stream `<note_id>:v` and have it register here for free, with no change to
 * this function and no migration of anything already ingested. A video note whose stream
 * was captured is skipped on the next sweep like any expanded note; one whose ladder gave
 * nothing registers nothing and IS re-opened, which is deliberate — 020 B3 observed the
 * same note serving a different ladder minutes apart, so a refusal is a fact about one
 * visit's ladder and not about the note.
 * The sweep-level mode marker (`bulk-controller.js`) gates whether this index is consulted
 * at all; this is what makes it precise per NOTE, and it is also what lets a board larger
 * than the note-open budget make progress — the notes the budget never reached have no
 * child, so the next sweep spends its budget on them instead of re-opening the done ones.
 *
 * The residual risk R14 names is unchanged and is handled the same way: a note captured
 * PARTIALLY (a sweep that died after 3 of 9 images) looks done. That is why the caller
 * arms this ONLY when the prior sweep of this scope closed clean.
 */
export function knownNoteIndex(knownSet) {
  const notes = new Set();
  for (const id of knownSet || []) {
    if (typeof id !== "string") continue;
    const cut = id.indexOf(":");
    if (cut > 0) notes.add(id.slice(0, cut));
  }
  return notes;
}

/**
 * Build the `expandItems` hook the rednote source runs over each board page, plus the
 * `arm` and `stats` seams the controller needs around it.
 *
 * `openNote(item) => boolean` drives the SPA to open one note (false = the note's card was
 * not on the page, which is a degradation, not an error); `closeNote()` puts the board
 * back. Both are injected — see `createPageNoteDriver`.
 *
 * `resolveVideo` is the sweep's existing video toggle, threaded in because it decides
 * whether a video note has anything to give: with it off, a video note's only contribution
 * would be its poster, which the cover pass already has, so opening it buys a guaranteed
 * refusal at the price of a paced note-open — and 30 of the 37 rows of the sampled board
 * are video. With it on, the note is opened for its STREAM (098 T6c).
 *
 * Per note, in order, and every arm of it is a decision:
 *
 *   · no note id            → keep the cover. Nothing to open, nothing to correlate on.
 *   · already expanded      → yield NOTHING. Not the cover: the cover's `<note_id>` key was
 *                             never ingested for this note (its children were), so
 *                             re-emitting it would mint a brand-new item on every re-sweep.
 *                             Checked FIRST, ahead of the video arm: a note whose stream is
 *                             already captured must not be re-opened whatever kind it is,
 *                             and since T6c a video note CAN have been expanded.
 *   · `kind: "video"`, video off → keep the cover, count a REFUSAL, and do not open it at
 *                             all. Refusals are counted apart from degradations precisely
 *                             so an 81 %-video board does not report every sweep as partial
 *                             for doing exactly what it was designed to do.
 *   · budget exhausted      → keep the cover, and keep going. The cover pass finishes.
 *   · otherwise             → pace, open, await, parse, fan out.
 */
/** The `unsupported` reasons that mean "this note's STREAM was refused" rather than "this
 * note's expansion went wrong". Derived from `STREAM_REFUSAL` rather than retyped, so a new
 * refusal reason is counted correctly the day it is added instead of silently landing in
 * `degraded` and turning every sweep partial. */
const STREAM_REFUSALS = new Set(Object.values(STREAM_REFUSAL));

/** "There was no card on the page to open" — `openAndRead`'s third outcome, distinct from
 * the `null` that means "opened, and nothing usable came back". A sentinel rather than a
 * second boolean out-param because the two are counted into different fields and a reader
 * of the stats has to be able to tell them apart; collapsing them is the defect changelog
 * 495 exists to undo. */
const UNREACHED = Symbol("unreached");

export function createNoteExpander({
  waiter = createNoteDetailWaiter(),
  openNote,
  closeNote = async () => {},
  host = "www.rednote.com",
  resolveVideo = false,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  random = Math.random,
  log = () => {},
  budget = NOTE_OPEN_BUDGET,
  pacingMs = NOTE_OPEN_PACING_MS,
  pacingJitterMs = NOTE_OPEN_PACING_JITTER_MS,
  timeoutMs = NOTE_OPEN_TIMEOUT_MS,
  pollMs = NOTE_OPEN_POLL_MS,
} = {}) {
  /** null = the note-level pre-check is DISARMED (the default). A Set = armed. */
  let knownNotes = null;
  const counts = {
    // Every note this pass SET OUT to expand — the denominator of "expanded N of M", and
    // the only number that makes the others readable. A note the sweep was never going to
    // open is not in it: one already expanded by a previous sweep (`skippedKnown`) and a
    // video note with the video toggle off (`refused`) were both correctly left alone, and
    // counting them here would depress a ratio that is meant to measure a SHORTFALL.
    attempted: 0,
    opened: 0, expanded: 0, degraded: 0, refused: 0, skippedKnown: 0, images: 0,
    // COULD NOT REACH THE NOTE, as against `degraded`'s "reached it and it did not answer".
    // `openNote` returned false: the note's card was not in the DOM, so there was no anchor
    // to click and no note-open ever happened. That is not a note that misbehaved, it is a
    // STRUCTURAL limit of driving a virtualised grid — see `findLink` below, where a live
    // board was measured holding 13 mounted cards against a feed page of 37-38. It is
    // counted apart from `degraded` because the two ask for different fixes: a degradation
    // wants a longer timeout or a better parse, this wants the note opened while its card
    // is still mounted (098 2A), which is a redesign of WHEN expansion runs.
    unreachable: 0,
    // Split out from `images` since T6c: a stream is not a picture, and a board that
    // reported "37 images" for 30 videos and 7 carousels would be telling the user
    // something false about what it saved.
    streams: 0,
    // A video note that WAS opened and whose ladder gave nothing usable — 020's
    // cover-still-only outcome. Counted apart from `refused` (never opened) because the
    // two cost different things: this one spent a paced note-open.
    streamRefused: 0,
  };
  const reasons = Object.create(null);
  let budgetExhausted = false;

  const note = (reason) => { reasons[reason] = (reasons[reason] || 0) + 1; };

  /** The gap before each note-open. A skipped or refused note costs nothing — only a real
   * open is paced, so a re-sweep that skips 380 known notes is not 380 idle waits. */
  const pace = () => sleep(pacingMs + Math.floor(random() * pacingJitterMs));

  /**
   * Wait for THIS note's detail body, polling the waiter until `timeoutMs` is spent.
   *
   * A polling loop rather than a `Promise.race` against a timer, for two reasons: the
   * injected `sleep` is what tests control, and a race against a fake `sleep` that
   * resolves immediately would time out before the response it is waiting for could
   * arrive. Here a fake `sleep` that delivers a response is indistinguishable from a real
   * one that waits for it.
   *
   * Returns the parsed detail, or null on timeout. THROWS the parser's `error` — a
   * challenge — which the caller marks fatal so the seam re-raises it.
   */
  async function awaitDetail(noteId, xsecToken) {
    const match = (json) => {
      const parsed = parseNoteDetail(json, { host, xsecToken, resolveVideo });
      // A refusal has no note to correlate on and must never be silently discarded as
      // "somebody else's response" — it is the one body that outranks correlation.
      if (parsed.error) return { error: parsed.error };
      return parsed.noteId === noteId ? { parsed } : null;
    };
    for (let waited = 0; ; waited += Math.max(1, pollMs)) {
      const hit = waiter.take(match);
      if (hit && hit.error) throw hit.error;
      if (hit) return hit.parsed;
      if (waited >= timeoutMs) { note("timeout"); return null; }
      await sleep(pollMs);
    }
  }

  /** Open one note, read its detail, and ALWAYS put the board back.
   *
   * Three outcomes, not two: the detail, `null` for "opened and gave nothing usable", and
   * `UNREACHED` for "there was never a card to open". The caller must be able to tell the
   * last two apart, so they are different values rather than one falsy one. */
  async function openAndRead(item, noteId) {
    let isOpen = false;
    try {
      isOpen = (await openNote(item)) !== false;
      if (!isOpen) { note("no_note_card"); return UNREACHED; }
      return await awaitDetail(noteId, item.xsecToken ?? null);
    } finally {
      // In a `finally` because the challenge throw passes through here too: a sweep that
      // halts must still leave the tab on the board, and a note left open would wall the
      // NEXT sweep's scroll as surely as it would this one's.
      if (isOpen) {
        try {
          await closeNote();
        } catch (error) {
          log("rednote: closing the note failed — the board scroll may be blocked:", String(error));
        }
      }
    }
  }

  async function expandItems(items) {
    if (!Array.isArray(items) || items.length === 0) return items;
    const out = [];
    for (const item of items) {
      const noteId = noteIdOf(item);
      const kind = item && item.provenance && item.provenance.rawMetadata
        ? item.provenance.rawMetadata.kind : null;

      if (!noteId) { note("no_note_id"); counts.attempted += 1; counts.degraded += 1; out.push(item); continue; }
      if (knownNotes && knownNotes.has(noteId)) { counts.skippedKnown += 1; continue; }
      if (kind === "video" && !resolveVideo) { note("video"); counts.refused += 1; out.push(item); continue; }
      // Past this line the note is a CANDIDATE: the sweep meant to expand it, and whether
      // it did is this pass's coverage rather than a decision it made on purpose. A note
      // the budget never reached counts too — "we ran out" is a shortfall, not a choice.
      counts.attempted += 1;
      if (counts.opened >= budget) {
        if (!budgetExhausted) {
          budgetExhausted = true;
          log("rednote: note-open budget of", budget, "spent — the rest of the board keeps its covers");
        }
        note("budget");
        out.push(item);
        continue;
      }

      await pace();
      counts.opened += 1;
      const parsed = await openAndRead(item, noteId);
      if (parsed === UNREACHED) { counts.unreachable += 1; out.push(item); continue; }
      if (!parsed) { counts.degraded += 1; out.push(item); continue; }
      if (parsed.unsupported) {
        // `items: []` with a reason means KEEP THE COVER (098 R7 / changelog 485). It never
        // means the note is empty, and dropping it here would lose a picture the cover pass
        // had already captured.
        note(parsed.unsupported);
        // A video that slipped past the board row's `kind` (the row said image, the note
        // says video) is the same deliberate refusal, not a failure of this sweep.
        if (parsed.unsupported === "video") counts.refused += 1;
        // A ladder that yielded nothing is 020's cover-still-only outcome — a TYPED SKIP,
        // not a shortfall. It does not make the sweep partial: the note was opened, its
        // ladder was read, and there was no decodable stream in it. Calling that "partly
        // expanded" would put an 81 %-video board back where T5b's `refused`/`degraded`
        // split took it out of — reporting partial on every sweep for working correctly.
        else if (STREAM_REFUSALS.has(parsed.unsupported)) counts.streamRefused += 1;
        else counts.degraded += 1;
        out.push(item);
        continue;
      }
      counts.expanded += 1;
      if (parsed.noteKind === "video") {
        // The cover rides ALONGSIDE the stream, not replaced by it. Two reasons, and the
        // second is the load-bearing one: the poster is a real picture at a key
        // (`<note_id>`) the cover pass already uses, so keeping it costs one dedup-skip and
        // nothing else; and the stream's ladder can still be exhausted at INGEST time, long
        // after this parse, at which point 020's "keep the cover still" has to already be
        // true. It is — the cover is a separate item that ingests on its own.
        counts.streams += parsed.items.length;
        out.push(item);
      } else {
        counts.images += parsed.items.length;
      }
      out.push(...parsed.items);
    }
    return out;
  }

  return {
    expandItems,
    /** Feed an intercepted detail response through to the waiter. */
    onDetail: (json, url) => waiter.onDetail(json, url),
    /**
     * Arm (or leave disarmed) the note-level known-set pre-check at sweep start. The
     * controller decides `armed` from the clean marker's `clean` AND its recorded MODE —
     * a cover-only prior sweep must never arm an expansion sweep's pre-check.
     */
    arm({ knownSet = null, armed = false } = {}) {
      knownNotes = armed && knownSet ? knownNoteIndex(knownSet) : null;
      if (knownNotes) log("rednote: note-level pre-check armed over", knownNotes.size, "expanded notes");
      return knownNotes ? knownNotes.size : 0;
    },
    /**
     * What this sweep's expansion actually did (098 R7's first-class outcome).
     *
     * `partial` is the load-bearing field: true when this sweep expanded LESS than it set
     * out to — a note that could not be REACHED, a note that would not answer, or a budget
     * that ran out. `unreachable` is named in it explicitly rather than riding inside
     * `degraded`: pulling the unmounted-card case out of `degraded` (so a reader can tell
     * "no card on the page" from "the page did not answer") would otherwise have made a
     * board where EVERY note was unreachable report `degraded: 0, partial: false` — a
     * total failure to expand wearing the sentence of a complete one. The truth value is
     * unchanged from before the split; only the spelling is.
     *
     * `attempted` is the denominator the rest are read against. Without it "4 kept covers
     * only" is the same line whether the sweep expanded 400 notes or 0, which is exactly
     * the report a virtualised board produces (13 of 116) and exactly what must not read
     * as a success.
     *
     * Two things are deliberately NOT shortfalls, and T6c re-examined both rather than
     * inheriting them. A note skipped because it was already expanded is not one. And
     * neither kind of video refusal is one: `refused` is a note the sweep was told not to
     * open (the video toggle is off — expansion was never on offer for it), and
     * `streamRefused` is a note that WAS opened and whose ladder held no decodable stream,
     * which is 020's typed skip — the sweep did everything it set out to do and the content
     * is not there in a form we can take. Counting either as partial would report an
     * 81 %-video board as partly expanded on every single sweep, which is the failure T5b's
     * split exists to prevent. Both are counted and both are named in `reasons`, so a user
     * who wants the number can have it without the status line crying wolf.
     */
    stats: () => ({
      mode: "expansion",
      budget,
      ...counts,
      budgetExhausted,
      reasons: { ...reasons },
      partial: counts.degraded > 0 || counts.unreachable > 0 || budgetExhausted,
    }),
  };
}

/** `true` when an error from `expandItems` must HALT the sweep rather than degrade it: a
 * rednote refusal (the 461 shape), which `parseNoteDetail` returns as a
 * `RednoteChallengeError`. Matched on the `challenge` flag rather than the class so the
 * board feed's own refusals — which reach the engine down a different path — cannot ever
 * be classified differently from these. */
export const isRednoteChallenge = (error) => !!(error && error.challenge === true);

// MARK: - the live page drivers (browser glue — E2E-verified, injected everywhere else)
//
// The four moves below are SHARED by `createPageNoteDriver` and `createPageFeedResetter`.
// Both drive the same SPA through the same affordances and neither may ever navigate: a
// board page is the sweep's own host document, so assigning `location` (or opening a
// window) would tear down the content script, the engine and the sweep with it. Every one
// of them is guarded and returns a verdict instead of throwing — a page that will not be
// driven is a degradation the caller reports, never an exception into the sweep.

/** An anchor's href as written, falling back to the resolved `.href` property. Guarded:
 * a detached or exotic node must degrade to the empty string, never throw. */
const hrefOf = (node) => {
  try {
    const attr = node && typeof node.getAttribute === "function" ? node.getAttribute("href") : null;
    return String(attr || (node && node.href) || "");
  } catch {
    return "";
  }
};

/** Click one of the page's OWN anchors, the way a reader does. Scrolled into view first so
 * the click lands on something the SPA considers visible. `what` names the caller for the
 * log line, which is the only signal a live run gets when a page stops being drivable. */
function clickAnchor(node, { log = () => {}, what = "the page" } = {}) {
  try {
    if (node && typeof node.scrollIntoView === "function") node.scrollIntoView({ block: "center" });
    node.click();
    return true;
  } catch (error) {
    log(`rednote: clicking ${what} threw:`, String(error));
    return false;
  }
}

/** Pop one history entry. The ONLY way back that keeps the content script alive. */
function goBack(win, { log = () => {} } = {}) {
  try {
    if (win && win.history && typeof win.history.back === "function") {
      win.history.back();
      return true;
    }
  } catch (error) {
    log("rednote: the history back threw:", String(error));
  }
  return false;
}

/** Put the viewport at `y`. The source pages the board by scrolling, so where a driver
 * leaves the viewport decides where the NEXT fetch pages from. */
function scrollWindowTo(win, y, { log = () => {} } = {}) {
  try {
    if (win && typeof win.scrollTo === "function") win.scrollTo(0, y);
  } catch (error) {
    log("rednote: restoring the board scroll threw:", String(error));
  }
}

/** The SPA's current route, or "" — the only readable evidence that a click navigated. */
const pathnameOf = (win) => {
  try {
    return (win && win.location && win.location.pathname) || "";
  } catch {
    return "";
  }
};

/**
 * `openNote` / `closeNote` against a real rednote board page.
 *
 * The note is opened by CLICKING its card's link, not by navigating: a board page is the
 * sweep's own host document, and assigning `location` would tear down the content script,
 * the engine and the sweep with it. rednote opens a note as an overlay over the board, so
 * a click keeps the grid — and the intercept source's scroll position — alive underneath.
 *
 * Closing tries Escape first (the overlay's own affordance) and falls back to
 * `history.back()` when the SPA routed instead of overlaying; the scroll position is
 * saved and restored around the whole thing, because the source pages the board by
 * scrolling and a note-open that left the viewport somewhere else would page from there.
 *
 * Everything is guarded and best-effort: a failure to open or close is a degradation the
 * expander counts, never a throw into the sweep — which is why the whole feature is opt-in
 * and degrades to the cover pass this file cannot break.
 *
 * THE CARD'S LINK SHAPE IS NO LONGER A GUESS. A live board
 * (`/board/69322476000000001202811f`) was probed in the console on 2026-09-14 and every
 * anchor dumped in document order:
 *
 *     /board/<board_id>/<note_id>                                  <- NO token
 *     /board/<board_id>/<note_id>?xsec_token=AB40…Y1w=&xsec_source=
 *
 * The board renders TWO anchors per note and the TOKENLESS ONE COMES FIRST, so a
 * `querySelector` that asks only for the id picks it — and rednote answers 404 for a note
 * URL with no `xsec_token`. That was not a theory: it was the 404 the user watched the
 * sweep open. Hence `findLink` below chooses on the TOKEN, not on document order.
 *
 * The overlay's close affordance is still the one thing here a capture cannot answer.
 */
export function createPageNoteDriver({
  win,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  settleMs = NOTE_OPEN_SETTLE_MS,
  log = () => {},
} = {}) {
  let restoreScroll = 0;

  /** A note URL that will actually open: `xsec_token=` with SOMETHING after it. Only the
   * token is tested. `xsec_source` sits beside it and varies by where the reader came from
   * — EMPTY on the board card probed above, `pc_user` on a note the user opened by hand —
   * so requiring it would reject the very anchor this function exists to find. */
  const TOKENISED = /[?&]xsec_token=[^&#]/;

  /**
   * The card link for a note — the TOKENISED one when the page renders one.
   *
   * Matched on the id ANYWHERE in the href rather than on a route shape, deliberately and
   * still: a note is reachable at `/explore/<id>`, at `/discovery/item/<id>` and at
   * `/board/<board>/<id>` (all three observed live), and the id is the part that identifies
   * it in every one of them. Narrowing to a route would trade one silent failure for
   * another the day the SPA picks a different one.
   *
   * What is NOT incidental is WHICH of the matching anchors is clicked. The board emits a
   * tokenless anchor and a tokenised anchor for the same note, tokenless first, and a note
   * URL without `xsec_token` 404s — so the choice is made on the token and document order
   * is only the tie-break among tokenised ones. A tokenless anchor is still clicked when it
   * is the ONLY one, because a 404 that degrades is strictly better than refusing a note
   * whose card is plainly there; it is logged, because it is a shape change worth seeing.
   *
   * WHAT THIS CANNOT DO, MEASURED. The board grid is VIRTUALISED: it mounts roughly a
   * screenful of cards and unmounts the rest. A console probe on a live board
   * (`/board/69322476000000001202811f`, 2026-09-14) counted the DISTINCT note cards in the
   * DOM and found **13**, while one feed page carries **37-38** notes and the whole board
   * holds **116**. A note with no mounted card has no anchor, so this returns null,
   * `openNote` returns false, and the note is counted `unreachable` and keeps its cover.
   *
   * That is not a bug in the selector and no selector can fix it — the element is not in
   * the document. It is a consequence of WHEN expansion runs: a whole feed page of 37-38
   * notes is expanded AFTER that page has arrived, by which time the grid has scrolled on
   * and most of those cards are gone. The fix is 098 2A — interleave the opening with the
   * scrolling so each note is opened while its card is still mounted — and it is a
   * redesign of the source's page loop, not of this function. Until then this file's job
   * is to report the shortfall accurately (changelog 495), not to hide it.
   *
   * ONLY the note id is ever interpolated into the selector, and only after the id guard —
   * so nothing can smuggle a selector through an attribute. The token is never interpolated
   * at all: it contains `=` and `-` and (being page-supplied) could contain a quote, and
   * the filtering is done in JS where it cannot break out of anything.
   */
  const findLink = (noteId) => {
    if (!/^[A-Za-z0-9_-]{4,64}$/.test(noteId)) return null;
    const doc = win && win.document;
    if (!doc || typeof doc.querySelectorAll !== "function") return null;
    const nodes = Array.from(doc.querySelectorAll(`a[href*="${noteId}"]`) || []);
    const tokenised = nodes.find((node) => TOKENISED.test(hrefOf(node)));
    if (tokenised) return tokenised;
    if (nodes.length > 0) {
      log("rednote: no anchor for", noteId, "carries an xsec_token — the open may 404");
    }
    return nodes[0] || null;
  };

  return {
    async openNote(item) {
      const noteId = noteIdOf(item);
      if (!noteId) return false;
      let link = null;
      try {
        link = findLink(noteId);
      } catch (error) {
        log("rednote: looking up the note card threw:", String(error));
        return false;
      }
      if (!link) return false;
      restoreScroll = typeof win.scrollY === "number" ? win.scrollY : 0;
      if (!clickAnchor(link, { log, what: "the note card" })) return false;
      await sleep(settleMs);
      return true;
    },

    async closeNote() {
      const doc = win && win.document;
      try {
        if (doc && typeof doc.dispatchEvent === "function" && typeof win.KeyboardEvent === "function") {
          doc.dispatchEvent(new win.KeyboardEvent("keydown", {
            key: "Escape", code: "Escape", keyCode: 27, bubbles: true, cancelable: true,
          }));
        }
      } catch (error) {
        log("rednote: the Escape close threw:", String(error));
      }
      await sleep(settleMs);
      // Still on a note's own route → the SPA navigated rather than overlaying, so the
      // history entry the click pushed is what has to come off. WHICH pathnames are a
      // note is the extractor's `rednoteNoteId`, shared rather than retyped: a private
      // copy here spelled `/explore/` alone, and the board card routes to
      // `/board/<board_id>/<note_id>` — so on the live board this fallback never fired.
      if (rednoteNoteId(pathnameOf(win)) && goBack(win, { log })) await sleep(settleMs);
      // Put the viewport back where the board pass left it. The source scrolls to the
      // document bottom to page, so a note-open that ended halfway up the grid would
      // otherwise page from the wrong place — or, on a virtualised grid, from a DOM that
      // has been rebuilt around a different offset.
      scrollWindowTo(win, restoreScroll, { log });
    },
  };
}

/** The board's own profile link — the "away" leg. A CONSTANT selector: unlike `findLink`,
 * which must interpolate a (guarded) note id, nothing page-supplied goes near this one. */
const PROFILE_LINK_SELECTOR = 'a[href*="/user/profile/"]';

/** …and the href shape that makes a match a real profile ROUTE rather than an anchor that
 * merely mentions one. `[href*=…]` is a SUBSTRING match, so it also selects
 * `/login?redirect=/user/profile/<id>` — an anchor whose click goes somewhere else entirely,
 * and whose back leg would therefore land somewhere else entirely. The profile path has to
 * begin the href's own path, and carry an id. Checked in JS, where (like the note driver's
 * token test) it cannot break out of anything. */
const PROFILE_HREF = /^(?:https?:\/\/[^/]+)?\/user\/profile\/[A-Za-z0-9_-]{4,}(?:[/?#]|$)/;

/**
 * Put a mid-scrolled board back at the START of its feed, IN PAGE (changelog 494).
 *
 * 493 established that the board feed pages FORWARD only: a response's `cursor` buys the
 * next slice, no request walks back, and the sweep's one lever is a scroll to the bottom —
 * so a run that did not hold the opening slice can never fetch it, and 493 refuses such a
 * run rather than under-capturing quietly. This is the other half: rather than telling the
 * user to reload, the sweep puts the feed back itself, and 493's rule becomes the ASSERTION
 * that it worked.
 *
 * A RELOAD is not available — it tears down the content script the sweep runs in (493
 * rejected it for exactly that reason) — but the SPA can be driven, which is the same idiom
 * `createPageNoteDriver` already relies on.
 *
 * THE SEQUENCE IS NOT A GUESS, and it is not interchangeable with a simpler one. Verified in
 * the user's own browser on 2026-09-14, on a mid-scrolled board, with the hook logging every
 * board-feed request url:
 *
 *     [req] cursor= "6a804923000000002c001f0c"   <- from scrolling
 *     [req] cursor= ""                            <- after navigating BACK to the board
 *
 * The `cursor=` is empty on that second line — the opening slice, refetched. What produced
 * it was a PAIR of moves: forward-navigate to another SPA route (the board's own
 * `/user/profile/<id>` link), then browser-BACK to the board. The back is what triggered the
 * refetch. `history.back()` alone from an unknown state pops whatever entry happens to be
 * behind the board and lands somewhere nobody chose; assigning `location` kills the sweep.
 * Neither is this.
 *
 * Returns `true` only when the board was actually left and actually returned to. It never
 * throws and it never waits for the response — the CALLER owns the evidence, because the
 * evidence is the request url and `rednote-source.js` is the only thing that sees it. A
 * `false` here, or a `true` whose refetch never comes, both land in the same place: 493's
 * refusal, with its "reload the board page, then start the sweep again". A reset that
 * silently failed must never become a sweep that silently under-captures.
 */
export function createPageFeedResetter({
  win,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  settleMs = FEED_RESET_SETTLE_MS,
  log = () => {},
} = {}) {
  /**
   * Suppress the browser's own scroll restoration across the back, and put it back after.
   *
   * The point of the reset is to be at the TOP of a feed. A back navigation restores the
   * scroll offset the board had when it was left — which is halfway down the grid, which is
   * where the SPA's infinite scroll would immediately fetch the NEXT page from, defeating
   * the refetch we came for. `manual` is scoped to this navigation and restored afterwards
   * because it is a property of the user's page, not ours to keep.
   */
  const suppressScrollRestoration = () => {
    let previous = null;
    let applied = false;
    try {
      const history = win && win.history;
      if (history && "scrollRestoration" in history) {
        previous = history.scrollRestoration;
        history.scrollRestoration = "manual";
        applied = true;
      }
    } catch (error) {
      log("rednote: pinning the scroll restoration threw:", String(error));
    }
    return () => {
      if (!applied) return;
      try {
        win.history.scrollRestoration = previous;
      } catch (error) {
        log("rednote: releasing the scroll restoration threw:", String(error));
      }
    };
  };

  /** The board's profile anchor, or null. An empty board, or a layout that stopped
   * rendering one, simply has no away leg — and that degrades to 493's refusal. */
  const findProfileLink = () => {
    const doc = win && win.document;
    if (!doc || typeof doc.querySelectorAll !== "function") return null;
    try {
      const nodes = Array.from(doc.querySelectorAll(PROFILE_LINK_SELECTOR) || []);
      return nodes.find((node) => PROFILE_HREF.test(hrefOf(node))) || null;
    } catch (error) {
      log("rednote: looking up the board's profile link threw:", String(error));
      return null;
    }
  };

  return async function resetFeed() {
    const link = findProfileLink();
    if (!link) {
      log("rednote: no /user/profile/ link on this board — the feed cannot be restarted in page");
      return false;
    }

    const board = pathnameOf(win);
    const release = suppressScrollRestoration();
    try {
      if (!clickAnchor(link, { log, what: "the board's profile link" })) return false;
      await sleep(settleMs);

      // THE GUARD ON THE BACK, and the reason the click is checked at all. If the click did
      // not route — an overlay, an intercepted anchor, a build that renders the profile in
      // place — then the top of the history stack is still the board, and `history.back()`
      // would pop the BOARD off and land the sweep on whatever the user was looking at
      // before it. That is the "back from an unknown state" this sequence exists not to be.
      if (pathnameOf(win) === board) {
        log("rednote: the profile link did not route away from", board, "— leaving the history alone");
        return false;
      }
      if (!goBack(win, { log })) return false;
      await sleep(settleMs);

      // And the mirror: back landed somewhere that is not the board (an SPA that pushed two
      // entries, a redirect). Nothing is retried — a second blind back is the same unknown
      // state from one step further away. The sweep is left to 493's refusal, which tells
      // the user to reload the board, which fixes this too.
      if (pathnameOf(win) !== board) {
        log("rednote: going back landed on", pathnameOf(win), "not the board", board);
        return false;
      }

      // The sweep wants the TOP. `scrollRestoration: manual` is what stops the browser
      // putting the old offset back; this is what puts the new one where the sweep expects.
      scrollWindowTo(win, 0, { log });
      return true;
    } finally {
      release();
    }
  };
}
