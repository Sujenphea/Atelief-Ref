// Atelier Capture — rednote board-feed parser (098 T2).
//
// Driven by the LIVE captures of 2026-09-13 wherever a real shape exists, because every
// interesting property of this parser is a fact about rednote's data rather than about
// our code: `cover.url` is empty on every row, `cover.file_id` is empty on every row, the
// terminator is `cursor: ""`, and the author field is spelled two different ways on two
// different endpoints. A hand-written fixture would have had none of those.

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

import {
  BOARD_FEED_PATH, RednoteChallengeError, boardIdFromRequestURL, cursorFromRequestURL,
  detectRednoteChallenge, isBoardFeedRequest, mapBoardNote, matchesScope,
  parseBoardFeedPage, pickRednoteImage, rednoteAuthor,
} from "../src/bulk-rednote.js";

/** The live capture, when it is present. It lives in the gitignored `resources/` until
 * T4 sanitizes it into a committed fixture, so these tests SKIP rather than fail on a
 * fresh clone — but they must not skip silently on the machine that has it. */
const LIVE = new URL("../../resources/rednote-board-page2.json", import.meta.url);
const live = existsSync(LIVE) ? JSON.parse(readFileSync(LIVE, "utf8")) : null;
const withLive = (name, fn) => test(name, { skip: live ? false : "no live capture" }, fn);

/** The real envelope, minimally reconstructed for the cases the capture cannot show. */
const feed = (notes, { hasMore = true, cursor = "abc123" } = {}) =>
  ({ code: 0, success: true, msg: "成功", data: { has_more: hasMore, notes, cursor } });

/** A row with the real key names and the real "empty string means absent" convention. */
const row = (over = {}) => ({
  note_id: "n1", type: "normal", display_title: "A title", xsec_token: "tok-1",
  user: { user_id: "u1", nick_name: "Someone", avatar: "a", xsec_token: "utok" },
  cover: {
    file_id: "", url: "", width: 900, height: 1200, trace_id: "",
    url_pre: "http://sns-web-i10.rednotecdn.com/2026/sigA/keyA!nc_n_webp_prv_1",
    url_default: "http://sns-web-i10.rednotecdn.com/2026/sigB/keyA!nc_n_webp_mw_1",
    info_list: [
      { image_scene: "WB_PRV", url: "http://sns-web-i10.rednotecdn.com/2026/sigA/keyA!nc_n_webp_prv_1" },
      { image_scene: "WB_DFT", url: "http://sns-web-i10.rednotecdn.com/2026/sigB/keyA!nc_n_webp_mw_1" },
    ],
  },
  ...over,
});

// MARK: - request-URL readers (the protocol-relative form)

test("reads the cursor and board id off a PROTOCOL-RELATIVE request url", () => {
  // This is verbatim what the XHR path reports. `new URL()` throws on it without a base,
  // so a reader written the obvious way silently returns null for every page.
  const url = "//webapi.rednote.com/api/sns/web/v1/board/note"
    + "?board_id=69322476000000001202811f&num=30&cursor=6a79628500000000330086d8&image_formats=jpg,webp,avif";
  assert.equal(cursorFromRequestURL(url), "6a79628500000000330086d8");
  assert.equal(boardIdFromRequestURL(url), "69322476000000001202811f");
});

test("the absolute form reads identically, and garbage reads as null", () => {
  const url = `https://webapi.rednote.com${BOARD_FEED_PATH}?board_id=bd1&cursor=c1`;
  assert.equal(cursorFromRequestURL(url), "c1");
  assert.equal(boardIdFromRequestURL(url), "bd1");
  for (const bad of ["not a url", "", null, undefined]) {
    assert.equal(cursorFromRequestURL(bad), null);
    assert.equal(boardIdFromRequestURL(bad), null);
  }
});

test("an EMPTY cursor param reads as absent, not as a cursor", () => {
  // The live last page requests/reports `cursor=""`. Treating it as a value is the
  // infinite-loop bug this whole convention exists to prevent.
  assert.equal(cursorFromRequestURL(`https://webapi.rednote.com${BOARD_FEED_PATH}?cursor=`), null);
});

