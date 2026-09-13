// Atelier Capture — rednote note-open expansion (098 T5b, K3b's driving half).
//
// `parseNoteDetail` (T5a) is pure and tested apart from transport; this file tests the
// half that has to deal with the world — opening a note, correlating the response that
// comes back, budgeting the cost, and putting the board back afterwards. Everything
// browser-shaped is injected, so the whole expander runs here with no DOM.
//
// The properties asserted are the ones whose failure is SILENT:
//   · a response is matched to the note it belongs to, not to the note we are waiting for
//   · a note that only produced a cover is re-opened on the next sweep; one whose images
//     were ingested is not (the R14 pre-check, and the mode trap under it)
//   · the board is always given back — a note left open wedges the scroll and truncates
//     the sweep while reporting it complete
//   · a refusal is not a degradation

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  createNoteDetailWaiter, createNoteExpander, createPageNoteDriver,
  isRednoteChallenge, knownNoteIndex, noteIdOf, DETAIL_BUFFER_LIMIT,
} from "../src/rednote-detail-client.js";
import { mapBoardNote, parseNoteDetail } from "../src/bulk-rednote.js";

/** The live note capture — nine images, `type: "normal"`. */
const DETAIL = JSON.parse(readFileSync(new URL("./fixtures/rednote-note-detail.json", import.meta.url)));
/** The trimmed board page, for real cover rows to expand FROM. */
const BOARD = JSON.parse(readFileSync(new URL("./fixtures/rednote-board.json", import.meta.url)));

const HOST = "www.rednote.com";
const clone = (value) => structuredClone(value);

/** The live detail body, re-addressed to `noteId` — so a test can point a real nine-image
 * response at a real board row. Only the id moves; every url, count and shape is the
 * capture's. */
function detailFor(noteId) {
  const body = clone(DETAIL);
  body.data.items[0].note_card.note_id = noteId;
  return body;
}

/** A cover item exactly as the cover pass produces it (through the real mapper, so a
 * change to what a cover item looks like reaches these tests). */
function coverItem(row, overrides = {}) {
  const note = clone(row);
  Object.assign(note, overrides);
  return mapBoardNote(note, { host: HOST, cursor: "cur" });
}

const NORMAL_ROW = BOARD.data.notes.find((note) => note.type === "normal");
const VIDEO_ROW = BOARD.data.notes.find((note) => note.type === "video");

/** The observed 461 shape: a refusal wearing a success envelope (098 D1). */
const refusal = () => ({ code: 0, success: true, msg: "", data: {} });

/**
 * An expander wired to a scripted page. `open` is called with the item and may push a
 * response into the waiter — that IS the note answering. Records every open and close.
 */
function scripted({ open = () => true, ...overrides } = {}) {
  const state = { opened: [], closed: 0, sleeps: [] };
  const waiter = createNoteDetailWaiter();
  const expander = createNoteExpander({
    waiter,
    host: HOST,
    random: () => 0,
    sleep: async (ms) => {
      state.sleeps.push(ms);
      // A fake `sleep` that always resolves turns an UNBOUNDED wait into a hang rather
      // than a failure, and a hanging suite reports nothing. This makes "it never gave up"
      // a legible test failure.
      if (state.sleeps.length > 50) throw new Error("the note-open wait never gave up");
    },
    openNote: async (item) => {
      state.opened.push(noteIdOf(item));
      return open(item, waiter);
    },
    closeNote: async () => { state.closed += 1; },
    timeoutMs: 1000,
    pollMs: 250,
    pacingMs: 10,
    pacingJitterMs: 0,
    ...overrides,
  });
  return { expander, waiter, state };
}

const ids = (items) => items.map((item) => item.sourceId);

// MARK: - the waiter (correlation)

test("the waiter hands back the first body its matcher accepts and discards what it rejects", () => {
  const waiter = createNoteDetailWaiter();
  waiter.onDetail({ tag: "a" });
  waiter.onDetail({ tag: "b" });
  waiter.onDetail({ tag: "c" });

  assert.deepEqual(waiter.take((json) => (json.tag === "b" ? json : null)), { tag: "b" });
  // "a" was walked past and DROPPED, not left to be re-parsed on every later poll; "c" is
  // untouched behind the match.
  assert.equal(waiter.size, 1);
  assert.deepEqual(waiter.take((json) => json), { tag: "c" });
  assert.equal(waiter.take((json) => json), null);
});

