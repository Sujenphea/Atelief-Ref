// Atelier Capture — rednote end-to-end integration: fixtures → source → engine (098 T4, R12).
//
// The board-feed parser (bulk-rednote.js), the push→pull seam (intercept-source.js, via
// rednote-source.js) and the sweep engine (bulk-engine.js) are each unit-tested in
// isolation; nothing proved they COMPOSE. These do: a fake `scroll` feeds intercepted
// pages in exactly as the MAIN-world hook would, `runSweep` pulls them, and a recording
// relay stands in for the SW. `intercept-source.test.js` already covers the seam
// generically with fakes — what is here is only what needs REAL pages, a real parser and
// a real engine to be true:
//   · pagination composing across two pages, every note one unsigned-origin item
//   · the `cursor: ""` terminator, which no per-page test can watch LOOP (098 R12)
//   · a 461 refusal halting resumable — rednote is the first production user of the
//     seam's fatal route, and the first place it ever executes (098 R10)
//   · dedup-skip on a re-sweep, the only thing that makes a scroll-resumable source safe
//
// Pages are the committed captures wherever one exists, and composed from live ROWS where
// a second page is needed: rednote's next `cursor` is literally the LAST row's `note_id`
// (verified in both captures of 2026-09-13), so a composed page threads exactly as the
// real one did.
//
// The fake-scroll + recording-relay shape is duplicated between
// `bulk-twitter-integration.test.js` and `bulk-instagram-integration.test.js` rather than
// living in a shared module; this file follows that same local shape (rednote's scroll
// script needs a scroll COUNT, which neither of those exposes) instead of adding a fourth
// variant of a helper module that does not exist yet.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { createRednoteSource } from "../src/rednote-source.js";
import {
  createNoteDetailWaiter, createNoteExpander, isRednoteChallenge, noteIdOf,
} from "../src/rednote-detail-client.js";
import { parseBoardFeedPage, parseNoteDetail } from "../src/bulk-rednote.js";
import { ORIGIN_HOST } from "../src/extractors/rednote.js";
import { runSweep, OUTCOMES } from "../src/bulk-engine.js";
import { NOTE_DETAIL_REFUSAL_STREAK } from "../src/config.js";

/** The trimmed first page: 3 notes, `has_more: true`, a non-empty cursor. */
const PAGE1 = JSON.parse(readFileSync(new URL("./fixtures/rednote-board.json", import.meta.url)));
/** The full 37-note capture — the row pool every composed page is built from. */
const LIVE = JSON.parse(readFileSync(new URL("./fixtures/rednote-board-live.json", import.meta.url)));
/** The live NOTE capture — nine images — re-addressed per test to the row being expanded. */
const DETAIL = JSON.parse(readFileSync(new URL("./fixtures/rednote-note-detail.json", import.meta.url)));
/** The live VIDEO note capture — one EF4 rung with one backup, and one poster (098 T6b). */
const VIDEO = JSON.parse(readFileSync(new URL("./fixtures/rednote-note-video.json", import.meta.url)));

const HOST = "www.rednote.com";
/** The board id off the live request URL — 24-char hex, NOT digits. */
const BOARD_ID = "69322476000000001202811f";
const SCOPE = `board:${BOARD_ID}`;

/** A board-feed request URL in the PROTOCOL-RELATIVE form the XHR path actually reports —
 * the form `new URL()` rejects unaided, and the one the scope matcher must survive. */
const feedUrl = (cursor = "", boardId = BOARD_ID) =>
  `//webapi.rednote.com/api/sns/web/v1/board/note` +
  `?board_id=${boardId}&num=30&cursor=${cursor}&image_formats=jpg,webp,avif`;

const clone = (value) => structuredClone(value);

/** Live rows that are NOT on page 1, so a composed page 2 is provably new content. */
const PAGE1_IDS = PAGE1.data.notes.map((note) => note.note_id);
/** Page 1's video rows, by id — 2 of its 3 notes. */
const VIDEO_IDS = new Set(PAGE1.data.notes.filter((note) => note.type === "video").map((n) => n.note_id));
const FRESH_ROWS = LIVE.data.notes.filter((note) => !PAGE1_IDS.includes(note.note_id));

/**
 * Compose a board-feed page out of live rows. `cursor` defaults to the last row's
 * `note_id`, which is what rednote itself returns (page 1's own fixture cursor is its
 * last row's id), so the threading in these tests is the real threading.
 */
const feed = (notes, { hasMore = true, cursor } = {}) => ({
  code: 0,
  success: true,
  msg: "成功",   // every genuine response says this; the 461 refusal said "" (098 D1)
  data: {
    has_more: hasMore,
    notes,
    cursor: cursor !== undefined ? cursor : (notes.length ? notes[notes.length - 1].note_id : ""),
  },
});

/** The LIVE last page, verbatim: an empty array and an EMPTY-STRING cursor. Not a
 * refusal — an exhausted feed. */
const lastPage = () => ({ code: 0, success: true, msg: "成功", data: { has_more: false, notes: [], cursor: "" } });

/** The observed HTTP 461 body: a refusal wearing a success shape — `code: 0`,
 * `success: true`, an empty `msg`, and no `data.notes` at all (098 D1). */
const refusal = () => ({ code: 0, success: true, msg: "", data: {} });

/** The sourceIds a page is EXPECTED to yield — derived from the parser, never hardcoded,
 * so these tests still mean something if the mapping rules move. */
const idsOf = (json) => parseBoardFeedPage(json, { host: HOST }).items.map((item) => item.sourceId);

/**
 * A rednote source whose fake `scroll` delivers `pages` — `[json, url]` pairs — one per
 * nudge, exactly as the live hook does when the board fetches its next slice. `state.scrolls`
 * counts the nudges, so a test can prove a page was NEVER requested; pages beyond the
 * script are simply never delivered (a sweep that asks for one it should not have then
 * shows up both as a scroll count and as an item that must not exist).
 */
function boardSource(pages = [], { scope = SCOPE, ...overrides } = {}) {
  const state = { scrolls: 0 };
  let next = 0;
  const source = createRednoteSource({
    host: HOST,
    scope,
    sleep: async () => {},
    maxIdleRounds: 3,
    scroll: () => {
      state.scrolls += 1;
      if (next < pages.length) {
        const [json, url] = pages[next];
        next += 1;
        source.onResponse(json, url);
      }
    },
    ...overrides,
  });
  return { source, state };
}

/** Records the WHOLE item, not just its id — the media-rewrite property is asserted on
 * what the relay would actually POST. */
function recordingRelay() {
  const items = [];
  return {
    items,
    ids: () => items.map((item) => item.sourceId),
    relay: async (item) => { items.push(item); return { outcome: OUTCOMES.ingested }; },
  };
}

const engineOpts = {
  sleep: () => Promise.resolve(), random: () => 0,
  config: { MAX_CONCURRENCY: 1, PACING_MS: 0, PACING_JITTER_MS: 0 },
};

// MARK: - pagination

test("rednote integration: two intercepted pages compose into one ordered, unsigned-origin sweep", async () => {
  // Page 1 is the committed fixture (has_more:true, cursor = its last row's note_id);
  // page 2 is composed from live rows and terminates. The second page's request carries
  // page 1's cursor, which is what the board itself does.
  const page2 = feed(FRESH_ROWS.slice(0, 5), { hasMore: false });
  const { source, state } = boardSource([[page2, feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(PAGE1, feedUrl());   // the replay buffer's first page, as on navigation

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  // The UNION of both pages, in feed order — one item per NOTE (a board row holds exactly
  // one cover; there is no per-image fan-out to be had from this response).
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(page2)]);
  assert.equal(recorder.items.length, PAGE1.data.notes.length + page2.data.notes.length);
  assert.equal(new Set(recorder.ids()).size, recorder.items.length, "every note is a distinct sourceId");
  assert.equal(result.counts.ingested, recorder.items.length);
  assert.equal(state.scrolls, 1, "one scroll fetched page 2; nothing more was asked for");

  for (const item of recorder.items) {
    // D2's whole point: what we FETCH is the unsigned full-resolution original on the
    // plain image node, with the signed, transformed webp kept only as the fallback.
    // Asserting the host (not a literal url) is what makes this a property.
    assert.equal(new URL(item.mediaUrl).hostname, ORIGIN_HOST, `signed url leaked as mediaUrl: ${item.mediaUrl}`);
    assert.ok(!item.mediaUrl.includes("!"), `transform suffix survived into mediaUrl: ${item.mediaUrl}`);
    assert.ok(item.mediaUrlFallback && item.mediaUrlFallback !== item.mediaUrl, "the signed url is kept as fallback");
    assert.notEqual(new URL(item.mediaUrlFallback).hostname, ORIGIN_HOST, "the fallback is the SIGNED url");
    assert.equal(item.provenance.platform, "rednote");
  }
});

// MARK: - termination
//
// Three different terminators, because rednote has three and only one of them is the
// obvious `has_more: false`.

test("rednote integration: has_more:false ends the sweep — the third page is never requested", async () => {
  // A sentinel page is armed behind the terminator. If the sweep asked for it, the
  // sentinel note would ingest — so this fails loudly rather than silently passing.
  const page2 = feed(FRESH_ROWS.slice(0, 4), { hasMore: false });
  const sentinel = feed(FRESH_ROWS.slice(4, 6));
  const { source, state } = boardSource([
    [page2, feedUrl(PAGE1.data.cursor)],
    [sentinel, feedUrl(page2.data.cursor)],
  ]);
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(state.scrolls, 1);
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(page2)]);
  for (const id of idsOf(sentinel)) {
    assert.equal(recorder.ids().includes(id), false, `page 3 was fetched after has_more:false (${id})`);
  }
});