test("isBoardFeedRequest matches the feed path only — never the adjacent telemetry hosts", () => {
  assert.equal(isBoardFeedRequest(`//webapi.rednote.com${BOARD_FEED_PATH}?board_id=1`), true);
  assert.equal(isBoardFeedRequest(`https://webapi.rednote.com${BOARD_FEED_PATH}`), true);
  // Real traffic seen alongside the feed during the live probe. Matching on host would
  // swallow these; matching on path does not.
  assert.equal(isBoardFeedRequest("https://t2.rnote.com/api/v2/collect"), false);
  assert.equal(isBoardFeedRequest("https://apm-fe.rnote.com/api/data"), false);
  assert.equal(isBoardFeedRequest("//as.rednote.com/api/sec/v1/shield/webprofile"), false);
  assert.equal(isBoardFeedRequest("https://webapi.rednote.com/api/sns/web/v2/comment/page"), false);
  assert.equal(isBoardFeedRequest(null), false);
});

// MARK: - scope (replay-buffer contamination between boards)

test("matchesScope keeps this board's pages and drops another board's", () => {
  const url = (id) => `//webapi.rednote.com${BOARD_FEED_PATH}?board_id=${id}&cursor=c`;
  assert.equal(matchesScope(url("bd1"), "board:bd1"), true);
  assert.equal(matchesScope(url("bd2"), "board:bd1"), false);
});

test("matchesScope DROPS anything it cannot verify", () => {
  // Mirrors X: an unknown scope is never worth the risk of sweeping the wrong feed.
  assert.equal(matchesScope(`//webapi.rednote.com${BOARD_FEED_PATH}?num=30`, "board:bd1"), false);
  assert.equal(matchesScope("https://t2.rnote.com/api/v2/collect", "board:bd1"), false);
  assert.equal(matchesScope("not a url", "board:bd1"), false);
  assert.equal(matchesScope(`//webapi.rednote.com${BOARD_FEED_PATH}?board_id=bd1`, null), false);
});

// MARK: - the author trap

test("rednoteAuthor reads BOTH spellings — nick_name (feed) and nickname (detail)", () => {
  // The same product spells it differently on two endpoints. Reading one silently yields
  // a null author on the other, and a null author fails nothing loudly (098 D6).
  assert.equal(rednoteAuthor({ nick_name: "Feed Name", user_id: "u1" }).name, "Feed Name");
  assert.equal(rednoteAuthor({ nickname: "Detail Name", user_id: "u1" }).name, "Detail Name");
  assert.equal(rednoteAuthor({}).name, null);
  assert.equal(rednoteAuthor(null).name, null);
  // rednote publishes no username at all, so a handle would be an invention.
  assert.equal(rednoteAuthor({ nick_name: "x" }).handle, null);
  assert.equal(rednoteAuthor({ user_id: 12345 }).userId, "12345");
});

// MARK: - image selection

test("pickRednoteImage prefers the DEFAULT rendering and keeps the signed url as fallback", () => {
  const { mediaUrl, mediaUrlFallback } = pickRednoteImage(row().cover);
  assert.equal(mediaUrl, "http://sns-i27.rednotecdn.com/keyA");
  // sigB is url_default — the default rendering wins over the preview.
  assert.equal(mediaUrlFallback, "http://sns-web-i10.rednotecdn.com/2026/sigB/keyA!nc_n_webp_mw_1");
});

test("pickRednoteImage survives cover.url being the empty string on every row", () => {
  // The single most likely way a first implementation ingests nothing: `cover.url` is the
  // obvious field and it is `""` on 37/37 live rows.
  const cover = { ...row().cover, url: "" };
  assert.ok(pickRednoteImage(cover).mediaUrl, "an empty cover.url must not mean no image");
});

test("pickRednoteImage falls back through info_list when the direct fields are missing", () => {
  const cover = {
    url: "", url_pre: "", url_default: "",
    info_list: [{ image_scene: "WB_DFT", url: "http://sns-web-i10.rednotecdn.com/2026/sig/keyZ!x" }],
  };
  assert.equal(pickRednoteImage(cover).mediaUrl, "http://sns-i27.rednotecdn.com/keyZ");
});

test("pickRednoteImage reports nothing usable rather than inventing a url", () => {
  for (const empty of [null, undefined, {}, { url: "", info_list: [] }, { info_list: "nope" }]) {
    assert.deepEqual(pickRednoteImage(empty), { mediaUrl: null, mediaUrlFallback: null });
  }
});