test("the waiter is bounded — a long sweep cannot accrue note bodies without limit", () => {
  const waiter = createNoteDetailWaiter();
  for (let i = 0; i < DETAIL_BUFFER_LIMIT + 5; i += 1) waiter.onDetail({ i });
  assert.equal(waiter.size, DETAIL_BUFFER_LIMIT);
  // The OLDEST go: the newest response is the one a wait is most likely to be for.
  assert.deepEqual(waiter.take((json) => json), { i: 5 });
});

test("the waiter ignores a non-object body rather than queueing garbage", () => {
  const waiter = createNoteDetailWaiter();
  waiter.onDetail(null);
  waiter.onDetail("not json");
  assert.equal(waiter.size, 0);
});

// MARK: - the note-level known index (098 R14 + the mode trap)

test("knownNoteIndex counts a note as done only when an IMAGE of it was ingested", () => {
  // The mode trap, asserted directly. `<id>` is a COVER — the cover-only default ingests
  // one for every note on the board — and `<id>:<n>` is an expanded image. R14's literal
  // `id.split(":")[0]` over every known id maps both to the same note, so after a
  // cover-only sweep every note reads as done and the first expansion sweep opens nothing.
  const known = new Set(["cover-only", "expanded:0", "expanded:4", "other-cover"]);
  const index = knownNoteIndex(known);

  assert.equal(index.has("expanded"), true, "a note with ingested images is done");
  assert.equal(index.has("cover-only"), false, "a note with only a cover still owes its images");
  assert.equal(index.has("other-cover"), false);
  assert.equal(index.size, 1);
});

test("knownNoteIndex tolerates an empty/absent set and non-string ids", () => {
  assert.equal(knownNoteIndex(null).size, 0);
  assert.equal(knownNoteIndex(new Set()).size, 0);
  assert.equal(knownNoteIndex(new Set([123, ":leading", "a:1"])).size, 1);
});

// MARK: - expansion, the happy path

test("a note is opened, its response correlated, and its images replace the cover item", async () => {
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });

  const out = await expander.expandItems([cover]);

  // The fan-out is the parser's, asserted through it rather than against a literal count —
  // if the mapping rules move, this test moves with them instead of pinning a stale 9.
  const expected = parseNoteDetail(detailFor(cover.sourceId), { host: HOST, xsecToken: cover.xsecToken });
  assert.deepEqual(ids(out), ids(expected.items));
  assert.equal(out.includes(cover), false, "the cover was REPLACED, not kept alongside its images");
  assert.deepEqual(state.opened, [cover.sourceId]);
  assert.equal(state.closed, 1, "the board was given back");

  const stats = expander.stats();
  assert.equal(stats.expanded, 1);
  assert.equal(stats.opened, 1);
  assert.equal(stats.partial, false);
});

test("the cover row's xsecToken is threaded into the expanded items — the detail body has none", async () => {
  // The detail response carries only `user.xsec_token`, which authorizes the AUTHOR's
  // profile, not this note. Taking it would produce items whose token opens the wrong
  // thing, which fails nowhere until someone follows one.
  const cover = coverItem(NORMAL_ROW);
  assert.ok(cover.xsecToken, "the fixture row must carry a token for this test to mean anything");
  const authorToken = DETAIL.data.items[0].note_card.user.xsec_token;

  const { expander } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });
  const out = await expander.expandItems([cover]);

  assert.ok(out.length > 1);
  for (const item of out) {
    assert.equal(item.xsecToken, cover.xsecToken);
    assert.notEqual(item.xsecToken, authorToken, "the author's profile token was used as the note's");
    assert.equal(JSON.stringify(item.provenance).includes(item.xsecToken), false,
      "a short-lived credential never enters provenance");
  }
});

// MARK: - correlation (the replay-buffer hazard)