test("rednote integration: the LIVE last page (empty notes, cursor \"\") completes, and is not a refusal", async () => {
  // The genuine terminator, captured verbatim. An empty `notes` ARRAY is an exhausted
  // feed; the challenge detector must not read it as a refusal, or every clean sweep
  // would close "halted" and the checkpoint would never be cleared.
  const { source, state } = boardSource([[lastPage(), feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(result.error, null, "the exhausted feed did not surface as an enumeration error");
  assert.deepEqual(recorder.ids(), idsOf(PAGE1));
  assert.equal(state.scrolls, 1);
});

test("rednote integration: an EMPTY-STRING cursor terminates instead of looping (098 R12)", async () => {
  // The bug Instagram's `next_max_id != null` idiom would import: `""` is not null, so a
  // cursor-presence check written that way reads the terminator as a LIVE cursor and pages
  // forever. Here `has_more` is still true — so `cursor: ""` is the ONLY thing that can end
  // this sweep, and three further pages are armed to be swept up if it does not.
  const page1 = feed(PAGE1.data.notes, { hasMore: true, cursor: "" });
  const wouldLoop = [
    feed(FRESH_ROWS.slice(0, 2), { cursor: "" }),
    feed(FRESH_ROWS.slice(2, 4), { cursor: "" }),
    feed(FRESH_ROWS.slice(4, 6), { cursor: "" }),
  ];
  const { source, state } = boardSource(wouldLoop.map((page) => [page, feedUrl()]));
  source.onResponse(page1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.deepEqual(recorder.ids(), idsOf(page1));
  assert.equal(state.scrolls, 0, "a cursorless page ended the feed — nothing was scrolled for");
  for (const page of wouldLoop) {
    for (const id of idsOf(page)) {
      assert.equal(recorder.ids().includes(id), false, `the sweep kept paging past cursor:"" (${id})`);
    }
  }
});

test("rednote integration: an EMPTY page with has_more:true is not the end — the sweep pages on", async () => {
  // The mirror image of the test above, and the reason `endOfFeed` cannot simply be
  // "no rows": a page can legitimately arrive empty (a deleted-note gap) while the board
  // still has more. Terminating there would truncate the board and record it complete.
  const empty = feed([], { hasMore: true, cursor: "still-going" });
  const page3 = feed(FRESH_ROWS.slice(0, 3), { hasMore: false });
  const { source, state } = boardSource([
    [empty, feedUrl(PAGE1.data.cursor)],
    [page3, feedUrl("still-going")],
  ]);
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(page3)]);
  assert.equal(state.scrolls, 2, "the empty page cost one extra scroll and did not end the sweep");
});

test("rednote integration: scrolling into a wall HALTS resumable under rednote's own stall error", async () => {
  // No terminator ever arrives (a DOM wall / rate-limit). The board must NOT be recorded
  // complete — that would delete the checkpoint and lose everything past the wall.
  const { source, state } = boardSource([]);   // every scroll delivers nothing
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, null, "a self-halt → the controller closes the job paused, not cancelled");
  assert.match(result.error, /rednote board stalled/);
  assert.deepEqual(recorder.ids(), idsOf(PAGE1), "what was already intercepted still ingested");
  assert.equal(state.scrolls, 3, "it gave up after maxIdleRounds, not on the first empty scroll");
});

// MARK: - the 461 refusal (098 R10, the fatal route's first real user)

test("rednote integration: a 461 refusal mid-sweep HALTS resumable — the board is not falsely completed", async () => {
  // Page 1 ingests, then the next request comes back as the risk-control refusal. The
  // parser RETURNS it as `error` (never throws — a throw is swallowed as an unparseable
  // capture), the seam re-raises it on the pull side, and the engine halts.
  const store = new Map();
  const storage = {
    load: async (k) => store.get(k) ?? null,
    save: async (k, v) => { store.set(k, v); },
    remove: async (k) => { store.delete(k); },
  };
  const unreached = feed(FRESH_ROWS.slice(0, 3), { hasMore: false });
  const { source } = boardSource([
    [refusal(), feedUrl(PAGE1.data.cursor)],
    [unreached, feedUrl("never")],
  ]);
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, {
    ...engineOpts, relay: recorder.relay, storage, checkpointKey: "rednote:test",
  });

  assert.equal(result.status, "halted", "a refused board must never close 'complete'");
  assert.match(result.error, /rednote refused the feed/);
  assert.deepEqual(recorder.ids(), idsOf(PAGE1), "what arrived before the refusal is kept");
  for (const id of idsOf(unreached)) {
    assert.equal(recorder.ids().includes(id), false, "the sweep kept requesting after the refusal");
  }
  // Resumable: the checkpoint survives. Its `cursor` is deliberately null — an intercept
  // source declares `resumable: "scroll"` and cannot seek, so persisting one would be a
  // resume token nothing reads back (098 R1). The counts are the part that is used.
  const saved = store.get("rednote:test");
  assert.ok(saved, "checkpoint preserved — the sweep resumes, it is not lost");
  assert.equal(saved.cursor, null);
  assert.equal(saved.counts.ingested, idsOf(PAGE1).length);
});

test("rednote integration: a refusal PRE-EMPTS pages already queued behind it", async () => {
  // The replay buffer hands over page 1 AND the refusal that followed it before the sweep
  // ever pulls. Pinned, not expected: `pendingError` is checked at the TOP of each
  // iteration, so it wins over a non-empty queue and page 1 is never yielded — the
  // opposite of the intuitive reading.
  //
  // It is also the safer half of the trade. Halting on sight loses nothing: the sweep
  // halts RESUMABLE, and a resume re-walks those same pages with dedup-skip making the
  // overlap idempotent. Draining a backlog of ~37 relays against an account rednote has
  // just flagged is not recoverable in the same way — it is the behaviour the risk-control
  // layer is watching for.
  const { source } = boardSource([]);
  source.onResponse(PAGE1, feedUrl());
  source.onResponse(refusal(), feedUrl(PAGE1.data.cursor));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.match(result.error, /rednote refused the feed/);
  assert.deepEqual(recorder.ids(), [], "nothing relayed — the challenge pre-empted the queued page");
  assert.equal(result.counts.ingested, 0);
});

// MARK: - 1A: the sweep must hold the feed's FIRST page, or refuse to run
//
// Measured live 2026-09-14 on a 116-note board: the sweep captured 78 and reported
// `complete`. The board's own responses show four pages — A(38) B(37) C(38) D(3) — and the
// run held B·C·D. 116 − 78 = 38 = page A, exactly. The board had been scrolled before the
// sweep started, so A was fetched in an earlier page session; the feed pages FORWARD only
// and the driver's one lever is a scroll to the bottom, so no amount of scrolling can ask
// for it again. This is the T0/T6a class of defect — a wrong answer that reports success —
// and the fix is to refuse rather than to under-capture quietly.
//
// The cursors below are the ones that board actually returned.
const CURSOR_A = "6a804923000000004d0075a2";   // page A's response → page B's request
const CURSOR_B = "6a650248000000004c01f0c7";
const CURSOR_C = "6a616185000000004d00a318";

test("rednote integration: a sweep that never held the first page is REFUSED, not completed", async () => {
  // The live failure in miniature: the run's first response is a MID-FEED page. Before 1A
  // this swept to `complete`, deleted the checkpoint and reported success — with a whole
  // page of the board never seen and no way for the user to know.
  const pageB = feed(FRESH_ROWS.slice(0, 4));
  const pageC = feed(FRESH_ROWS.slice(4, 8), { hasMore: false });
  const { source, state } = boardSource([[pageC, feedUrl(CURSOR_B)]]);
  source.onResponse(pageB, feedUrl(CURSOR_A));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted", "a board swept from the middle must never close 'complete'");
  assert.equal(result.haltStatus, null, "a self-halt → the controller closes the job paused, not cancelled");
  assert.match(result.error, /RednoteFeedStartError/, "the halt is TYPED, not a bare throw");
  assert.match(result.error, /reload the board page/i, "the halt must tell the user what to DO");
  assert.deepEqual(recorder.ids(), [], "a refused sweep relays nothing — a partial board is not a board");
  assert.equal(state.scrolls, 0, "it refused before spending a single scroll on the wrong start");
});

test("rednote integration: a first page that arrives AFTER enumeration starts is not refused", async () => {
  // The one way this rule could be worse than the bug. The controller posts the replay
  // request and returns immediately; the hook's buffered responses come back on their own
  // `postMessage` tasks and land during the source's FIRST SETTLE — so at the moment
  // `enumerate` is first pulled there is legitimately nothing to judge. A check at
  // construction, or on the first response parsed, would refuse this perfectly good sweep.
  // Here the fake `sleep` IS that settle: nothing exists until it runs.
  let replayed = false;
  const { source, state } = boardSource([], {
    sleep: async () => {
      if (replayed) return;
      replayed = true;
      source.onResponse(PAGE1, feedUrl());                      // the opening slice, late
      source.onResponse(lastPage(), feedUrl(PAGE1.data.cursor));
    },
  });

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete", "a good sweep was refused for not having its replay YET");
  assert.equal(result.error, null);
  assert.deepEqual(recorder.ids(), idsOf(PAGE1));
  assert.equal(state.scrolls, 1, "the settle it waited through is the one the replay arrived in");
});