test("pickRednoteImage serves a note-detail image_list entry — the SAME shape as a cover", () => {
  // Verbatim from the live detail capture, including the multi-segment key.
  const entry = {
    live_photo: false, height: 1660, width: 1242, url: "", stream: {},
    file_id: "oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg", trace_id: "",
    url_pre: "http://sns-web-i10.rednotecdn.com/202609131347/9b18d6eb/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg!nd_prv_wlteh_webp_3",
    url_default: "http://sns-web-i10.rednotecdn.com/202609131347/0bdf3366/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg!nd_dft_wlteh_webp_3",
    info_list: [],
  };
  assert.equal(
    pickRednoteImage(entry).mediaUrl,
    "http://sns-i27.rednotecdn.com/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg");
});

// MARK: - row mapping

test("mapBoardNote produces a cover-keyed BulkItem with rednote provenance", () => {
  const item = mapBoardNote(row(), { host: "www.rednote.com", cursor: "cur1" });
  assert.equal(item.sourceId, "n1");
  assert.equal(item.cursor, "cur1");
  assert.equal(item.mediaUrl, "http://sns-i27.rednotecdn.com/keyA");
  assert.equal(item.provenance.platform, "rednote");
  assert.equal(item.provenance.originalURL, "https://www.rednote.com/explore/n1");
  assert.equal(item.provenance.authorName, "Someone");
  assert.equal(item.provenance.title, "A title");
  assert.deepEqual(item.provenance.rawMetadata, {
    noteId: "n1", kind: "image", userId: "u1", width: 900, height: 1200,
  });
});

test("the xsec_token rides as a LOCAL field and never enters stored provenance", () => {
  const item = mapBoardNote(row());
  // K3b needs it during the sweep; nothing needs it afterwards, and a stored one is a
  // dead credential. Same rule the single-capture path applies by stripping it from the
  // permalink.
  assert.equal(item.xsecToken, "tok-1");
  assert.equal(JSON.stringify(item.provenance).includes("tok-1"), false);
  assert.equal(item.provenance.originalURL.includes("xsec_token"), false);
});

test("a video row is marked as video — its cover is only a poster still", () => {
  assert.equal(mapBoardNote(row({ type: "video" })).provenance.rawMetadata.kind, "video");
});

test("mapBoardNote drops a row with no id or no usable cover, rather than enqueueing a doomed item", () => {
  assert.equal(mapBoardNote(row({ note_id: null })), null);
  assert.equal(mapBoardNote(row({ cover: { url: "", url_pre: "", url_default: "", info_list: [] } })), null);
  assert.equal(mapBoardNote(null), null);
  assert.equal(mapBoardNote("nope"), null);
});

// MARK: - page parsing + the terminator

test("parseBoardFeedPage maps every row and stamps them with the page's next cursor", () => {
  const page = parseBoardFeedPage(feed([row({ note_id: "a" }), row({ note_id: "b" })], { cursor: "next1" }));
  assert.equal(page.error, null);
  assert.deepEqual(page.items.map((i) => i.sourceId), ["a", "b"]);
  assert.equal(page.cursor, "next1");
  assert.deepEqual([...new Set(page.items.map((i) => i.cursor))], ["next1"]);
  assert.equal(page.endOfFeed, false);
});

test("the LIVE terminator ends the feed: has_more false, notes [], cursor \"\"", () => {
  // Captured verbatim 2026-09-13 from the last page of a real board.
  const last = { code: 0, success: true, msg: "成功", data: { has_more: false, notes: [], cursor: "" } };
  const page = parseBoardFeedPage(last);
  assert.equal(page.error, null, "an exhausted feed is not a refusal");
  assert.deepEqual(page.items, []);
  assert.equal(page.endOfFeed, true);
  assert.equal(page.cursor, null);
});

test("an empty cursor ends the feed EVEN IF has_more is still true", () => {
  // The loop guard. Doc 020 recorded has_more staying optimistically true; Instagram's
  // `next_max_id != null` idiom would read "" as live and page forever.
  assert.equal(parseBoardFeedPage(feed([row()], { hasMore: true, cursor: "" })).endOfFeed, true);
  assert.equal(parseBoardFeedPage(feed([row()], { hasMore: true, cursor: null })).endOfFeed, true);
});

test("a page of rows that all fail to map is empty but NOT a challenge", () => {
  // Distinguishing "rednote refused us" from "these rows had no cover" matters: the first
  // halts the sweep, the second must not.
  const page = parseBoardFeedPage(feed([row({ note_id: null }), row({ note_id: null })]));
  assert.equal(page.error, null);
  assert.deepEqual(page.items, []);
  assert.equal(page.endOfFeed, false);
});

// MARK: - the challenge detector (halt, don't burn)