test("an EARLIER note's detail is discarded, not mistaken for the note we opened", async () => {
  // The hazard `matchesScope` guards on the board pass, which cannot be reused here: a
  // detail body has no `board_id`. Left uncorrelated, note B would be saved under note A's
  // images — every id, every url and every count wrong, and nothing would fail.
  const cover = coverItem(NORMAL_ROW);
  const stale = detailFor("SOMEONE-ELSES-NOTE");
  const { expander, state } = scripted({
    open: (item, waiter) => {
      waiter.onDetail(stale);                              // the replay buffer's leftover
      waiter.onDetail(detailFor(noteIdOf(item)));          // and then the real answer
      return true;
    },
  });

  const out = await expander.expandItems([cover]);

  const expected = parseNoteDetail(detailFor(cover.sourceId), { host: HOST, xsecToken: cover.xsecToken });
  assert.deepEqual(ids(out), ids(expected.items));
  for (const item of out) {
    assert.equal(item.provenance.rawMetadata.noteId, cover.sourceId,
      "an item from the wrong note's response leaked into this note's expansion");
  }
  assert.equal(state.closed, 1);
});

test("a note whose response never arrives times out, keeps its cover, and costs a BOUNDED wait", async () => {
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({ open: () => true });   // the page never answers

  const out = await expander.expandItems([cover]);

  assert.deepEqual(out, [cover], "the cover survives — expansion is a bonus, never a loss");
  // Bounded: the poll loop spends timeoutMs and stops. Without a ceiling a single note that
  // never answers hangs the sweep, which is the failure the budget exists to prevent.
  const polls = state.sleeps.filter((ms) => ms === 250).length;
  assert.equal(polls, 4, "1000ms of timeout at a 250ms poll");
  assert.equal(state.closed, 1, "a note that did not answer is still closed");
  assert.equal(expander.stats().degraded, 1);
  assert.equal(expander.stats().reasons.timeout, 1);
  assert.equal(expander.stats().partial, true);
});

test("a note whose card is not on the page degrades without opening or closing anything", async () => {
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({ open: () => false });

  const out = await expander.expandItems([cover]);

  assert.deepEqual(out, [cover]);
  assert.equal(state.closed, 0, "nothing was opened, so nothing is closed");
  assert.equal(expander.stats().reasons.no_note_card, 1);
  assert.equal(expander.stats().partial, true);
});

// MARK: - the board must always come back

test("the board is restored even when the note-open throws", async () => {
  // A note left open sits over the grid: the source's scroll then pages nothing, the sweep
  // stalls or ends, and it reports a COMPLETE board with half its rows. The close is in a
  // `finally` for exactly this.
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({
    open: () => { throw new Error("the overlay never opened"); },
  });

  await assert.rejects(expander.expandItems([cover]), /overlay never opened/);
  assert.equal(state.closed, 0, "the open threw before anything was open");

  // …and when the note DID open and the read is what failed.
  const second = scripted({
    open: (item, waiter) => { waiter.onDetail(refusal()); return true; },
  });
  await assert.rejects(second.expander.expandItems([cover]), /rednote refused/);
  assert.equal(second.state.closed, 1, "a challenge still gives the board back");
});

test("a closeNote that throws is survivable — the sweep continues to the next note", async () => {
  const rows = BOARD.data.notes.filter((note) => note.type === "normal");
  const cover = coverItem(rows[0]);
  const logs = [];
  const { expander, state } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
    closeNote: async () => { state.closed += 1; throw new Error("Escape did nothing"); },
    log: (...args) => logs.push(args.join(" ")),
  });

  const out = await expander.expandItems([cover]);
  assert.ok(out.length > 1, "the note still expanded");
  assert.ok(logs.some((line) => /closing the note failed/.test(line)),
    "a close failure is reported — it is how a wedged board is diagnosed");
});

// MARK: - video notes are refused WITHOUT being opened

test("a video note is never opened — the parser would refuse it anyway", async () => {
  // 30 of the 37 rows of the sampled board are video, and `parseNoteDetail` refuses every
  // one of them (T6 is blocked on a live video capture). Opening them buys a guaranteed
  // refusal at the price of a paced note-open each — 81 % of the budget for nothing.
  const video = coverItem(VIDEO_ROW);
  assert.equal(video.provenance.rawMetadata.kind, "video");
  const { expander, state } = scripted();

  const out = await expander.expandItems([video]);

  assert.deepEqual(out, [video], "a video note keeps its cover, which is what K3a captures");
  assert.deepEqual(state.opened, [], "a note the parser will refuse was opened anyway");
  assert.equal(state.sleeps.length, 0, "and it cost no pacing either");
  const stats = expander.stats();
  assert.equal(stats.refused, 1);
  assert.equal(stats.degraded, 0);
  // A refusal is NOT a shortfall of this sweep: expansion was never possible for a video
  // note. Counting it as one would make every sweep of an 81 %-video board report partial.
  assert.equal(stats.partial, false);
});