test("rednote integration: the first page arriving OUT OF ORDER still licenses the sweep", async () => {
  // The buffer replays in fetch order, but nothing in the seam depends on that: the rule
  // asks whether the opening slice ARRIVED, never whether it arrived first. A page A
  // delivered behind a later page must still count, or a reordering would refuse a sweep
  // that holds the whole board.
  const pageB = feed(FRESH_ROWS.slice(0, 3));
  const { source } = boardSource([[lastPage(), feedUrl(pageB.data.cursor)]]);
  source.onResponse(pageB, feedUrl(PAGE1.data.cursor));   // a later page…
  source.onResponse(PAGE1, feedUrl());                    // …then the opening slice

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.deepEqual(recorder.ids(), [...idsOf(pageB), ...idsOf(PAGE1)], "both pages swept, in arrival order");
});

test("rednote integration: the SAME page replayed twice is not a substitute for the first page", async () => {
  // Observed live: two of the run's responses carried the identical cursor `6a616185…`.
  // A rule that counted responses, or took a second sighting as corroboration, would wave
  // this straight through — repetition is not evidence of anything.
  const pageC = feed(FRESH_ROWS.slice(0, 3));
  const { source } = boardSource([]);
  source.onResponse(pageC, feedUrl(CURSOR_C));
  source.onResponse(clone(pageC), feedUrl(CURSOR_C));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.deepEqual(recorder.ids(), []);
});

test("rednote integration: a board small enough to fit on page A sweeps, it does not refuse", async () => {
  // The honest small case: the opening slice is ALSO the last page (`has_more:false`, no
  // second request, no cursor anywhere). The rule asks only whether the run holds the
  // beginning — a feed with exactly one page holds all of it.
  const only = feed(FRESH_ROWS.slice(0, 3), { hasMore: false });
  const { source, state } = boardSource([]);
  source.onResponse(only, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(result.error, null);
  assert.deepEqual(recorder.ids(), idsOf(only));
  assert.equal(state.scrolls, 0, "one page was the whole board — nothing was scrolled for");
});

test("rednote integration: a mid-feed run whose only page is the empty TAIL is refused, not completed", async () => {
  // A board scrolled to the very bottom before the sweep started: the one thing in the
  // buffer is the exhausted tail, fetched with a cursor. It yields NO items at all, so the
  // first-yield check never runs — and without the same rule applied where enumeration
  // ENDS, this closes `complete` having captured none of a 116-note board. The quietest
  // possible version of the bug.
  const { source, state } = boardSource([]);
  source.onResponse(lastPage(), feedUrl(CURSOR_C));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted", "an empty sweep of a full board reported success");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.deepEqual(recorder.ids(), []);
  assert.equal(state.scrolls, 0);
});

test("rednote integration: ANOTHER board's first page cannot license this sweep", async () => {
  // The replay buffer holds pages from a board visited earlier in the same tab, and one of
  // those is that board's opening slice — an empty cursor on the wrong `board_id`. It is
  // evidence about a feed we are not sweeping, so the scope gate that keeps its NOTES out
  // has to keep its licence out too.
  const foreign = feed(FRESH_ROWS.slice(0, 2));
  const ours = feed(FRESH_ROWS.slice(2, 5), { hasMore: false });
  const { source } = boardSource([]);
  source.onResponse(foreign, feedUrl("", "a1b2c3d4e5f600000000000f"));   // another board, page A
  source.onResponse(ours, feedUrl(CURSOR_B));                            // ours, mid-feed

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.deepEqual(recorder.ids(), [], "the wrong board's opening page waved this sweep through");
});

test("rednote integration: a RESUMED sweep is held to the same rule, for the same reason", async () => {
  // `resumable: "scroll"` means no cursor is persisted and a resume RE-WALKS from wherever
  // the page now is — the source cannot even tell it is a resume (`enumerate` ignores the
  // engine's cursor). So the rule fires on a resume too, and it should: a resume that
  // starts at page B reaches exactly the notes a fresh one would, dedup-skips what it
  // already has, and then closes `complete` and clears the checkpoint with page A still
  // never seen. Being a second attempt does not put the top of the feed back in reach.
  const pageB = feed(FRESH_ROWS.slice(0, 3), { hasMore: false });
  const { source } = boardSource([]);
  source.onResponse(pageB, feedUrl(CURSOR_B));

  const recorder = recordingRelay();
  const knownSet = new Set(idsOf(PAGE1));   // a prior run's ingest
  const result = await runSweep(source, { boardId: BOARD_ID }, {
    ...engineOpts, relay: recorder.relay, knownSet,
  });

  assert.equal(result.status, "halted");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.deepEqual(recorder.ids(), []);
  assert.equal(result.counts.skipped, 0, "it refused before walking, so nothing was even skipped");
});

// MARK: - 2A: the sweep RESETS the feed to its start rather than only refusing
//
// 1A's refusal is a guard, not a fix — the user still has to reload by hand. The sweep now
// puts the feed back itself, in page, and 1A's rule becomes the ASSERTION that it worked.
//
// Verified live on 2026-09-14, on a mid-scrolled board, with the hook logging each
// board-feed request url:
//
//     [req] cursor= "6a804923000000002c001f0c"   <- from scrolling
//     [req] cursor= ""                            <- after navigating BACK to the board
//
// The driver that produces that pair (forward to the board's own profile link, then
// browser-back) is `createPageFeedResetter`, tested against a fake page next door. What is
// tested HERE is the part only the real parser, the real seam and the real engine can show:
// WHEN the reset runs, WHAT the sweep does with what it had before it, and — above all —
// that a reset which did not work falls into 1A's refusal rather than around it.

/** An expander-shaped probe: it answers every note with its own cover and records that it
 * ran. Enough to prove WHEN expansion happens relative to the reset, which is all the two
 * tests below ask — and shaped as the real expander's per-note seam, so it cannot pass by
 * being wired to something the source no longer calls. */
function probeExpander(onAttempt) {
  return {
    attemptNote: async (item) => { onAttempt(item); return { settled: true, items: [item] }; },
    retireNote: (item) => ({ settled: true, items: [item] }),
    failNote: (item) => ({ settled: true, items: [item] }),
  };
}

/** A board source whose reset is scripted. `onReset` stands in for the page: whatever it
 * pushes into the source is what the SPA refetched. Returns `false` to model a page that
 * could not be driven at all. `state.resets` counts the attempts. */
function resettableBoard(pages, onReset, { ...overrides } = {}) {
  const state = { resets: 0 };
  const built = boardSource(pages, {
    resetFeed: async () => {
      state.resets += 1;
      return (await onReset(built.source)) !== false;
    },
    // The poll is driven by the injected `sleep`, which these tests make instantaneous; the
    // budgets stay at their real values so nothing here depends on a number.
    ...overrides,
  });
  return { source: built.source, scrollState: built.state, state };
}

test("rednote integration: a mid-scrolled board is RESET to its start and sweeps whole", async () => {
  // The live failure, repaired. The run's replay holds only a mid-feed page — 1A refuses
  // this outright. Here the sweep drives the SPA back to the top, the board refetches with
  // an empty cursor, and the sweep walks the WHOLE feed from page A.
  const pageB = feed(FRESH_ROWS.slice(0, 4));
  const { source, scrollState, state } = resettableBoard(
    [[pageB, feedUrl(PAGE1.data.cursor)], [lastPage(), feedUrl(pageB.data.cursor)]],
    (src) => src.onResponse(PAGE1, feedUrl()),      // the refetch: `cursor=` empty
  );
  source.onResponse(pageB, feedUrl(CURSOR_A));      // all this run had: a page from mid-feed

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete", "the reset worked and the sweep still refused");
  assert.equal(result.error, null);
  assert.equal(state.resets, 1);
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(pageB)],
    "the opening slice is the one page a scroll can never reach — it must be in the sweep");
  assert.equal(scrollState.scrolls, 2, "the board was re-walked from the top, not from where it sat");
});

test("rednote integration: the reset waits for the REFETCH, not for a fixed delay", async () => {
  // The reset is awaited on the real signal — a board-feed request whose cursor is empty —
  // and not on a sleep that hopes the SPA has caught up. Here the refetch lands several
  // polls after the navigation was driven, which is the ordinary case on a live page: the
  // route change, the render and the request are three separate turns. A reset that stopped
  // waiting when the driver returned would refuse this sweep, having actually fixed it.
  const pageB = feed(FRESH_ROWS.slice(0, 4), { hasMore: false });
  let driven = false;
  let polls = 0;
  const board = {};
  Object.assign(board, resettableBoard(
    [[pageB, feedUrl(PAGE1.data.cursor)]],
    () => { driven = true; },                       // the navigation happens…
    {
      sleep: async () => {
        if (!driven) return;
        polls += 1;
        if (polls === 4) board.source.onResponse(PAGE1, feedUrl());   // …the refetch, later
      },
    },
  ));

  const recorder = recordingRelay();
  const result = await runSweep(board.source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.ok(polls >= 4, "the wait gave up before the page had answered");
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(pageB)]);
});

test("rednote integration: a board ALREADY at its start is not navigated at all", async () => {
  // The common case — a board the user just opened — and the one where doing nothing is the
  // feature. An unnecessary route change is real automation footprint against a site running
  // an active risk-control layer (`xhsFingerprintV3`) that has already answered a scripted
  // request with HTTP 461. The opening slice is in hand, so nothing is driven.
  const page2 = feed(FRESH_ROWS.slice(0, 4), { hasMore: false });
  const { source, state } = resettableBoard(
    [[page2, feedUrl(PAGE1.data.cursor)]],
    () => assert.fail("a freshly-loaded board was navigated for nothing"),
  );
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(state.resets, 0);
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(page2)]);
});