test("a healthy page does NOT trip the challenge detector", () => {
  assert.equal(detectRednoteChallenge(feed([row()])), null);
  assert.equal(detectRednoteChallenge({ code: 0, success: true, data: { has_more: false, notes: [], cursor: "" } }), null);
});

test("the observed 461 shape IS caught — a refusal wearing a success shape", () => {
  // The 2026-09-13 signing experiment returned HTTP 461 with `success: true, code: 0,
  // msg: ""` where every genuine response says `成功`. The hook forwards status-blind, so
  // the missing `data.notes` array is what has to carry the signal.
  const refusal = { code: 0, success: true, msg: "" };
  assert.equal(detectRednoteChallenge(refusal), "no_feed_payload");
});

test("a non-zero code, an explicit failure, and a garbage body are all challenges", () => {
  assert.equal(detectRednoteChallenge({ code: 300012, success: false, data: {} }), "code_300012");
  assert.equal(detectRednoteChallenge({ code: 0, success: false, data: { notes: [] } }), "request_failed");
  assert.equal(detectRednoteChallenge({ code: 0, success: true, data: { notes: "nope" } }), "no_feed_payload");
  assert.equal(detectRednoteChallenge(null), "unparseable");
  assert.equal(detectRednoteChallenge("<html>"), "unparseable");
});

test("parseBoardFeedPage RETURNS the challenge as `error` and never throws it", () => {
  // A throw from parsePage is swallowed by intercept-source as an unparseable capture,
  // which for a challenge means quietly sweeping on against a flagged account (098 R10).
  const page = parseBoardFeedPage({ code: 461, success: true, msg: "" });
  assert.ok(page.error instanceof RednoteChallengeError);
  assert.equal(page.error.challenge, true);
  assert.equal(page.error.kind, "code_461");
  assert.deepEqual(page.items, []);
  assert.equal(page.endOfFeed, false, "a refusal is not an end — the feed is unfinished");
});

// MARK: - against the live capture

withLive("the live board page parses to one item per note, all distinct", () => {
  const page = parseBoardFeedPage(live, { host: "www.rednote.com" });
  const notes = live.data.notes;
  assert.equal(page.error, null);
  // K3a is one item per NOTE, not per image — the feed carries no image list to fan out.
  assert.equal(page.items.length, notes.length, `expected ${notes.length} items`);
  assert.equal(new Set(page.items.map((i) => i.sourceId)).size, notes.length, "no key collisions");
  assert.equal(page.items.every((i) => i.mediaUrl), true, "every note yielded a cover");
  assert.equal(page.endOfFeed, false, "this capture is a middle page");
});

withLive("every live cover resolves to an UNSIGNED original with a signed fallback", () => {
  const page = parseBoardFeedPage(live);
  for (const item of page.items) {
    assert.match(item.mediaUrl, /^http:\/\/sns-i27\.rednotecdn\.com\//, item.mediaUrl);
    assert.equal(item.mediaUrl.includes("!"), false, "no transform suffix survives");
    assert.ok(item.mediaUrlFallback, "the signed url is kept — the bare original can 404");
    assert.notEqual(item.mediaUrl, item.mediaUrlFallback);
  }
});

withLive("every live row yields an author name and a title, and no token leaks", () => {
  const page = parseBoardFeedPage(live);
  assert.equal(page.items.every((i) => i.provenance.authorName), true, "nick_name read");
  assert.equal(page.items.every((i) => i.provenance.title), true, "display_title read");
  assert.equal(page.items.every((i) => i.xsecToken), true, "the token is available to K3b");
  const serialized = JSON.stringify(page.items.map((i) => i.provenance));
  for (const item of page.items) {
    assert.equal(serialized.includes(item.xsecToken), false, "no xsec_token in provenance");
  }
});

withLive("the live capture's video-heavy mix is carried through to rawMetadata", () => {
  const page = parseBoardFeedPage(live);
  const kinds = page.items.reduce((acc, i) => {
    acc[i.provenance.rawMetadata.kind] = (acc[i.provenance.rawMetadata.kind] || 0) + 1;
    return acc;
  }, {});
  // 30 video / 7 normal in this capture. Asserted as a PROPERTY (both kinds present, video
  // dominant) rather than exact counts, so a re-captured fixture does not break the test.
  assert.ok(kinds.video > 0 && kinds.image > 0, `expected both kinds, got ${JSON.stringify(kinds)}`);
  assert.ok(kinds.video > kinds.image, "this board is video-heavy — K3a captures posters for those");
});