test("a note the BOARD called an image and the DETAIL calls video is refused, not degraded", async () => {
  const cover = coverItem(NORMAL_ROW);
  const asVideo = detailFor(cover.sourceId);
  asVideo.data.items[0].note_card.type = "video";
  const { expander } = scripted({ open: (item, waiter) => { waiter.onDetail(asVideo); return true; } });

  const out = await expander.expandItems([cover]);

  assert.deepEqual(out, [cover]);
  const stats = expander.stats();
  assert.equal(stats.refused, 1);
  assert.equal(stats.degraded, 0);
  assert.equal(stats.reasons.video, 1);
});

test("a note that came back unreadable keeps its cover and counts as a degradation", async () => {
  // `unsupported` NEVER means "this note is empty" — the cover pass already captured
  // something usable, and expansion must degrade to it rather than replace it with nothing.
  const cover = coverItem(NORMAL_ROW);
  const empty = detailFor(cover.sourceId);
  empty.data.items[0].note_card.image_list = [];
  const { expander } = scripted({ open: (item, waiter) => { waiter.onDetail(empty); return true; } });

  const out = await expander.expandItems([cover]);

  assert.deepEqual(out, [cover]);
  assert.equal(expander.stats().degraded, 1);
  assert.equal(expander.stats().reasons.no_images, 1);
});

// MARK: - the refusal (098 D8)

test("a refused note-open THROWS a challenge, and the challenge is classified fatal", async () => {
  // The one expansion failure that must not degrade: degrading past a refusal keeps
  // opening notes against a session rednote has already flagged. The seam re-raises it
  // (`isFatalExpandFailure`) so the engine halts RESUMABLE.
  const cover = coverItem(NORMAL_ROW);
  const { expander } = scripted({ open: (item, waiter) => { waiter.onDetail(refusal()); return true; } });

  const error = await expander.expandItems([cover]).then(() => null, (e) => e);
  assert.ok(error, "a refusal degraded to the cover instead of halting the sweep");
  assert.match(String(error), /rednote refused the feed/);
  assert.equal(isRednoteChallenge(error), true);
});

test("isRednoteChallenge says no to an ordinary expansion failure", () => {
  // The predicate decides HALT vs degrade, so a false positive turns "one note would not
  // open" into "the sweep stops".
  assert.equal(isRednoteChallenge(new Error("the note never opened")), false);
  assert.equal(isRednoteChallenge(null), false);
  assert.equal(isRednoteChallenge({ challenge: "yes" }), false, "only the boolean flag counts");
});

test("a refusal for ANOTHER note still halts — a challenge outranks correlation", async () => {
  // A refusal carries no note id, so a matcher that correlated first and asked questions
  // later would discard it as "someone else's response" and keep opening notes.
  const cover = coverItem(NORMAL_ROW);
  const { expander } = scripted({
    open: (item, waiter) => {
      waiter.onDetail(refusal());
      waiter.onDetail(detailFor(noteIdOf(item)));
      return true;
    },
  });

  await assert.rejects(expander.expandItems([cover]), /rednote refused the feed/);
});

// MARK: - the budget (098 R13)

test("the note-open budget is a CEILING: past it every note keeps its cover and the sweep finishes", async () => {
  const rows = [NORMAL_ROW, ...BOARD.data.notes.filter((n) => n.type === "normal")]
    .map((row, i) => coverItem(row, { note_id: `note-${i}` }));
  assert.ok(rows.length >= 2);
  const { expander, state } = scripted({
    budget: 1,
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });

  const out = await expander.expandItems(rows);

  assert.deepEqual(state.opened, [rows[0].sourceId], "the budget bounded the opens");
  // The cover pass FINISHES: every note past the budget is still yielded, still relayed,
  // still saved at cover fidelity. Halting would have been the easy wrong answer.
  for (const cover of rows.slice(1)) {
    assert.equal(out.includes(cover), true, `note past the budget was dropped: ${cover.sourceId}`);
  }
  const stats = expander.stats();
  assert.equal(stats.budgetExhausted, true);
  assert.equal(stats.reasons.budget, rows.length - 1);
  assert.equal(stats.partial, true, "a sweep that ran out of budget must not report a full expansion");
});

