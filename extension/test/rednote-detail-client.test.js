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
  createNoteDetailWaiter, createNoteExpander, createPageFeedResetter, createPageNoteDriver,
  isRednoteChallenge, knownNoteIndex, noteIdOf, DETAIL_BUFFER_LIMIT,
} from "../src/rednote-detail-client.js";
import { mapBoardNote, parseNoteDetail } from "../src/bulk-rednote.js";

/** The live note capture — nine images, `type: "normal"`. */
const DETAIL = JSON.parse(readFileSync(new URL("./fixtures/rednote-note-detail.json", import.meta.url)));
/** The trimmed board page, for real cover rows to expand FROM. */
const BOARD = JSON.parse(readFileSync(new URL("./fixtures/rednote-board.json", import.meta.url)));
/** The live VIDEO note capture — one `EF4` rung, one backup, one poster (098 T6b). */
const VIDEO = JSON.parse(readFileSync(new URL("./fixtures/rednote-note-video.json", import.meta.url)));

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

/** The live VIDEO detail body, re-addressed to `noteId` — the mirror of `detailFor`. */
function videoDetailFor(noteId) {
  const body = clone(VIDEO);
  body.data.items[0].note_card.note_id = noteId;
  return body;
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

// MARK: - video notes, once the video toggle lets them expand (098 T6c)

test("with resolveVideo on, a video note IS opened and yields its cover AND its stream", async () => {
  const video = coverItem(VIDEO_ROW);
  const { expander, state } = scripted({
    resolveVideo: true,
    open: (item, waiter) => { waiter.onDetail(videoDetailFor(noteIdOf(item))); return true; },
  });

  const out = await expander.expandItems([video]);

  assert.deepEqual(state.opened, [video.sourceId], "the toggle is what makes opening it worth a note-open");
  // BOTH, and in this order. The cover is the poster at `<note_id>` — a real picture, and
  // the thing 020's "keep the cover still" falls back to when the ladder is exhausted at
  // INGEST time, which is long after this parse and cannot be undone from here.
  assert.deepEqual(ids(out), [video.sourceId, `${video.sourceId}:v`]);
  assert.equal(out[0], video, "the cover item is passed through untouched, not rebuilt");
  assert.equal(out[1].mediaUrl, null, "and the stream carries no still, so the poster ingests ONCE");

  const stats = expander.stats();
  assert.equal(stats.expanded, 1);
  assert.equal(stats.streams, 1);
  assert.equal(stats.images, 0, "a stream is not a picture — a count that said otherwise would lie");
  assert.equal(stats.refused, 0);
  assert.equal(stats.partial, false);
});

test("a re-sweep does NOT re-open a video note whose stream was captured", async () => {
  // The budget-burn trap the T5 addendum exists to prevent, at the one key T6c added. The
  // pre-check is armed from the REAL known-set the app returns, through the real
  // `knownNoteIndex`, so this asserts the predicate rather than a description of it.
  const video = coverItem(VIDEO_ROW);
  const { expander, state } = scripted({
    resolveVideo: true,
    open: (item, waiter) => { waiter.onDetail(videoDetailFor(noteIdOf(item))); return true; },
  });
  expander.arm({ knownSet: new Set([`${video.sourceId}:v`]), armed: true });

  const out = await expander.expandItems([video]);

  assert.deepEqual(state.opened, [], "a note whose stream is already ingested must not be re-opened");
  assert.deepEqual(out, [], "…and must yield nothing — re-emitting its cover would mint a new item");
  assert.equal(expander.stats().skippedKnown, 1);
  assert.equal(state.sleeps.length, 0, "a skipped note costs no pacing either");
});

test("an already-expanded video note is SKIPPED even with the video toggle off", async () => {
  // The known-set pre-check runs ahead of the video refusal, and the order is load-bearing
  // for the accounting: a note whose stream a previous sweep captured has nothing left to
  // do, and counting it as a fresh REFUSAL would report an 81 %-video board as refusing
  // hundreds of notes it had already finished.
  const video = coverItem(VIDEO_ROW);
  const { expander, state } = scripted();      // resolveVideo off — the T5b default
  expander.arm({ knownSet: new Set([`${video.sourceId}:v`]), armed: true });

  const out = await expander.expandItems([video]);

  assert.deepEqual(out, []);
  assert.deepEqual(state.opened, []);
  const stats = expander.stats();
  assert.equal(stats.skippedKnown, 1);
  assert.equal(stats.refused, 0, "a finished note is not a refusal");
});

test("a COVER-only video note is still re-opened — the mode trap, unchanged by :v", async () => {
  // The other half of the same predicate: `<note_id>` alone never reads as expanded, so a
  // board swept cover-only does not silently skip every note-open of the first video sweep.
  const video = coverItem(VIDEO_ROW);
  const { expander, state } = scripted({
    resolveVideo: true,
    open: (item, waiter) => { waiter.onDetail(videoDetailFor(noteIdOf(item))); return true; },
  });
  expander.arm({ knownSet: new Set([video.sourceId]), armed: true });

  await expander.expandItems([video]);

  assert.deepEqual(state.opened, [video.sourceId]);
});

test("a ladder that yields nothing keeps the cover, counts a STREAM REFUSAL, and is not partial", async () => {
  // 020's cover-still-only case. The note WAS opened and its ladder read; there is simply no
  // decodable stream in it. Calling that "partly expanded" would report an 81 %-video board
  // as partial on every sweep for working exactly as designed — the failure T5b's
  // refused/degraded split was written to prevent, in a new coat.
  const video = coverItem(VIDEO_ROW);
  const efOnly = (noteId) => {
    const body = videoDetailFor(noteId);
    body.data.items[0].note_card.video.media.stream = { EF4: [], EF5: [], EF6: [], EF7: [] };
    return body;
  };
  const { expander, state } = scripted({
    resolveVideo: true,
    open: (item, waiter) => { waiter.onDetail(efOnly(noteIdOf(item))); return true; },
  });

  const out = await expander.expandItems([video]);

  assert.deepEqual(out, [video], "the cover the K3a pass captured is what the note keeps");
  assert.equal(state.opened.length, 1);
  const stats = expander.stats();
  assert.equal(stats.streamRefused, 1);
  assert.equal(stats.degraded, 0, "a refused ladder is not a degradation of this sweep");
  assert.equal(stats.refused, 0, "…nor the never-opened kind");
  assert.equal(stats.partial, false);
  assert.equal(stats.reasons.empty_ladder, 1, "and it says WHICH nothing");
});

test("a refused ladder leaves no child, so the NEXT sweep opens the note again", async () => {
  // Stated as a test because it is a cost, and a deliberate one: 020 B3 saw the same note
  // serve a DIFFERENT ladder on two visits minutes apart, so a refusal is a fact about one
  // visit's ladder, not about the note. Recording it as permanently done would wall the note
  // off forever on the strength of a list that demonstrably rotates. The cost is one
  // note-open per refused note per sweep, bounded by the budget.
  const video = coverItem(VIDEO_ROW);
  const { expander } = scripted({
    resolveVideo: true,
    open: (item, waiter) => {
      const body = videoDetailFor(noteIdOf(item));
      body.data.items[0].note_card.video.media.stream = { EF4: [] };
      waiter.onDetail(body);
      return true;
    },
  });

  const out = await expander.expandItems([video]);

  assert.deepEqual(ids(out), [video.sourceId]);
  assert.equal(knownNoteIndex(new Set(ids(out))).has(video.sourceId), false,
    "nothing this note produced registers as expanded, so a re-sweep tries the ladder again");
});

test("an IMAGE note is unchanged by the video toggle — its cover is still replaced", async () => {
  // The composition claim, from the other side: `resolveVideo` decides what a VIDEO note
  // contributes and nothing else. A carousel's children still supersede its cover.
  const cover = coverItem(NORMAL_ROW);
  const { expander } = scripted({
    resolveVideo: true,
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });

  const out = await expander.expandItems([cover]);

  assert.equal(out.includes(cover), false);
  assert.ok(out.length > 1);
  assert.ok(out.every((item) => item.sourceId.startsWith(`${cover.sourceId}:`)));
  const stats = expander.stats();
  assert.equal(stats.images, out.length);
  assert.equal(stats.streams, 0);
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

// MARK: - coverage, and the unmounted card (changelog 495)
//
// The board grid is VIRTUALISED. A probe on a live board on 2026-09-14 counted 13 distinct
// note cards in the DOM against a feed page of 37-38 notes and a board of 116 — so on a real
// sweep MOST notes have no card to click when expansion reaches them, `openNote` returns
// false, and they keep their cover. These tests pin the REPORTING of that, which is all this
// change does; opening a note while its card is still mounted is 098 2A and is not here.

test("a card that was never on the page is counted apart from a note that would not answer", async () => {
  // Both keep their cover, and to a user both read as "it did not expand" — but one was
  // never reached and the other was reached and stayed silent. They want different fixes
  // (a page-loop redesign vs. a timeout or a parse), so a reader of the stats has to be
  // able to tell them apart. Before this they were one number.
  const unmounted = coverItem(NORMAL_ROW, { note_id: "never-mounted" });
  const silent = coverItem(NORMAL_ROW, { note_id: "will-time-out" });
  const { expander, state } = scripted({ open: (item) => noteIdOf(item) !== "never-mounted" });

  const out = await expander.expandItems([unmounted, silent]);

  assert.deepEqual(ids(out), ["never-mounted", "will-time-out"], "both covers survive");
  const stats = expander.stats();
  assert.equal(stats.unreachable, 1, "the note with no card could not be REACHED");
  assert.equal(stats.degraded, 1, "the note that timed out was reached and gave no answer");
  assert.equal(stats.reasons.no_note_card, 1);
  assert.equal(stats.reasons.timeout, 1);
  assert.equal(state.closed, 1, "only the note that actually opened is closed");
  assert.equal(stats.partial, true);
});

test("a board where no card is mounted reports a total shortfall, not a clean sweep", async () => {
  // The realistic virtualised case, and the one that must never read as a success. Once
  // `no_note_card` stopped landing in `degraded`, `partial` had to name `unreachable`
  // itself or the WORST possible expansion would be the one reporting no shortfall at all.
  const rows = ["a", "b", "c"].map((id) => coverItem(NORMAL_ROW, { note_id: id }));
  const { expander, state } = scripted({ open: () => false });

  await expander.expandItems(rows);

  const stats = expander.stats();
  assert.equal(stats.expanded, 0);
  assert.equal(stats.unreachable, rows.length);
  assert.equal(stats.attempted, rows.length, "every one was a note this sweep meant to expand");
  assert.equal(stats.degraded, 0, "nothing was reached, so nothing can have failed to answer");
  assert.equal(state.closed, 0, "nothing opened, so nothing is closed");
  assert.equal(stats.partial, true, "expanding none of the board is not a complete expansion");
});

test("coverage counts only the notes the sweep MEANT to expand", async () => {
  // A note a previous sweep already expanded, and a video note with the video toggle off,
  // were both correctly left alone — neither is a shortfall (098 T5b's refused/degraded
  // split, and T6c after it). Putting them in the denominator would report a coverage gap
  // on an 81 %-video board for doing exactly what it was told to do.
  const expanded = coverItem(NORMAL_ROW, { note_id: "will-expand" });
  const video = coverItem(VIDEO_ROW, { note_id: "is-video" });
  const known = coverItem(NORMAL_ROW, { note_id: "already-done" });
  const { expander } = scripted({
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });
  expander.arm({ knownSet: new Set(["already-done:3"]), armed: true });

  await expander.expandItems([expanded, video, known]);

  const stats = expander.stats();
  assert.equal(stats.attempted, 1);
  assert.equal(stats.expanded, stats.attempted, "this sweep expanded everything it set out to");
  assert.equal(stats.refused, 1);
  assert.equal(stats.skippedKnown, 1);
  assert.equal(stats.partial, false);
});

test("a note the budget never reached is inside the coverage, not outside it", async () => {
  // "We ran out" is a shortfall, not a decision about that note — so it belongs in the
  // denominator, and `expanded 1 of N` is what says how far the sweep actually got.
  const rows = [NORMAL_ROW, ...BOARD.data.notes.filter((n) => n.type === "normal")]
    .map((row, i) => coverItem(row, { note_id: `note-${i}` }));
  assert.ok(rows.length >= 2);
  const { expander } = scripted({
    budget: 1,
    open: (item, waiter) => { waiter.onDetail(detailFor(noteIdOf(item))); return true; },
  });

  await expander.expandItems(rows);

  const stats = expander.stats();
  assert.equal(stats.attempted, rows.length);
  assert.equal(stats.expanded, 1);
  assert.equal(stats.unreachable, 0, "a budget that ran out is not a card that was missing");
});

test("expansion that was never given a note reports no coverage to misread", async () => {
  // A refused sweep opens ZERO notes (changelog 491/492's reset work guarantees it), and a
  // sweep of an empty board attempts nothing. Neither is a shortfall, and neither may
  // produce a ratio — "expanded 0 of 0" is a sentence about nothing.
  const { expander } = scripted();
  await expander.expandItems([]);
  const stats = expander.stats();
  assert.equal(stats.attempted, 0);
  assert.equal(stats.unreachable, 0);
  assert.equal(stats.partial, false);
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
  // It is still a note this sweep set out to expand — an id it could not read is a
  // shortfall like any other, not a note it deliberately passed over.
  assert.equal(expander.stats().attempted, 1);
});

// MARK: - the live page driver (browser glue)

/**
 * A fake board page. `links` is the page's anchors IN DOCUMENT ORDER, and the document
 * answers `querySelectorAll` in that order — which is the whole point here: the live board
 * renders two anchors per note and the useless one is first.
 *
 * `state.selectors` records every selector string the document was asked for, so a test can
 * assert what was interpolated into one rather than only what came back out.
 *
 * `routes` makes the fake page NAVIGABLE, which the feed reset needs and the note driver did
 * not: an href listed in it becomes the new `location.pathname` when that anchor is clicked,
 * and `history.back()` pops back to the previous one. An href absent from it is a click that
 * does NOT route — the case the reset must notice before it touches the history. `state.log`
 * is the driver's own log, `state.restoration` every value written to
 * `history.scrollRestoration`, and `state.navigations` any attempt to leave the page the way
 * neither driver is ever allowed to (assigning `location`, or opening a window).
 */
function fakeWindow({
  links = [], pathname = "/board/abc", routes = {}, under = null, backSteps = 1,
} = {}) {
  const state = {
    clicks: [], scrolled: [], back: 0, scrolledIntoView: [], selectors: [],
    log: [], restoration: [], navigations: [], order: [],
  };
  // `under` is the entry BENEATH the page the driver starts on — what a back would land on
  // if it popped one too many. `backSteps` is how many entries one `history.back()` pops:
  // an SPA that pushed two entries for one route change pops past the board with one back.
  const history = under ? [under, pathname] : [pathname];
  const nodes = links.map((href) => ({
    getAttribute: (name) => (name === "href" ? href : null),
    click: () => {
      state.clicks.push(href);
      state.order.push(`click:${href}`);
      if (Object.prototype.hasOwnProperty.call(routes, href)) history.push(routes[href]);
    },
    scrollIntoView: () => state.scrolledIntoView.push(href),
  }));
  /**
   * Enough of a selector engine to make an injection REACHABLE, which a regex that simply
   * declines to parse anything unexpected is not — a fake that returns `[]` for a malformed
   * selector passes every guard test with the guard deleted.
   *
   * So this models the three behaviours that decide whether a breakout bites: a comma makes
   * a selector LIST and the terms are unioned in document order; `[href*=""]` matches
   * nothing (an empty substring never matches, per CSS); and a selector that will not parse
   * throws the way `querySelectorAll` throws `SyntaxError`, rather than quietly matching
   * nothing.
   */
  const matching = (selector) => {
    state.selectors.push(selector);
    const terms = selector.split(",").map((term) => {
      const parsed = /^\s*a\[href\*="([^"]*)"\]\s*$/.exec(term);
      if (!parsed) throw new Error(`SyntaxError: '${selector}' is not a valid selector`);
      return parsed[1];
    });
    return nodes.filter((_, index) =>
      terms.some((needle) => needle !== "" && links[index].includes(needle)));
  };
  const win = {
    scrollY: 1234,
    scrollTo: (x, y) => { state.scrolled.push(y); state.order.push(`scroll:${y}`); },
    open: (...args) => { state.navigations.push(["open", ...args]); },
    history: {
      back: () => {
        state.back += 1;
        state.order.push("back");
        for (let step = 0; step < backSteps && history.length > 1; step += 1) history.pop();
      },
    },
    location: {
      get pathname() { return history[history.length - 1]; },
      set href(value) { state.navigations.push(["href", value]); },
    },
    KeyboardEvent: function KeyboardEvent(type, init) { this.type = type; Object.assign(this, init); },
    document: {
      querySelectorAll: (selector) => matching(selector),
      querySelector: (selector) => matching(selector)[0] || null,
      dispatchEvent: (event) => { state.event = event; return true; },
    },
  };
  // `scrollRestoration` is a real property with a real value, watched rather than replaced:
  // the reset must PUT BACK whatever the page had, not merely set its own.
  let restoration = "auto";
  Object.defineProperty(win.history, "scrollRestoration", {
    get: () => restoration,
    set: (value) => { restoration = value; state.restoration.push(value); },
    configurable: true,
  });
  return { state, win, log: (...args) => state.log.push(args.join(" ")) };
}

/**
 * The live board's own anchors for ONE note, in the order the page emits them — probed in
 * the console on 2026-09-14 against `https://www.rednote.com/board/69322476000000001202811f`
 * and copied verbatim, query strings included.
 *
 * Two things in here are the bug rather than decoration. The tokenless anchor is FIRST, so
 * document order picks the one rednote answers 404 for. And `xsec_source` is present but
 * EMPTY, so any test of "is this URL usable" that reaches for the source rather than the
 * token would reject the only anchor that works.
 */
const LIVE_BOARD_ID = "69322476000000001202811f";
const LIVE_NOTE_ID = "6a9f696e000000000d020daa";
const LIVE_TOKEN = "AB40jTqIOcxMe4J14aCe6fUNDD35OS0cACcj06BBg-Y1w=";
const LIVE_NOTE_HREF = `/board/${LIVE_BOARD_ID}/${LIVE_NOTE_ID}`;
const LIVE_TOKENISED_HREF = `${LIVE_NOTE_HREF}?xsec_token=${LIVE_TOKEN}&xsec_source=`;
const LIVE_ANCHORS = [
  "/user/profile/65d3e54f000000000503359d",
  "/user/profile/65d3e54f000000000503359d?tab=fav&subTab=board",
  LIVE_NOTE_HREF,
  LIVE_TOKENISED_HREF,
];

/** An item shaped like the cover pass's, for the driver to open. */
const noteItem = (noteId, overrides = {}) => ({
  sourceId: noteId, provenance: { rawMetadata: { noteId } }, ...overrides,
});

/** The `xsec_token` an href carries, or null — the property every open depends on. */
const tokenIn = (href) => {
  const match = /[?&]xsec_token=([^&#]*)/.exec(href || "");
  return match && match[1] ? match[1] : null;
};

test("the page driver clicks the note's own card — it never navigates", async () => {
  // Assigning `location` would tear down the content script, the engine and the sweep with
  // it. The card click keeps the board (and this code) alive underneath the overlay.
  const { win, state } = fakeWindow({ links: ["/explore/NOTE-1?xsec_token=t", "/explore/NOTE-2"] });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  const opened = await driver.openNote({ sourceId: "NOTE-2", provenance: { rawMetadata: { noteId: "NOTE-2" } } });

  assert.equal(opened, true);
  assert.deepEqual(state.clicks, ["/explore/NOTE-2"]);
});

test("the board's TOKENLESS anchor comes first and must not win — the live 404, pinned", async () => {
  // The bug, exactly as the live board renders it. rednote answers 404 for a note URL with
  // no `xsec_token`, the board emits a tokenless anchor and a tokenised one for the same
  // note, and the tokenless one is FIRST in document order — so `querySelector` on the id
  // alone opened a 404 page for every note on the board.
  const { win, state } = fakeWindow({ links: LIVE_ANCHORS, pathname: `/board/${LIVE_BOARD_ID}` });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  const opened = await driver.openNote(noteItem(LIVE_NOTE_ID, { xsecToken: LIVE_TOKEN }));

  assert.equal(opened, true);
  assert.equal(state.clicks.length, 1);
  // The property, not the literal: whatever was clicked carries a usable token.
  assert.equal(tokenIn(state.clicks[0]), LIVE_TOKEN, "the note was opened without its token");
  assert.equal(state.clicks[0], LIVE_TOKENISED_HREF);
  assert.equal(state.clicks.includes(LIVE_NOTE_HREF), false, "document order won over the token");
});

test("an empty xsec_source does not disqualify the anchor that carries the token", async () => {
  // The live href ends `&xsec_source=` — empty. `xsec_source` says where the reader came
  // from (empty from a board card, `pc_user` from a hand-opened note) and varies; only the
  // token decides whether the URL opens. A usability test that reached for the source would
  // reject the one anchor that works and fall back to the 404.
  const { win, state } = fakeWindow({ links: LIVE_ANCHORS });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  await driver.openNote(noteItem(LIVE_NOTE_ID));

  assert.ok(state.clicks[0].includes("xsec_source="));
  assert.equal(tokenIn(state.clicks[0]), LIVE_TOKEN);
});

test("all THREE note routes are opened through their tokenised anchor — the id is the match", async () => {
  // A note is reachable at `/explore/<id>`, at `/discovery/item/<id>` (observed live, with
  // `xsec_source=pc_user`) and at `/board/<board>/<id>` (what the board card renders). The
  // driver matches the id ANYWHERE in the href on purpose: narrowing to a route would fail
  // silently the day the SPA picks a different one. Each shape is paired with its tokenless
  // twin, first, so the token — not the route and not the order — is what is being asserted.
  const routes = [
    `/explore/${LIVE_NOTE_ID}`,
    `/discovery/item/${LIVE_NOTE_ID}`,
    `/board/${LIVE_BOARD_ID}/${LIVE_NOTE_ID}`,
  ];
  for (const [index, route] of routes.entries()) {
    const source = index === 1 ? "pc_user" : "";
    const tokenised = `${route}?xsec_token=${LIVE_TOKEN}&xsec_source=${source}`;
    const { win, state } = fakeWindow({ links: [route, tokenised] });
    const driver = createPageNoteDriver({ win, sleep: async () => {} });

    assert.equal(await driver.openNote(noteItem(LIVE_NOTE_ID)), true, route);
    assert.deepEqual(state.clicks, [tokenised], route);
  }
});

test("a tokenised anchor wins wherever it sits, and an EMPTY token is not a token", async () => {
  // `xsec_token=` with nothing after it is the tokenless case wearing the parameter's name.
  const { win, state } = fakeWindow({
    links: [
      `/board/${LIVE_BOARD_ID}/${LIVE_NOTE_ID}?xsec_token=&xsec_source=`,
      `/explore/${LIVE_NOTE_ID}`,
      `/explore/${LIVE_NOTE_ID}?xsec_token=${LIVE_TOKEN}`,
    ],
  });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  await driver.openNote(noteItem(LIVE_NOTE_ID));

  assert.equal(tokenIn(state.clicks[0]), LIVE_TOKEN);
});

test("a note whose ONLY anchor is tokenless is still opened — and the shape change is logged", async () => {
  // Refusing here would report `no_note_card` for a card that is plainly on the page, and
  // would lose every note the day rednote stops rendering the tokenised anchor. A 404 that
  // degrades (and times out into `reasons.timeout`) is the better failure, but it is not
  // silent: the log line is the only warning a live run would get.
  const lines = [];
  const { win, state } = fakeWindow({ links: [`/explore/${LIVE_NOTE_ID}`] });
  const driver = createPageNoteDriver({ win, sleep: async () => {}, log: (...args) => lines.push(args.join(" ")) });

  assert.equal(await driver.openNote(noteItem(LIVE_NOTE_ID)), true);
  assert.deepEqual(state.clicks, [`/explore/${LIVE_NOTE_ID}`]);
  assert.equal(lines.some((line) => line.includes("xsec_token")), true,
    "a tokenless open passed without a word");
});

test("the item's xsec_token is NEVER interpolated into a selector — only the guarded id is", async () => {
  // A token contains `=` and `-`, comes off a page response, and would break out of an
  // attribute selector if it were ever spliced into one. The filtering is done in JS for
  // that reason, so the only thing the document is ever asked for is the id — which the
  // guard above has already cleared.
  const hostile = 'x"] , a[href*="';
  const { win, state } = fakeWindow({ links: [`/explore/${LIVE_NOTE_ID}?xsec_token=${LIVE_TOKEN}`] });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  await driver.openNote(noteItem(LIVE_NOTE_ID, { xsecToken: hostile }));

  assert.deepEqual(state.selectors, [`a[href*="${LIVE_NOTE_ID}"]`]);
  for (const selector of state.selectors) {
    assert.equal(selector.includes(hostile), false);
    assert.equal(selector.includes("xsec_token"), false);
  }
});

test("the page driver reports FALSE when the note's card is not on the page", async () => {
  const { win, state } = fakeWindow({ links: ["/explore/NOTE-1"] });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  assert.equal(await driver.openNote({ sourceId: "NOTE-404", provenance: { rawMetadata: { noteId: "NOTE-404" } } }), false);
  assert.deepEqual(state.clicks, []);
});

test("the page driver refuses an id that is not id-shaped rather than building a selector from it", async () => {
  // The dangerous breakout is not a selector that fails to parse — `querySelectorAll` throws
  // on those and the driver already catches it. It is a VALID one: an id that closes the
  // attribute and opens a second term steers the click at an anchor of the attacker's
  // choosing, and clicking a profile link is a real navigation off the board, which is the
  // one thing this whole driver exists not to do.
  const { win, state } = fakeWindow({
    links: ["/user/profile/65d3e54f000000000503359d", `/explore/${LIVE_NOTE_ID}`],
  });
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  for (const hostile of ['"] , a[href*="', 'x"], a[href*="/user/profile', '"]']) {
    assert.equal(await driver.openNote(noteItem(hostile)), false, hostile);
  }
  assert.deepEqual(state.clicks, []);
  assert.deepEqual(state.selectors, [], "a non-id never reached the document at all");
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

test("the routed-note close covers every note route, and the BOARD page is not one", async () => {
  // The history fallback fires only when the SPA navigated instead of overlaying, and it
  // used to ask `/explore/` alone — which the live board never matches, because a board
  // card routes to `/board/<board_id>/<note_id>`. Asserted through the same
  // `rednoteNoteId` the extractor uses, so the two cannot drift apart again.
  const routed = [
    `/explore/${LIVE_NOTE_ID}`,
    `/discovery/item/${LIVE_NOTE_ID}`,
    `/board/${LIVE_BOARD_ID}/${LIVE_NOTE_ID}`,
  ];
  for (const pathname of routed) {
    const { win, state } = fakeWindow({ links: [], pathname });
    await createPageNoteDriver({ win, sleep: async () => {} }).closeNote();
    assert.equal(state.back, 1, pathname);
    assert.deepEqual(state.scrolled, [0], `${pathname}: the board scroll is restored either way`);
  }

  // The board itself, and a board sub-route whose tail is not a note id: nothing to pop,
  // and popping would take the sweep off the board it is halfway through.
  for (const pathname of [`/board/${LIVE_BOARD_ID}`, `/board/${LIVE_BOARD_ID}/edit`]) {
    const { win, state } = fakeWindow({ links: [], pathname });
    await createPageNoteDriver({ win, sleep: async () => {} }).closeNote();
    assert.equal(state.back, 0, pathname);
  }
});

test("the page driver never throws into the sweep, whatever the page does", async () => {
  const win = {
    document: { querySelectorAll: () => { throw new Error("detached document"); } },
    location: { pathname: "/board/abc" },
  };
  const driver = createPageNoteDriver({ win, sleep: async () => {} });

  assert.equal(await driver.openNote({ sourceId: "NOTE-1", provenance: { rawMetadata: { noteId: "NOTE-1" } } }), false);
  await driver.closeNote();   // no KeyboardEvent, no history, no scrollTo — and no throw
});

// MARK: - the live FEED RESET driver (changelog 494)
//
// 493 refuses a sweep that cannot prove it holds the board feed's opening slice, because the
// feed pages FORWARD only and no scroll walks back. This is the other half: the sweep puts
// the feed back at its start itself.
//
// The sequence is not invented here. Verified in the user's browser on 2026-09-14, on a
// mid-scrolled board, with the hook logging each board-feed request url:
//
//     [req] cursor= "6a804923000000002c001f0c"   <- from scrolling
//     [req] cursor= ""                            <- after navigating BACK to the board
//
// Forward to another SPA route, then browser-BACK. The pair is the mechanism; neither leg
// alone is. These tests hold the driver to that pair, and to the two things it must never do
// — navigate away for real, or touch the history from a state it has not verified.

/** The live board's profile href, and where the SPA routes when it is clicked. */
const PROFILE_HREF = "/user/profile/65d3e54f000000000503359d";
const PROFILE_ROUTE = "/user/profile/65d3e54f000000000503359d";
const BOARD_ROUTE = `/board/${LIVE_BOARD_ID}`;

/**
 * The live board's anchors, with the NOTE cards in front of the profile link.
 *
 * Document order is the thing being taken away here. The board the sequence was verified on
 * happened to render its profile link first — so a driver that simply clicked the first
 * anchor on the page, or the first one whose href mentions a profile, would pass every test
 * below on that board and open a NOTE on any board that lays out the other way round.
 * Opening a note is not an away leg: it overlays, the pathname may not change at all, and
 * the back that follows is then a back from a state nobody verified.
 */
const RESET_ANCHORS = [
  LIVE_NOTE_HREF,
  LIVE_TOKENISED_HREF,
  // A substring match selects this one too — an anchor that MENTIONS a profile route on its
  // way somewhere else. Clicking it navigates, so the click check would pass; the back would
  // then land on a login page rather than the board.
  `/login?redirect=${PROFILE_HREF}`,
  ...LIVE_ANCHORS.filter((href) => href.startsWith("/user/profile/")),
];

/** A board page whose profile anchor really routes. */
const resettableBoard = (overrides = {}) => fakeWindow({
  links: RESET_ANCHORS,
  pathname: BOARD_ROUTE,
  routes: { [PROFILE_HREF]: PROFILE_ROUTE, [`/login?redirect=${PROFILE_HREF}`]: "/login" },
  ...overrides,
});

test("the feed reset drives the board AWAY through its own profile link and BACK again", async () => {
  // The live pair, in order: a click on an anchor the page rendered, then a history back.
  // The order is asserted, not just the counts — a back before the forward leg is the
  // "history.back() from an unknown state" that pops the board itself off the stack.
  const { win, state, log } = resettableBoard();
  const reset = createPageFeedResetter({ win, sleep: async () => {}, log });

  assert.equal(await reset(), true);
  assert.equal(state.clicks.length, 1);
  assert.equal(state.clicks[0], PROFILE_HREF,
    "the away leg must be the board's own profile ROUTE — not the first anchor, and not an "
    + "anchor that merely mentions one");
  assert.equal(state.back, 1, "the BACK is what makes the board refetch — a click alone does not");
  assert.ok(state.order.indexOf(`click:${PROFILE_HREF}`) < state.order.indexOf("back"),
    "the back ran before the forward navigation it is supposed to undo");
  assert.equal(win.location.pathname, BOARD_ROUTE, "the sweep must be left on the board it is sweeping");
});

test("the feed reset NEVER navigates — no location assignment, no window.open", async () => {
  // The whole reason a reload is not on the table: a board page is the sweep's own host
  // document, so a real navigation tears down the content script, the engine and the sweep.
  // Clicking the SPA's anchor keeps all three alive, which is why it is the only lever here.
  const { win, state, log } = resettableBoard();

  await createPageFeedResetter({ win, sleep: async () => {}, log })();

  assert.deepEqual(state.navigations, []);
});

test("the reset leaves the viewport at the TOP, and does not let the browser put it back", async () => {
  // A back navigation restores the offset the board had when it was left — halfway down the
  // grid, which is exactly where the SPA's infinite scroll would fetch the NEXT page from,
  // defeating the refetch the reset exists to cause. So the restoration is pinned MANUAL
  // across the navigation and released afterwards, and the viewport is put at 0.
  const { win, state, log } = resettableBoard();

  assert.equal(await createPageFeedResetter({ win, sleep: async () => {}, log })(), true);

  assert.deepEqual(state.scrolled, [0], "the sweep pages from where the reset left the viewport");
  assert.ok(state.order.indexOf("back") < state.order.lastIndexOf("scroll:0"),
    "the scroll must be put at the top AFTER the navigation, or the navigation overwrites it");
  assert.equal(state.restoration[0], "manual", "the browser was left free to restore the old offset");
  assert.equal(win.history.scrollRestoration, "auto",
    "the page's own scrollRestoration was not put back — the reset kept a setting that is not its own");
});

test("a board with no /user/profile/ anchor degrades to the guard instead of improvising", async () => {
  // An empty board, or a layout that stopped rendering one. There is no away leg, so there
  // is no pair — and a lone `history.back()` from here is the unknown state. Reporting false
  // hands the sweep to 493's refusal, which tells the user to reload the board.
  const { win, state, log } = fakeWindow({ links: [LIVE_NOTE_HREF], pathname: BOARD_ROUTE });

  assert.equal(await createPageFeedResetter({ win, sleep: async () => {}, log })(), false);
  assert.deepEqual(state.clicks, []);
  assert.equal(state.back, 0, "it went back without ever having gone forward");
  assert.ok(state.log.some((line) => line.includes("/user/profile/")), "the degradation passed without a word");
});

test("a click that does NOT route leaves the history alone — the board is still on top of it", async () => {
  // THE dangerous case, and the reason the forward leg is verified rather than assumed. If
  // the click did not navigate (an overlay, an intercepted anchor, a different build), the
  // top of the history stack is still the board — so `history.back()` would pop the BOARD
  // off and land the sweep on whatever the user was looking at before it.
  const { win, state, log } = fakeWindow({
    links: RESET_ANCHORS, pathname: BOARD_ROUTE, routes: {},   // clicking routes nowhere
  });

  assert.equal(await createPageFeedResetter({ win, sleep: async () => {}, log })(), false);
  assert.equal(state.clicks.length, 1, "the away leg was still attempted");
  assert.equal(state.back, 0, "a back was issued from a state the driver had not verified");
  assert.equal(win.location.pathname, BOARD_ROUTE);
});

test("a back that lands somewhere other than the board is reported, not retried", async () => {
  // An SPA that pushed two entries for one route change, or a redirect: one back pops past
  // the board. Nothing is retried — a second blind back is the same unknown state one step
  // further away — so the sweep falls into 493's refusal, whose advice (reload the board
  // page) repairs this too.
  const { win, state, log } = fakeWindow({
    links: RESET_ANCHORS,
    pathname: BOARD_ROUTE,
    under: "/explore",                                      // what sits beneath the board
    routes: { [PROFILE_HREF]: PROFILE_ROUTE },
    backSteps: 2,
  });

  assert.equal(await createPageFeedResetter({ win, sleep: async () => {}, log })(), false);
  assert.equal(state.back, 1, "the recovery improvised a second back from an unknown state");
  assert.equal(win.location.pathname, "/explore");
  assert.ok(state.log.some((line) => line.includes("not the board")), "landing off the board passed silently");
});

test("the feed reset never throws into the sweep, whatever the page does", async () => {
  // Same contract as the note driver's: a page that will not be driven is a degradation the
  // caller reports, never an exception into the enumeration.
  const hostile = {
    document: { querySelectorAll: () => { throw new Error("detached document"); } },
  };
  assert.equal(await createPageFeedResetter({ win: hostile, sleep: async () => {} })(), false);
  assert.equal(await createPageFeedResetter({ win: {}, sleep: async () => {} })(), false);
  assert.equal(await createPageFeedResetter({ win: null, sleep: async () => {} })(), false);
});
