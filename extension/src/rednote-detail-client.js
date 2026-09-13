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

import { parseNoteDetail } from "./bulk-rednote.js";
import { STREAM_REFUSAL } from "./rednote-video.js";
import {
  NOTE_OPEN_BUDGET, NOTE_OPEN_PACING_MS, NOTE_OPEN_PACING_JITTER_MS,
  NOTE_OPEN_TIMEOUT_MS, NOTE_OPEN_POLL_MS, NOTE_OPEN_SETTLE_MS,
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
    opened: 0, expanded: 0, degraded: 0, refused: 0, skippedKnown: 0, images: 0,
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

  /** Open one note, read its detail, and ALWAYS put the board back. */
  async function openAndRead(item, noteId) {
    let isOpen = false;
    try {
      isOpen = (await openNote(item)) !== false;
      if (!isOpen) { note("no_note_card"); return null; }
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

      if (!noteId) { note("no_note_id"); counts.degraded += 1; out.push(item); continue; }
      if (knownNotes && knownNotes.has(noteId)) { counts.skippedKnown += 1; continue; }
      if (kind === "video" && !resolveVideo) { note("video"); counts.refused += 1; out.push(item); continue; }
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
     * out to — a note that would not open or would not answer, or a budget that ran out.
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
      partial: counts.degraded > 0 || budgetExhausted,
    }),
  };
}

/** `true` when an error from `expandItems` must HALT the sweep rather than degrade it: a
 * rednote refusal (the 461 shape), which `parseNoteDetail` returns as a
 * `RednoteChallengeError`. Matched on the `challenge` flag rather than the class so the
 * board feed's own refusals — which reach the engine down a different path — cannot ever
 * be classified differently from these. */
export const isRednoteChallenge = (error) => !!(error && error.challenge === true);

// MARK: - the live page driver (browser glue — E2E-verified, injected everywhere else)

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
 * expander counts, never a throw into the sweep. UNVERIFIED against a live board — the
 * card's link shape and the overlay's close affordance are the two things here that a
 * capture could not answer — which is why the whole feature is opt-in and degrades to the
 * cover pass this file cannot break.
 */
export function createPageNoteDriver({
  win,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  settleMs = NOTE_OPEN_SETTLE_MS,
  log = () => {},
} = {}) {
  let restoreScroll = 0;

  /** The card link for a note. Matched on the id ANYWHERE in the href rather than on a
   * route shape: a board card has linked to `/explore/<id>` and to `/board/<board>/<id>`
   * in different builds, and the id is the part that identifies the note either way.
   * Guarded to hex-ish ids so nothing can smuggle a selector through an attribute. */
  const findLink = (noteId) => {
    if (!/^[A-Za-z0-9_-]{4,64}$/.test(noteId)) return null;
    const doc = win && win.document;
    if (!doc || typeof doc.querySelector !== "function") return null;
    return doc.querySelector(`a[href*="${noteId}"]`);
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
      try {
        restoreScroll = typeof win.scrollY === "number" ? win.scrollY : 0;
        if (typeof link.scrollIntoView === "function") link.scrollIntoView({ block: "center" });
        link.click();
      } catch (error) {
        log("rednote: opening the note threw:", String(error));
        return false;
      }
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
      try {
        // Still on the note's own route → the SPA navigated rather than overlaying, so the
        // history entry the click pushed is what has to come off.
        if (win.location && /\/explore\//.test(win.location.pathname || "") &&
            win.history && typeof win.history.back === "function") {
          win.history.back();
          await sleep(settleMs);
        }
      } catch (error) {
        log("rednote: the history close threw:", String(error));
      }
      try {
        // Put the viewport back where the board pass left it. The source scrolls to the
        // document bottom to page, so a note-open that ended halfway up the grid would
        // otherwise page from the wrong place — or, on a virtualised grid, from a DOM that
        // has been rebuilt around a different offset.
        if (typeof win.scrollTo === "function") win.scrollTo(0, restoreScroll);
      } catch (error) {
        log("rednote: restoring the board scroll threw:", String(error));
      }
    },
  };
}