test("the budget is spent on opens, not on notes — skips and refusals do not consume it", async () => {
  const video = coverItem(VIDEO_ROW);
  const normal = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({
    budget: 1,
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });

  const out = await expander.expandItems([video, normal]);

  assert.deepEqual(state.opened, [normal.sourceId], "the video note ate the budget");
  assert.ok(out.length > 1);
  assert.equal(expander.stats().budgetExhausted, false);
});

// MARK: - the pre-check, armed and disarmed (098 R14)

test("DISARMED by default: an already-expanded note is opened again", async () => {
  // The default has to be the safe one. Arming is the caller's decision, taken only when
  // the prior sweep of this scope closed clean.
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });

  await expander.expandItems([cover]);
  assert.deepEqual(state.opened, [cover.sourceId]);
});

test("ARMED: a note whose images are known is skipped and yields NOTHING", async () => {
  // Not the cover — that is the point. The cover's `<note_id>` key was never ingested for
  // an expanded note (its children were), so re-emitting it would mint a brand-new item on
  // every re-sweep: 400 fresh covers for a board that is already complete.
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted();
  expander.arm({ knownSet: new Set([`${cover.sourceId}:0`, `${cover.sourceId}:1`]), armed: true });

  const out = await expander.expandItems([cover]);

  assert.deepEqual(out, []);
  assert.deepEqual(state.opened, []);
  assert.equal(state.sleeps.length, 0, "a skipped note costs no pacing");
  assert.equal(expander.stats().skippedKnown, 1);
  assert.equal(expander.stats().partial, false);
});

test("ARMED: a note known only by its COVER is still opened (the mode trap)", async () => {
  // After the cover-only default sweep, every note on the board is known as `<note_id>`.
  // If that counted, the first expansion sweep would skip every note-open there is,
  // complete in seconds, ingest nothing, and report success.
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });
  expander.arm({ knownSet: new Set([cover.sourceId]), armed: true });

  const out = await expander.expandItems([cover]);

  assert.deepEqual(state.opened, [cover.sourceId], "the toggle silently did nothing on an already-swept board");
  assert.ok(out.length > 1);
});

test("arm({ armed: false }) leaves the pre-check off even with a full known-set", async () => {
  const cover = coverItem(NORMAL_ROW);
  const { expander, state } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });
  assert.equal(expander.arm({ knownSet: new Set([`${cover.sourceId}:0`]), armed: false }), 0);

  await expander.expandItems([cover]);
  assert.deepEqual(state.opened, [cover.sourceId]);
});

// MARK: - stats / the first-class partial outcome (098 R7)

test("stats separate the four ways a note can end, and only two make a sweep partial", async () => {
  const expanded = coverItem(NORMAL_ROW, { note_id: "will-expand" });
  const degraded = coverItem(NORMAL_ROW, { note_id: "will-time-out" });
  const video = coverItem(VIDEO_ROW, { note_id: "is-video" });
  const known = coverItem(NORMAL_ROW, { note_id: "already-done" });

  const { expander } = scripted({
    open: (item, waiter) => {
      if (noteIdOf(item) === "will-expand") waiter.onDetail(detailFor("will-expand"));
      return true;
    },
  });
  expander.arm({ knownSet: new Set(["already-done:3"]), armed: true });

  await expander.expandItems([expanded, degraded, video, known]);

  const stats = expander.stats();
  assert.equal(stats.mode, "expansion");
  assert.equal(stats.expanded, 1);
  assert.equal(stats.degraded, 1);
  assert.equal(stats.refused, 1);
  assert.equal(stats.skippedKnown, 1);
  assert.equal(stats.opened, 2, "only the two candidates were opened");
  assert.equal(stats.images, parseNoteDetail(detailFor("will-expand"), { host: HOST }).items.length);
  assert.equal(stats.partial, true, "one note kept its cover, so this sweep expanded less than it meant to");
});

test("a fully successful expansion is NOT partial", async () => {
  const cover = coverItem(NORMAL_ROW);
  const { expander } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });
  await expander.expandItems([cover]);
  assert.equal(expander.stats().partial, false);
});

test("an empty page is returned untouched — no opens, no pacing, no stats", async () => {
  const { expander, state } = scripted();
  const empty = [];
  assert.equal(await expander.expandItems(empty), empty);
  assert.deepEqual(state.opened, []);
  assert.equal(expander.stats().opened, 0);
});