test("rednote integration: a board whose ONE page is also its first is swept, never reset", async () => {
  // The smallest honest board: page A is `has_more:false` and there is no second request
  // anywhere. It holds the beginning because it holds all of it.
  const only = feed(FRESH_ROWS.slice(0, 3), { hasMore: false });
  const { source, scrollState, state } = resettableBoard(
    [], () => assert.fail("a one-page board was navigated"),
  );
  source.onResponse(only, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(state.resets, 0);
  assert.equal(scrollState.scrolls, 0);
  assert.deepEqual(recorder.ids(), idsOf(only));
});

test("rednote integration: a reset that produces NO opening slice falls into the refusal", async () => {
  // The SPA restoring the board from its store instead of refetching — which is exactly why
  // 1A's guard stays. The reset is driven, the board answers nothing, and the sweep must
  // halt with 1A's error rather than force itself onward from the middle. A reset that
  // silently failed must never become a sweep that silently under-captures.
  const pageB = feed(FRESH_ROWS.slice(0, 4));
  const { source, scrollState, state } = resettableBoard(
    [[lastPage(), feedUrl(pageB.data.cursor)]],
    () => {},                                        // driven, but nothing comes back
  );
  source.onResponse(pageB, feedUrl(CURSOR_A));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.equal(result.haltStatus, null, "a self-halt → the job closes paused, not cancelled");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.match(result.error, /reload the board page/i, "the user is still told what to DO");
  assert.equal(state.resets, 1);
  assert.deepEqual(recorder.ids(), [], "a sweep from the middle relayed a partial board as a board");
  assert.equal(scrollState.scrolls, 0, "it refused before spending a scroll on the wrong start");
});

test("rednote integration: a page that cannot be driven at all is the same refusal", async () => {
  // No `/user/profile/` anchor — an empty board, or a layout that stopped rendering one.
  // There is no away leg, so there is no reset, and the sweep degrades to the guard rather
  // than improvising a lone `history.back()` from a state nobody verified.
  const pageB = feed(FRESH_ROWS.slice(0, 4));
  const { source, state } = resettableBoard([], () => false);
  source.onResponse(pageB, feedUrl(CURSOR_B));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.equal(state.resets, 1);
  assert.deepEqual(recorder.ids(), []);
});

test("rednote integration: a driver that THROWS is a driver that did not reset", async () => {
  const pageB = feed(FRESH_ROWS.slice(0, 4));
  const { source } = resettableBoard([], () => { throw new Error("detached document"); });
  source.onResponse(pageB, feedUrl(CURSOR_B));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.match(result.error, /RednoteFeedStartError/, "a throw from the page driver escaped as itself");
  assert.deepEqual(recorder.ids(), []);
});

test("rednote integration: what the PREVIOUS page session fetched cannot end the reset sweep", async () => {
  // The subtle one, and the reason the reset holds responses instead of forwarding them.
  // A board scrolled to its very bottom replays the exhausted TAIL (`has_more:false`). Queue
  // that tail ahead of the refetched page A and enumeration ENDS before page A is ever
  // yielded — a `complete` sweep missing the opening slice, which is this whole defect
  // rebuilt out of its own repair. The reset restarts the feed, so what the old session
  // fetched is dropped and the board re-serves all of it from the top.
  const pageC = feed(FRESH_ROWS.slice(0, 4));
  const { source } = resettableBoard(
    [[lastPage(), feedUrl(PAGE1.data.cursor)]],
    (src) => src.onResponse(PAGE1, feedUrl()),
  );
  source.onResponse(pageC, feedUrl(CURSOR_B));      // mid-feed…
  source.onResponse(lastPage(), feedUrl(CURSOR_C)); // …and the end of the old session

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  for (const id of idsOf(PAGE1)) {
    assert.ok(recorder.ids().includes(id), `the opening slice was cut off by a stale end-of-feed (${id})`);
  }
});

test("rednote integration: ANOTHER board's opening slice does not satisfy the reset either", async () => {
  // 1A scopes its evidence; the wait for the reset's refetch is the same evidence and is
  // scoped the same way. A page A for a board visited earlier in the tab proves nothing
  // about this feed, whether it arrives before the reset or during it.
  const pageB = feed(FRESH_ROWS.slice(0, 3));
  const { source } = resettableBoard(
    [],
    (src) => src.onResponse(feed(FRESH_ROWS.slice(3, 5)), feedUrl("", "a1b2c3d4e5f600000000000f")),
  );
  source.onResponse(pageB, feedUrl(CURSOR_B));

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.deepEqual(recorder.ids(), []);
});

test("rednote integration: the reset runs ONCE per source, however often it is pulled", async () => {
  // A resumed sweep, a retried start, two enumerations of one source. Driving the page a
  // second time buys nothing (the feed is already at its start) and costs another route
  // change against a site that fingerprints browsing.
  //
  // The two pulls are CONCURRENT and the reset is held open until both have started, which
  // is the only shape that tests anything: a sequential second pull is already covered by
  // the opening slice having arrived, so it would pass with the whole attempt un-memoised.
  // Here the second pull reaches the decision while the first is still mid-navigation.
  const pageB = feed(FRESH_ROWS.slice(0, 4));
  let release = () => {};
  const gate = new Promise((resolve) => { release = resolve; });
  const { source, state } = resettableBoard(
    [[pageB, feedUrl(PAGE1.data.cursor)], [lastPage(), feedUrl(pageB.data.cursor)]],
    async (src) => { await gate; src.onResponse(PAGE1, feedUrl()); },
  );
  source.onResponse(pageB, feedUrl(CURSOR_A));

  const first = source.enumerate();
  const second = source.enumerate();
  const pulls = [first.next(), second.next()];
  release();
  const [a, b] = await Promise.all(pulls);

  assert.equal(a.done, false);
  assert.equal(b.done, false, "the second pull was refused for the first pull's success");
  assert.equal(state.resets, 1, "two pulls drove the page twice");

  await first.return();
  await second.return();
  // …and a pull that starts long afterwards drives nothing either.
  const third = source.enumerate();
  await third.next();
  await third.return();
  assert.equal(state.resets, 1);
});

// The wasted-work window 1A's report leaves open: with note-opening on, its refusal fires
// only after the first queued page has been EXPANDED — up to a page of note-opens spent on a
// sweep that was always going to halt. The reset runs before anything is pulled from the
// seam, so expansion cannot precede it; and because the refusal is reached the moment the
// reset is known to have failed, nothing is expanded on that path either.

test("rednote integration: the reset happens BEFORE the first note is opened", async () => {
  const pageB = feed(FRESH_ROWS.slice(0, 4), { hasMore: false });
  const order = [];
  const { source } = resettableBoard(
    [[pageB, feedUrl(PAGE1.data.cursor)]],
    (src) => { order.push("reset"); src.onResponse(PAGE1, feedUrl()); },
    { expander: probeExpander(() => order.push("expand")) },
  );
  source.onResponse(pageB, feedUrl(CURSOR_A));

  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recordingRelay().relay });

  assert.equal(result.status, "complete");
  assert.equal(order[0], "reset", "a page of notes was opened before the feed was put back");
  assert.ok(order.includes("expand"), "the expansion never ran — this test would pass with it deleted");
});

test("rednote integration: a refused sweep opens NO notes at all", async () => {
  // The window, closed. Expansion is the expensive half — one paced SPA note-open per note
  // against the one site known to refuse a scripted request — and every one of them spent
  // here would be spent on a sweep that halts without relaying anything.
  const pageB = feed(FRESH_ROWS.slice(0, 4));
  const order = [];
  const { source } = resettableBoard(
    [[lastPage(), feedUrl(pageB.data.cursor)]],
    () => { order.push("reset"); },                  // driven, and the board does not answer
    { expander: probeExpander(() => order.push("expand")) },
  );
  source.onResponse(pageB, feedUrl(CURSOR_A));

  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recordingRelay().relay });

  assert.equal(result.status, "halted");
  assert.match(result.error, /RednoteFeedStartError/);
  assert.deepEqual(order, ["reset"], "note-opens were spent on a sweep that was always going to halt");
});

// MARK: - dedup (what makes a scroll-driven resume safe)