test("an item with no note id keeps itself rather than being dropped", async () => {
  const { expander, state } = scripted();
  const orphan = { sourceId: null, provenance: { rawMetadata: {} } };
  assert.deepEqual(await expander.expandItems([orphan]), [orphan]);
  assert.deepEqual(state.opened, []);
  assert.equal(expander.stats().reasons.no_note_id, 1);
});

// MARK: - the live page driver (browser glue)

/** A fake board page: one anchor per note id, recording clicks and scrolls. */
function fakeWindow({ links = [], pathname = "/board/abc" } = {}) {
  const state = { clicks: [], scrolled: [], back: 0, scrolledIntoView: [] };
  const nodes = links.map((href) => ({
    getAttribute: () => href,
    click: () => state.clicks.push(href),
    scrollIntoView: () => state.scrolledIntoView.push(href),
  }));
  return {
    state,
    win: {
      scrollY: 1234,
      scrollTo: (x, y) => state.scrolled.push(y),
      history: { back: () => { state.back += 1; } },
      location: { pathname },
      KeyboardEvent: function KeyboardEvent(type, init) { this.type = type; Object.assign(this, init); },
      document: {
        querySelector: (selector) => {
          const match = /a\[href\*="([^"]+)"\]/.exec(selector);
          if (!match) return null;
          const index = links.findIndex((href) => href.includes(match[1]));
          return index === -1 ? null : nodes[index];
        },
        dispatchEvent: (event) => { state.event = event; return true; },
      },
    },
  };
}

test("the page driver clicks the note's own card — it never navigates", async () => {
  // Assigning `location` would tear down the content script, the engine and the sweep with
  // it. The card click keeps the board (and this code) alive underneath the overlay.
  const { win, state } = fakeWindow({ links: ["/explore/NOTE-1?xsec_token=t", "/explore/NOTE-2"] });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  const opened = await driver.openNote({ sourceId: "NOTE-2", provenance: { rawMetadata: { noteId: "NOTE-2" } } });

  assert.equal(opened, true);
  assert.deepEqual(state.clicks, ["/explore/NOTE-2"]);
});

test("the page driver reports FALSE when the note's card is not on the page", async () => {
  const { win, state } = fakeWindow({ links: ["/explore/NOTE-1"] });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  assert.equal(await driver.openNote({ sourceId: "NOTE-404", provenance: { rawMetadata: { noteId: "NOTE-404" } } }), false);
  assert.deepEqual(state.clicks, []);
});

test("the page driver refuses an id that is not id-shaped rather than building a selector from it", async () => {
  const { win, state } = fakeWindow({ links: ['/explore/x"] , a['] });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  assert.equal(await driver.openNote({ sourceId: '"] , a[href*="', provenance: { rawMetadata: {} } }), false);
  assert.deepEqual(state.clicks, []);
});

test("closing restores the board's scroll position so the sweep keeps paging from where it was", async () => {
  // The source pages the board with `scrollTo(0, scrollHeight)`. A note-open that left the
  // viewport halfway up the grid would page from there — on a virtualised grid, from a DOM
  // rebuilt around a different offset.
  const { win, state } = fakeWindow({ links: ["/explore/NOTE-1"] });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  await driver.openNote({ sourceId: "NOTE-1", provenance: { rawMetadata: { noteId: "NOTE-1" } } });
  win.scrollY = 0;                       // the overlay moved the page
  await driver.closeNote();

  assert.deepEqual(state.scrolled, [1234]);
  assert.equal(state.event.key, "Escape", "Escape is the overlay's own close affordance");
  assert.equal(state.back, 0, "still on the board route — no history entry to pop");
});

test("closing falls back to history.back() when the SPA ROUTED to the note instead of overlaying it", async () => {
  const { win, state } = fakeWindow({ links: ["/explore/NOTE-1"], pathname: "/explore/NOTE-1" });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  await driver.closeNote();

  assert.equal(state.back, 1);
  assert.deepEqual(state.scrolled, [0], "and the board scroll is still restored afterwards");
});

test("the page driver never throws into the sweep, whatever the page does", async () => {
  const win = {
    document: { querySelector: () => { throw new Error("detached document"); } },
    location: { pathname: "/board/abc" },
  };
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  assert.equal(await driver.openNote({ sourceId: "NOTE-1", provenance: { rawMetadata: { noteId: "NOTE-1" } } }), false);
  await driver.closeNote();   // no KeyboardEvent, no history, no scrollTo — and no throw
});