test("rednote integration: a re-sweep SKIPS the notes it already has instead of re-ingesting", async () => {
  // Resume cannot seek (098 D1), so a resumed sweep re-walks from the top of the board.
  // Dedup-skip is the entire reason that is not a re-ingest of everything already saved.
  const page2 = feed(FRESH_ROWS.slice(0, 5), { hasMore: false });
  const { source } = boardSource([[page2, feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(PAGE1, feedUrl());

  const knownSet = new Set(idsOf(PAGE1));   // the first page, ingested by a prior run
  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay, knownSet });

  assert.equal(result.status, "complete");
  assert.equal(result.counts.skipped, idsOf(PAGE1).length);
  assert.equal(result.counts.ingested, idsOf(page2).length);
  // A skip costs NO relay at all — not a relay that answers "deduped".
  assert.deepEqual(recorder.ids(), idsOf(page2));
  for (const id of idsOf(PAGE1)) {
    assert.equal(recorder.ids().includes(id), false, `already-known note ${id} was re-relayed`);
  }
});

test("rednote integration: a note repeated across two pages is relayed once, skipped the second time", async () => {
  // Boards shift under a paging sweep (a note saved mid-sweep slides a row onto the next
  // page), so the same `note_id` can legitimately arrive twice. The engine grows its
  // known-set as it ingests, so the repeat costs a skip, not a duplicate ingest.
  const repeated = PAGE1.data.notes[0];
  const page2 = feed([clone(repeated), ...FRESH_ROWS.slice(0, 2)], { hasMore: false });
  const { source } = boardSource([[page2, feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  const relayedTimes = recorder.ids().filter((id) => id === repeated.note_id).length;
  assert.equal(relayedTimes, 1, "the repeated note was relayed exactly once");
  assert.equal(result.counts.skipped, 1);
  assert.equal(result.counts.ingested, PAGE1.data.notes.length + 2);
  assert.equal(new Set(recorder.ids()).size, recorder.ids().length);
});

// MARK: - rows and responses that must not reach the relay

test("rednote integration: a row with no usable cover is dropped, not enqueued as a doomed item", async () => {
  // `cover.url` is `""` on 37/37 live rows, so "no usable image" means every candidate
  // field is empty — and such a row must be dropped at the parser rather than relayed to
  // fail at fetch time. The rest of its page is unaffected.
  const coverless = clone(FRESH_ROWS[0]);
  coverless.cover = { file_id: "", url: "", url_pre: "", url_default: "", info_list: [], width: 0, height: 0 };
  const page2 = feed([coverless, ...FRESH_ROWS.slice(1, 3)], { hasMore: false });
  const { source } = boardSource([[page2, feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(recorder.ids().includes(coverless.note_id), false, "a coverless row reached the relay");
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(page2)]);
  assert.equal(recorder.items.length, PAGE1.data.notes.length + 2, "only the two usable rows of page 2");
  assert.equal(result.counts.permanentFailed, 0);
});

test("rednote integration: another board's replayed page is ignored — this sweep stays in scope", async () => {
  // The hook's replay buffer can hold pages from a board visited earlier in the same tab
  // (the X 075/076 contamination, on rednote's hook). Scope is read off the request URL's
  // `board_id`, in its protocol-relative form.
  const foreign = feed(FRESH_ROWS.slice(0, 4), { hasMore: false });
  const ours = feed(FRESH_ROWS.slice(4, 6), { hasMore: false });
  const { source } = boardSource([[ours, feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(foreign, feedUrl("", "a1b2c3d4e5f600000000000f"));   // a DIFFERENT board
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(ours)]);
  for (const id of idsOf(foreign)) {
    assert.equal(recorder.ids().includes(id), false, `another board's note ${id} leaked into this sweep`);
  }
});

test("rednote integration: another board's REFUSAL cannot halt this sweep", async () => {
  // The same scope gate on the fatal route: a replayed refusal from a board we are not
  // sweeping must not arm `pendingError`, or a stale buffer entry would halt every
  // subsequent sweep in the tab.
  const page2 = feed(FRESH_ROWS.slice(0, 3), { hasMore: false });
  const { source } = boardSource([[page2, feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(refusal(), feedUrl("", "a1b2c3d4e5f600000000000f"));
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(result.error, null);
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(page2)]);
});

// MARK: - the whole capture, end to end

test("rednote integration: the full 37-note capture sweeps to completion, one item per note", async () => {
  // The canary fixture driven through the real seam: 37 rows, 81 % of them video (a video
  // note's cover is a poster still, which is all K3a can capture), then the live
  // terminator. Every row must become exactly one item with a fetchable original.
  const { source, state } = boardSource([[lastPage(), feedUrl(LIVE.data.cursor)]]);
  source.onResponse(LIVE, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(recorder.items.length, LIVE.data.notes.length, "one item per note, no row dropped");
  assert.deepEqual(recorder.ids(), LIVE.data.notes.map((note) => note.note_id));
  assert.equal(state.scrolls, 1);
  assert.ok(
    recorder.items.some((item) => item.provenance.rawMetadata.kind === "video"),
    "the video-heavy mix survived the sweep",
  );
  for (const item of recorder.items) {
    assert.equal(new URL(item.mediaUrl).hostname, ORIGIN_HOST);
    assert.ok(item.xsecToken, "the per-note token rides as a LOCAL field for K3b");
    assert.equal("xsecToken" in item.provenance, false, "a short-lived credential never enters provenance");
    assert.equal(JSON.stringify(item.provenance).includes(item.xsecToken), false, "no token leaked into provenance");
  }
});

// MARK: - K3b: note-open expansion, composed (098 T5b)
//
// The cover pass above is the unexpanded path and stays exactly as it was. These drive the
// OTHER mode through the same real parser, real seam and real engine, with only the page
// itself faked — `openNote` stands in for the click and delivers the note's own response,
// which is precisely what the SPA does.

/** The live note body, re-addressed to `noteId`. Only the id moves. */
const detailFor = (noteId) => {
  const body = clone(DETAIL);
  body.data.items[0].note_card.note_id = noteId;
  return body;
};

/** The detail refusal — the same 461 shape as the board feed's, on the note-detail
 * envelope (`data.items` is what is missing here). */
const detailRefusal = () => ({ code: 0, success: true, msg: "", data: {} });

/** The sourceIds one note's expansion is EXPECTED to yield, derived from the parser. */
const imageIdsOf = (noteId) =>
  parseNoteDetail(detailFor(noteId), { host: HOST }).items.map((item) => item.sourceId);

/**
 * A rednote source with expansion ON: `pages` drive the board scroll exactly as above, and
 * `answer(noteId)` decides what the page returns when that note is opened (a body, or null
 * for a note that never answers).
 *
 * `mounted` is the VIRTUALISED grid (098 2A): the set of note ids whose card is in the DOM
 * right now. By default every card is mounted, which is the pre-2A world these tests were
 * written in and keeps them asking what they were written to ask. A test that wants the
 * real board passes a `mounted` that changes as `scrollStep` walks down the page.
 */
function expandingSource(pages = [], {
  answer = (noteId) => detailFor(noteId), armed = null, mounted = null, scrollStep = null,
  maxReachRounds, reachSettleMs = 0, onExpandFailure = null, onOpen = null, onScroll = null,
  ...overrides
} = {}) {
  const state = { scrolls: 0, steps: 0, opened: [], closed: 0, sleeps: 0 };
  const waiter = createNoteDetailWaiter();
  const expander = createNoteExpander({
    waiter,
    host: HOST,
    random: () => 0,
    // A fake `sleep` that always resolves turns an UNBOUNDED wait for a note's response
    // into a HANG rather than a failure, and a hanging suite reports nothing at all.
    sleep: async () => { if ((state.sleeps += 1) > 200) throw new Error("the note-open wait never gave up"); },
    pacingMs: 0,
    pacingJitterMs: 0,
    timeoutMs: 0,
    canOpen: mounted ? (item) => mounted().includes(noteIdOf(item)) : null,
    openNote: async (item) => {
      const noteId = noteIdOf(item);
      if (mounted && !mounted().includes(noteId)) return false;
      state.opened.push(noteId);
      if (onOpen) onOpen(noteId);
      const body = answer(noteId);
      if (body) waiter.onDetail(body, `https://webapi.rednote.com/api/sns/web/v1/feed`);
      return true;
    },
    closeNote: async () => { state.closed += 1; },
    ...overrides,
  });
  if (armed) expander.arm({ knownSet: armed, armed: true });

  let next = 0;
  const source = createRednoteSource({
    host: HOST,
    scope: SCOPE,
    sleep: async () => {},
    maxIdleRounds: 3,
    scroll: () => {
      state.scrolls += 1;
      if (onScroll) onScroll();
      if (next < pages.length) {
        const [json, url] = pages[next];
        next += 1;
        source.onResponse(json, url);
      }
    },
    expander,
    scrollStep: scrollStep ? () => { state.steps += 1; return scrollStep(state.steps); } : null,
    maxReachRounds,
    reachSettleMs,
    onExpandFailure,
    isFatalExpandFailure: isRednoteChallenge,
  });
  return { source, expander, state };
}

test("rednote expansion: a note's cover is replaced by its images, and a video note keeps its cover", async () => {
  // The whole of K3b in one sweep. Page 1 of the committed fixture is 2 video rows and 1
  // image row; only the image row is opened, and it fans out to its nine images.
  const { source, expander, state } = expandingSource([[lastPage(), feedUrl(PAGE1.data.cursor)]]);
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  const imageRows = PAGE1.data.notes.filter((note) => note.type !== "video");
  const videoRows = PAGE1.data.notes.filter((note) => note.type === "video");
  assert.equal(result.status, "complete");
  assert.deepEqual(state.opened, imageRows.map((note) => note.note_id), "only the image notes were opened");
  assert.equal(state.closed, state.opened.length, "every opened note was closed — the board must keep scrolling");

  // Feed order preserved, with each image row's single cover swapped for its images.
  const expected = PAGE1.data.notes.flatMap((note) =>
    (note.type === "video" ? [note.note_id] : imageIdsOf(note.note_id)));
  assert.deepEqual(recorder.ids(), expected);
  for (const id of videoRows.map((n) => n.note_id)) {
    assert.equal(recorder.ids().includes(id), true, `the video note lost its cover (${id})`);
  }
  // Every expanded item is keyed `<note_id>:<index>` — a namespace of its own, which is
  // what keeps a cover and its images from colliding.
  const expanded = recorder.ids().filter((id) => id.includes(":"));
  assert.equal(expanded.length, imageRows.length * imageIdsOf(imageRows[0].note_id).length);

  const stats = expander.stats();
  assert.equal(stats.expanded, imageRows.length);
  assert.equal(stats.refused, videoRows.length);
  assert.equal(stats.partial, false);
});

/** The live VIDEO detail body, re-addressed to `noteId`. */
function videoDetailFor(noteId) {
  const body = clone(VIDEO);
  body.data.items[0].note_card.note_id = noteId;
  return body;
}

test("rednote K4: with the video toggle on, a video note relays its cover AND its stream", async () => {
  // T6c end to end: board page → expander → engine → relay. Page 1 of the committed fixture
  // is 2 video rows and 1 image row, so this exercises both fan-outs in one sweep and pins
  // the thing that must never happen — the poster arriving twice.
  const { source, expander, state } = expandingSource(
    [[lastPage(), feedUrl(PAGE1.data.cursor)]],
    {
      resolveVideo: true,
      answer: (noteId) => (VIDEO_IDS.has(noteId) ? videoDetailFor(noteId) : detailFor(noteId)),
    });
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  // EVERY note is opened now, not just the image ones — which is exactly the escalation the
  // popup's risk gate re-renders for when the video box is ticked.
  assert.deepEqual(state.opened.sort(), PAGE1.data.notes.map((n) => n.note_id).sort());
  assert.equal(state.closed, state.opened.length, "every opened note was closed");

  const expected = PAGE1.data.notes.flatMap((note) =>
    (note.type === "video" ? [note.note_id, `${note.note_id}:v`] : imageIdsOf(note.note_id)));
  assert.deepEqual(recorder.ids(), expected);

  // The duplicate 098 T5a refused video notes to avoid: one picture, two keys. Every id is
  // relayed once, and no video note ever produces an image-indexed child.
  assert.equal(new Set(recorder.ids()).size, recorder.ids().length, "an id was relayed twice");
  for (const id of VIDEO_IDS) {
    assert.equal(recorder.ids().includes(`${id}:0`), false, `the poster was fanned out for ${id}`);
  }

  const stats = expander.stats();
  assert.equal(stats.expanded, PAGE1.data.notes.length);
  assert.equal(stats.streams, VIDEO_IDS.size);
  assert.equal(stats.refused, 0, "a video note is no longer refused when the toggle asks for its stream");
  assert.equal(stats.partial, false);
});

test("rednote K4: with the video toggle OFF, a video note is untouched by T6c", async () => {
  // The composition claim: `expandNotes` alone is exactly the sweep T5b shipped. Asserted
  // beside the test above so the two modes are compared rather than described.
  const { source, expander, state } = expandingSource(
    [[lastPage(), feedUrl(PAGE1.data.cursor)]],
    { answer: (noteId) => (VIDEO_IDS.has(noteId) ? videoDetailFor(noteId) : detailFor(noteId)) });
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.deepEqual(state.opened, PAGE1.data.notes.filter((n) => n.type !== "video").map((n) => n.note_id),
    "a video note costs no note-open when its stream was not asked for");
  assert.equal(recorder.ids().some((id) => id.endsWith(":v")), false);
  assert.equal(expander.stats().refused, VIDEO_IDS.size);
});

test("rednote expansion: a RUN of refused note-opens halts the sweep resumable, like a refused board page", async () => {
  // The asymmetry that matters (098 R7 / 485): `expandItems` degrades on a throw, which is
  // right for a note that would not open and wrong for a session rednote has flagged —
  // degrading past one of those keeps opening notes against an account already turned away.
  //
  // Changelog 500 put a RUN between the first refusal and the halt, because a refusal on
  // one note is also what a dead `xsec_token` may look like (020) and no live run has yet
  // shown which. Everything below the run is absorbed; the run itself still halts, still
  // resumable, still leaving the board scrollable.
  const store = new Map();
  const storage = {
    load: async (k) => store.get(k) ?? null,
    save: async (k, v) => { store.set(k, v); },
    remove: async (k) => { store.delete(k); },
  };
  const rows = imageRows(NOTE_DETAIL_REFUSAL_STREAK + 2, "refused");
  const page = feed(rows, { hasMore: false });
  const { source, state } = expandingSource([], { answer: () => detailRefusal() });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, {
    ...engineOpts, relay: recorder.relay, storage, checkpointKey: "rednote:test",
  });

  assert.equal(result.status, "halted", "an unbroken run of refusals degraded instead of halting");
  assert.match(result.error, /rednote refused the last/);
  assert.equal(state.opened.length, NOTE_DETAIL_REFUSAL_STREAK,
    "the pass stopped short of the run, or kept opening notes past it");
  assert.equal(state.closed, NOTE_DETAIL_REFUSAL_STREAK, "a note was left open over the board");

  // WHAT CHANGED WITH STREAMING, pinned deliberately (changelog 497). Before 2A a whole
  // page was expanded and then yielded, so a refusal partway through discarded the notes
  // ahead of it and this asserted NOTHING was relayed. A streaming pass has already
  // relayed them — which is the same trade the board feed's own fatal route makes one
  // level up ("what arrived before the refusal is kept"), and the safety property is
  // untouched: what must never happen is a relay AFTER the halt. So the notes the run
  // absorbed are relayed at cover fidelity, and nothing from the halt onward is.
  const absorbed = rows.slice(0, NOTE_DETAIL_REFUSAL_STREAK - 1).map((row) => row.note_id);
  assert.deepEqual(recorder.ids(), absorbed, "a note settled after the halt was still relayed");
  for (const row of rows.slice(NOTE_DETAIL_REFUSAL_STREAK - 1)) {
    assert.equal(recorder.ids().includes(row.note_id), false,
      `the halt did not stop the pass — ${row.note_id} was relayed anyway`);
  }
});

test("rednote expansion: ONE refused note-open degrades that note and the board sweeps on", async () => {
  // 020's `xsec_token` hazard, end to end through the real seam, the real ledger and the
  // real engine. A short-lived per-note credential dying is not the same event as a flagged
  // account, and the pre-500 code could not tell them apart because it halted on the first
  // refusal either way — one stale token ended a whole board. Now the note keeps the cover
  // the board pass already captured, every other note expands, and the sweep COMPLETES and
  // says it fell short.
  const rows = imageRows(4, "mixed");
  const page = feed(rows, { hasMore: false });
  const { source, expander, state } = expandingSource([], {
    answer: (noteId) => (noteId === rows[1].note_id ? detailRefusal() : detailFor(noteId)),
  });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete", "one dead credential ended the whole sweep");
  assert.equal(state.opened.length, rows.length, "the pass stopped opening notes after the refusal");
  // The cover-or-children rule, through the new arm: the refused note contributes exactly
  // its cover, every other note exactly its children, and nothing contributes both.
  assert.deepEqual(recorder.ids(), rows.flatMap((row) =>
    (row.note_id === rows[1].note_id ? [row.note_id] : imageIdsOf(row.note_id))));

  const stats = expander.stats();
  assert.equal(stats.detailRefused, 1);
  assert.equal(stats.expanded, rows.length - 1);
  assert.equal(stats.degraded, 0, "a refusal was filed as a note that would not answer");
  assert.equal(stats.partial, true, "a sweep that captured less than it meant to must say so");
});

test("rednote expansion: a note that never answers keeps its cover and the sweep still completes", async () => {
  const { source, expander } = expandingSource([[lastPage(), feedUrl(PAGE1.data.cursor)]], { answer: () => null });
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.deepEqual(recorder.ids(), idsOf(PAGE1), "every note fell back to exactly the cover pass's item");
  const stats = expander.stats();
  assert.equal(stats.degraded, PAGE1.data.notes.filter((n) => n.type !== "video").length);
  assert.equal(stats.partial, true, "a sweep that captured less than it meant to must say so");
});

test("rednote expansion: an exhausted budget finishes the cover pass instead of halting", async () => {
  // R13's rule. The notes past the ceiling are still swept, still relayed, still saved — at
  // cover fidelity — and the sweep reports PARTIAL rather than pretending it expanded them.
  const imageRows = LIVE.data.notes.filter((note) => note.type !== "video");
  assert.ok(imageRows.length >= 3, "the live capture must have several image notes for this to bound anything");
  const page = feed(imageRows, { hasMore: false });
  const { source, expander, state } = expandingSource([[page, feedUrl()]], { budget: 1 });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete", "the budget is a ceiling on note-opens, not a halt");
  assert.equal(state.opened.length, 1);
  const expected = imageRows.flatMap((note, index) =>
    (index === 0 ? imageIdsOf(note.note_id) : [note.note_id]));
  assert.deepEqual(recorder.ids(), expected, "every note past the budget still ingested its cover");
  const stats = expander.stats();
  assert.equal(stats.budgetExhausted, true);
  assert.equal(stats.partial, true);
});

test("rednote expansion: a re-sweep with the pre-check armed opens nothing and ingests nothing (098 R14)", async () => {
  // The waste R14 exists to cure: without the pre-check this re-sweep re-opens every note,
  // yields every image, and the engine dedup-skips all of them — full cost, zero result.
  const imageRows = PAGE1.data.notes.filter((note) => note.type !== "video");
  const known = new Set([
    ...PAGE1.data.notes.filter((n) => n.type === "video").map((n) => n.note_id),   // video covers
    ...imageRows.flatMap((note) => imageIdsOf(note.note_id)),                      // expanded images
  ]);
  const { source, expander, state } = expandingSource(
    [[lastPage(), feedUrl(PAGE1.data.cursor)]], { armed: known });
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, {
    ...engineOpts, relay: recorder.relay, knownSet: known,
  });

  assert.equal(result.status, "complete");
  assert.deepEqual(state.opened, [], "a note whose images are already ingested was re-opened");
  assert.deepEqual(recorder.ids(), [], "nothing was relayed");
  assert.equal(result.counts.ingested, 0);
  assert.equal(expander.stats().skippedKnown, imageRows.length);
  // The video covers are known too, so they are SKIPPED by the engine rather than dropped
  // by the expander — the two mechanisms compose without either double-counting.
  assert.equal(result.counts.skipped, PAGE1.data.notes.length - imageRows.length);
});

test("rednote expansion: an armed re-sweep still opens a note that only ever gave up a cover", async () => {
  // The mode trap, end to end. A note the LAST sweep degraded (or never reached) is known
  // as `<note_id>` and owes its images; if the pre-check counted that, the toggle would be
  // permanently inert on any board that was ever swept cover-only.
  const imageRows = PAGE1.data.notes.filter((note) => note.type !== "video");
  const known = new Set(PAGE1.data.notes.map((note) => note.note_id));   // a cover-only sweep
  const { source, expander, state } = expandingSource(
    [[lastPage(), feedUrl(PAGE1.data.cursor)]], { armed: known });
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, {
    ...engineOpts, relay: recorder.relay, knownSet: known,
  });

  assert.equal(result.status, "complete");
  assert.deepEqual(state.opened, imageRows.map((note) => note.note_id));
  assert.deepEqual(recorder.ids(), imageRows.flatMap((note) => imageIdsOf(note.note_id)));
  assert.equal(expander.stats().skippedKnown, 0);
  assert.ok(result.counts.ingested > 0, "the expansion toggle silently did nothing on an already-swept board");
});

// MARK: - 2A + 3B: expansion rides the scroll (changelog 497)
//
// Two defects with one cause, both measured on a live 116-note board.
//
// 2A. The grid is VIRTUALISED — 13 mounted note cards against a feed page of 37-38 — and a
// note can only be opened by clicking a card that exists. Expansion used to run over a whole
// page AFTER it arrived, by which time the grid had scrolled on, so 103 of 116 notes
// reported "no card on the page" and kept their covers.
//
// 3B. Nothing was yielded until the whole page had been expanded, which at ~2.4 s of pacing
// plus up to 8 s of waiting per note is two to five minutes before anything saves.
//
// The pass now works a page's notes in feed order, opens the ones whose cards are mounted,
// yields each note the moment it is answered, steps the viewport down and asks the rest
// again — conceding a note to its cover only once it has walked the whole page.
//
// Everything below drives the REAL parser, the REAL seam, the REAL expander and the REAL
// engine; only the page is faked, and it is faked as a virtualised grid rather than as a
// document where every card is always there, because the second is the world in which this
// defect did not exist.

/** Image rows from the live capture, re-addressed so a test can have as many as it needs. */
const LIVE_IMAGE_ROWS = LIVE.data.notes.filter((note) => note.type !== "video");
const imageRows = (count, prefix = "note") => Array.from({ length: count }, (_, index) => {
  const row = clone(LIVE_IMAGE_ROWS[index % LIVE_IMAGE_ROWS.length]);
  row.note_id = `${prefix}-${index}`;
  return row;
});

/**
 * A VIRTUALISED grid, modelled on the live measurement: `band` cards are in the DOM at a
 * time and the rest are not rendered at all. `step()` slides the band down and reports
 * whether it moved — false means the viewport is at the foot of the document, which is the
 * pass's evidence that it has now been past every card of this page. A new page puts the
 * band back at the head, which is where the viewport sits when the board appends one.
 */
function virtualGrid(pagesOfIds, { band = 3 } = {}) {
  let pageIndex = 0;
  let top = 0;
  const current = () => pagesOfIds[Math.min(pageIndex, pagesOfIds.length - 1)] || [];
  return {
    mounted: () => current().slice(top, top + band),
    step: () => {
      if (top + band >= current().length) return false;
      top += band;
      return true;
    },
    nextPage: () => { pageIndex += 1; top = 0; },
  };
}

test("rednote 2A: a virtualised board expands EVERY note — the pass walks down to the cards", async () => {
  // Nine notes, three cards mounted at a time: the shape of the live board, in miniature.
  // Before this the pass met all nine at once, found three, and wrote off the other six.
  const rows = imageRows(9);
  const page = feed(rows, { hasMore: false });
  const grid = virtualGrid([rows.map((row) => row.note_id)], { band: 3 });
  const { source, expander, state } = expandingSource([], {
    mounted: grid.mounted, scrollStep: () => grid.step(),
  });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.deepEqual(recorder.ids(), rows.flatMap((row) => imageIdsOf(row.note_id)),
    "the board did not expand whole, or it expanded out of feed order");
  assert.deepEqual(state.opened, rows.map((row) => row.note_id), "every note was opened, once, in order");
  const stats = expander.stats();
  assert.equal(stats.expanded, rows.length);
  assert.equal(stats.attempted, rows.length, "one note asked over several rounds is still one note");
  assert.equal(stats.unreachable, 0, "a note the walk reached was still reported as having no card");
  assert.equal(stats.partial, false, "a board that expanded whole reported a shortfall");
  assert.ok(state.steps > 0, "the walk never stepped — this passed without the thing it tests");
});

test("rednote 2A: without the walk, only the mounted band is reached — and the rest keep covers, once", async () => {
  // The control, and the defect itself. The same board with no way to walk down to the
  // cards reaches exactly the band that happened to be mounted; the notes it never reached
  // fall back to the cover the board pass captured — exactly one item each, never a cover
  // AND children — and the sweep says so rather than reporting a clean expansion.
  const rows = imageRows(9);
  const page = feed(rows, { hasMore: false });
  const grid = virtualGrid([rows.map((row) => row.note_id)], { band: 3 });
  const { source, expander, state } = expandingSource([], { mounted: grid.mounted });   // no scrollStep
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete", "the feed ending with notes still pending was not a clean finish");
  const reached = rows.slice(0, 3);
  const missed = rows.slice(3);
  assert.deepEqual(recorder.ids(), [
    ...reached.flatMap((row) => imageIdsOf(row.note_id)),
    ...missed.map((row) => row.note_id),
  ], "the notes the pass never reached did not fall back to exactly their covers");
  assert.deepEqual(state.opened, reached.map((row) => row.note_id));
  assert.equal(new Set(recorder.ids()).size, recorder.ids().length, "something was relayed twice");
  const stats = expander.stats();
  assert.equal(stats.expanded, reached.length);
  assert.equal(stats.unreachable, missed.length, "the shortfall is the notes with no card, and it is named");
  assert.equal(stats.reasons.no_note_card, missed.length, "a miss was counted per ROUND rather than per note");
  assert.equal(stats.partial, true);
});

test("rednote 3B: the first note SAVES before the last one is opened", async () => {
  // The block this removes. Before, a page's items were yielded only after `expandItems`
  // had returned, so a 37-note page opened every note — minutes of paced SPA clicks — before
  // a single item reached the app, and a sweep interrupted in that window saved nothing at
  // all. Now each note is yielded as it is answered, which is visible as INTERLEAVING:
  // relays appear among the opens rather than all behind them.
  const rows = imageRows(4);
  const page = feed(rows, { hasMore: false });
  const order = [];
  const { source } = expandingSource([], { onOpen: (noteId) => order.push(`open:${noteId}`) });
  source.onResponse(page, feedUrl());

  const result = await runSweep(source, { boardId: BOARD_ID }, {
    ...engineOpts,
    relay: async (item) => { order.push(`relay:${item.sourceId}`); return { outcome: OUTCOMES.ingested }; },
  });

  assert.equal(result.status, "complete");
  const firstRelay = order.findIndex((event) => event.startsWith("relay:"));
  assert.ok(firstRelay >= 0, "nothing was relayed at all");
  assert.ok(order.indexOf(`open:${rows[1].note_id}`) > firstRelay,
    "the whole page was expanded before anything saved — 3B, unchanged");
  assert.ok(order.slice(firstRelay).some((event) => event.startsWith("open:")),
    "no note was opened after the first save, so nothing was actually interleaved");
  // …and the first thing saved is the FIRST note's first image, not something out of order.
  assert.equal(order[firstRelay], `relay:${imageIdsOf(rows[0].note_id)[0]}`);
});

test("rednote 2A: a note whose card never mounts anywhere keeps its cover exactly once", async () => {
  // The honest miss: a short board, or a card the SPA renders in a shape `findLink` cannot
  // see. The walk runs its full course and the note is conceded — one cover, one
  // `unreachable`, one `no_note_card`, however many times the pass asked about it.
  const rows = imageRows(4);
  const ghost = rows[2].note_id;
  const page = feed(rows, { hasMore: false });
  const grid = virtualGrid([rows.map((row) => row.note_id)], { band: 2 });
  const { source, expander, state } = expandingSource([], {
    mounted: () => grid.mounted().filter((id) => id !== ghost),
    scrollStep: () => grid.step(),
  });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(recorder.ids().filter((id) => id === ghost).length, 1, "the missing note's cover was not relayed once");
  assert.equal(recorder.ids().some((id) => id.startsWith(`${ghost}:`)), false,
    "a note that was never opened produced children");
  assert.equal(state.opened.includes(ghost), false);
  const stats = expander.stats();
  assert.equal(stats.unreachable, 1);
  assert.equal(stats.reasons.no_note_card, 1, "the miss was counted once per ASK instead of once per note");
  assert.equal(stats.expanded, rows.length - 1, "one unreachable note cost the rest of the page");
});

test("rednote 2A: a note repeated on the NEXT page never gets a cover on top of its images", async () => {
  // THE trap, and the reason the expander keeps a ledger. Boards shift under a paging sweep
  // and re-serve a row (observed live). Expanded on page 1 and then met again on page 2 with
  // its card long gone, the note would be CONCEDED — emitting `<note_id>` beside the
  // `<note_id>:0…:8` it had already produced. That is one picture ingested under two keys,
  // with a dedup-skip that cannot see the duplicate: exactly what T5a refused video notes
  // over and what T6c chose `<note_id>:v` to avoid.
  const first = imageRows(2, "a");
  const repeat = clone(first[0]);
  const second = [repeat, ...imageRows(1, "b")];
  const page1 = feed(first);
  const page2 = feed(second, { hasMore: false });
  // Page 2 mounts only its OWN new row — the repeated card is not rendered again.
  const grid = virtualGrid([
    first.map((row) => row.note_id),
    second.map((row) => row.note_id).filter((id) => id !== repeat.note_id),
  ], { band: 2 });
  const { source, expander } = expandingSource([[page2, feedUrl(page1.data.cursor)]], {
    mounted: grid.mounted, scrollStep: () => grid.step(), onScroll: grid.nextPage,
  });
  source.onResponse(page1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(recorder.ids().includes(repeat.note_id), false,
    "the repeated note emitted its COVER as well as its images — one picture, two keys");
  assert.equal(new Set(recorder.ids()).size, recorder.ids().length, "an id was relayed twice");
  assert.deepEqual(recorder.ids(), [...first, ...second.slice(1)].flatMap((row) => imageIdsOf(row.note_id)));
  const stats = expander.stats();
  assert.equal(stats.unreachable, 0, "the repeat was counted as a note the pass could not reach");
  assert.equal(stats.attempted, 3, "the repeat was counted twice in the coverage denominator");
  assert.equal(stats.reasons.duplicate, 1, "the repeat is recognised and counted, not silently dropped");
});

test("rednote 2A: an exhausted budget gives the rest of the board its covers without walking for them", async () => {
  // R13's rule through the streaming pass. The ceiling is on note-OPENS, and a note past it
  // needs no card at all — so it is settled on sight, the walk is never spent looking for it,
  // and the cover pass finishes rather than halting.
  const rows = imageRows(6);
  const page = feed(rows, { hasMore: false });
  const grid = virtualGrid([rows.map((row) => row.note_id)], { band: 2 });
  const { source, expander, state } = expandingSource([], {
    budget: 2, mounted: grid.mounted, scrollStep: () => grid.step(),
  });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete", "the budget is a ceiling on note-opens, not a halt");
  assert.equal(state.opened.length, 2);
  assert.deepEqual(recorder.ids(), rows.flatMap((row, index) =>
    (index < 2 ? imageIdsOf(row.note_id) : [row.note_id])));
  assert.equal(state.steps, 0, "the walk went looking for cards it had already decided not to click");
  const stats = expander.stats();
  assert.equal(stats.budgetExhausted, true);
  assert.equal(stats.unreachable, 0, "a budget that ran out is not a card that was missing");
  assert.equal(stats.partial, true);
});

test("rednote 2A: a page that never mounts anything is bounded — the walk cannot hold a sweep for ever", async () => {
  // The guard for a page that keeps reporting room to scroll (a lazy grid that renders as
  // you go, a document growing under us). The honest terminator is reaching the foot; this
  // is what stops one page walking for ever if the foot never arrives. Hitting it is the
  // same outcome, reached the same way: the rest of the page keeps its covers.
  const rows = imageRows(3);
  const page = feed(rows, { hasMore: false });
  const { source, expander, state } = expandingSource([], {
    mounted: () => [],                 // nothing is ever mounted…
    // …and the page always claims there is further to go. The throw is the test's own
    // backstop: without the ceiling this walk would never end, and a hanging suite reports
    // nothing at all — so past a bound the fake page makes the loop fail legibly instead.
    scrollStep: (step) => {
      if (step > 10) throw new Error("the walk never stopped stepping");
      return true;
    },
    maxReachRounds: 4,
  });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(state.steps, 3, "the ceiling of 4 rounds allows 3 steps between them");
  assert.deepEqual(recorder.ids(), rows.map((row) => row.note_id), "every note kept its cover, once");
  assert.equal(expander.stats().unreachable, rows.length);
});

test("rednote 2A: a note the page THREW over degrades by itself — the page around it still expands", async () => {
  // Fail-open, moved down a level. Before, a throw out of expansion degraded the WHOLE page
  // to covers (the seam caught it once, per page); now it is the one note's, and 495's
  // distinction holds — a note that was reached and blew up is `degraded`, not `unreachable`,
  // because "the board only renders what is on screen" would be a lie about it.
  const rows = imageRows(3);
  const page = feed(rows, { hasMore: false });
  const failures = [];
  const { source, expander } = expandingSource([], {
    onExpandFailure: (error, items) => failures.push({ error: String(error), ids: items.map((i) => i.sourceId) }),
    // The page blows up while this one note is being opened — a detached node, an overlay
    // that never mounted. The other two open and answer normally.
    answer: (noteId) => {
      if (noteId === rows[1].note_id) throw new Error("detached document");
      return detailFor(noteId);
    },
  });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete", "one note's throw halted a sweep it should only have degraded");
  assert.deepEqual(recorder.ids(), rows.flatMap((row, index) =>
    (index === 1 ? [row.note_id] : imageIdsOf(row.note_id))),
  "the throw took the rest of its page down with it");
  assert.equal(failures.length, 1, "the loss was not reported, or was reported per page");
  assert.deepEqual(failures[0].ids, [rows[1].note_id], "the report named the whole page instead of the note");
  const stats = expander.stats();
  assert.equal(stats.degraded, 1);
  assert.equal(stats.unreachable, 0, "a note that was reached and threw was filed as having no card");
  assert.equal(stats.reasons.expand_failed, 1);
});

test("rednote 2A: a 461 on a note reached only AFTER a step still halts resumable", async () => {
  // The fatal route through the new loop shape, and not merely on the first note of a page:
  // a sustained refusal is the same risk-control answer the board feed gives, so degrading
  // past it keeps opening notes against a session rednote has already flagged. Everything
  // settled before it is kept — nothing is relayed after it.
  //
  // The refusals start at the SECOND note, so the run is met halfway down a walked page
  // rather than at its head: the walk, the ledger and the run counter all have to compose.
  const rows = imageRows(NOTE_DETAIL_REFUSAL_STREAK + 3);
  const page = feed(rows, { hasMore: false });
  const grid = virtualGrid([rows.map((row) => row.note_id)], { band: 1 });
  const { source, state } = expandingSource([], {
    mounted: grid.mounted,
    scrollStep: () => grid.step(),
    answer: (noteId) => (noteId === rows[0].note_id ? detailFor(noteId) : detailRefusal()),
  });
  source.onResponse(page, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "halted", "a refused note-open degraded to the cover instead of halting");
  assert.match(result.error, /rednote refused the last/);
  const absorbed = rows.slice(1, NOTE_DETAIL_REFUSAL_STREAK).map((row) => row.note_id);
  assert.deepEqual(recorder.ids(), [...imageIdsOf(rows[0].note_id), ...absorbed],
    "what was settled before the halt is kept, and nothing after it is");
  assert.deepEqual(state.opened, rows.slice(0, NOTE_DETAIL_REFUSAL_STREAK + 1).map((row) => row.note_id),
    "the run was miscounted — the pass halted early or kept opening notes past it");
  assert.equal(state.closed, state.opened.length, "the board was given back even as the sweep halted");
});

test("rednote 2A: the cover-or-children rule holds across a whole mixed sweep, walked", async () => {
  // The invariant stated over the real thing rather than per case: for every note on the
  // board, the sweep relays its CHILDREN or its COVER — and a video note's deliberate pair
  // (the poster, which is a picture the cover pass already keys, plus `<note_id>:v`, which
  // is a stream) is the one documented exception, never an image-indexed child beside it.
  const live = feed(LIVE.data.notes, { hasMore: false });
  const grid = virtualGrid([LIVE.data.notes.map((note) => note.note_id)], { band: 5 });
  const { source } = expandingSource([], {
    resolveVideo: true,
    mounted: grid.mounted,
    scrollStep: () => grid.step(),
    answer: (noteId) => (LIVE.data.notes.find((n) => n.note_id === noteId).type === "video"
      ? videoDetailFor(noteId) : detailFor(noteId)),
  });
  source.onResponse(live, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.equal(new Set(recorder.ids()).size, recorder.ids().length, "an id was relayed twice");
  const relayed = new Set(recorder.ids());
  for (const row of LIVE.data.notes) {
    const children = recorder.ids().filter((id) => id.startsWith(`${row.note_id}:`));
    const hasCover = relayed.has(row.note_id);
    assert.ok(children.length > 0 || hasCover, `note ${row.note_id} produced nothing at all`);
    if (row.type === "video") {
      // T6c's pair, and its bound: the poster rides beside the STREAM and never beside an
      // image-indexed child, which would be the same picture under two keys.
      assert.deepEqual(children, [`${row.note_id}:v`], `a video note fanned out as images: ${row.note_id}`);
      assert.ok(hasCover, `the video note lost its cover still: ${row.note_id}`);
    } else {
      assert.equal(hasCover && children.length > 0, false,
        `note ${row.note_id} relayed its cover AND its images — one picture, two keys`);
    }
  }
});

test("rednote 2A: with expansion OFF the walk is never driven and the cover pass is untouched", async () => {
  // The pass verified live against a real 116-note board. Nothing in 2A is allowed to reach
  // it: no expander, so no note is opened, no card is looked for, and the board is paged by
  // the same single jump to the foot of the document it always was.
  const page2 = feed(FRESH_ROWS.slice(0, 5), { hasMore: false });
  let steps = 0;
  const { source, state } = boardSource([[page2, feedUrl(PAGE1.data.cursor)]], {
    scrollStep: () => { steps += 1; return true; },
  });
  source.onResponse(PAGE1, feedUrl());

  const recorder = recordingRelay();
  const result = await runSweep(source, { boardId: BOARD_ID }, { ...engineOpts, relay: recorder.relay });

  assert.equal(result.status, "complete");
  assert.deepEqual(recorder.ids(), [...idsOf(PAGE1), ...idsOf(page2)]);
  assert.equal(steps, 0, "the cover pass walked the board a screen at a time");
  assert.equal(state.scrolls, 1, "the cover pass paged differently than it did before 2A");
});
