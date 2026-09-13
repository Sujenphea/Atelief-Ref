// Atelier Capture — rednote board-feed parser (098 T2).
//
// Driven by the LIVE captures of 2026-09-13 wherever a real shape exists, because every
// interesting property of this parser is a fact about rednote's data rather than about
// our code: `cover.url` is empty on every row, `cover.file_id` is empty on every row, the
// terminator is `cursor: ""`, and the author field is spelled two different ways on two
// different endpoints. A hand-written fixture would have had none of those.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  BOARD_FEED_PATH, NOTE_DETAIL_PATH, RednoteChallengeError, boardIdFromRequestURL,
  cursorFromRequestURL, detectRednoteChallenge, detectRednoteDetailChallenge,
  isBoardFeedRequest, isNoteDetailRequest, mapBoardNote, mapNoteImage, matchesScope,
  mapNoteVideo, parseBoardFeedPage, parseNoteDetail, pickRednoteImage, rednoteAuthor,
  videoSourceId, VIDEO_SOURCE_SUFFIX,
} from "../src/bulk-rednote.js";
import { readVideoCandidates, STREAM_REFUSAL, videoCandidates } from "../src/rednote-video.js";
import { knownNoteIndex } from "../src/rednote-detail-client.js";

/** The live capture of 2026-09-13, sanitized into a COMMITTED fixture by 098 T4. It used
 * to be read out of the gitignored `resources/`, so the four tests below skipped on every
 * machine but one — which is the same thing as not having them. The sanitizer preserves
 * structure exactly (key names, nesting, array lengths, path depth, the `!transform`
 * suffix) and replaces only leaf values, so every property asserted here is still a
 * property of what rednote sent; the literal ids are synthetic and are never asserted. */
const LIVE = new URL("./fixtures/rednote-board-live.json", import.meta.url);
const live = JSON.parse(readFileSync(LIVE, "utf8"));

/** The real envelope, minimally reconstructed for the cases the capture cannot show. */
const feed = (notes, { hasMore = true, cursor = "abc123" } = {}) =>
  ({ code: 0, success: true, msg: "成功", data: { has_more: hasMore, notes, cursor } });

/** A row with the real key names and the real "empty string means absent" convention. */
const row = (over = {}) => ({
  note_id: "n1", type: "normal", display_title: "A title", xsec_token: "tok-1",
  user: { user_id: "u1", nick_name: "Someone", avatar: "a", xsec_token: "utok" },
  cover: {
    file_id: "", url: "", width: 900, height: 1200, trace_id: "",
    url_pre: "http://sns-web-i10.rednotecdn.com/202609131332/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/keyA!nc_n_webp_prv_1",
    url_default: "http://sns-web-i10.rednotecdn.com/202609131332/b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2/keyA!nc_n_webp_mw_1",
    info_list: [
      { image_scene: "WB_PRV", url: "http://sns-web-i10.rednotecdn.com/202609131332/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/keyA!nc_n_webp_prv_1" },
      { image_scene: "WB_DFT", url: "http://sns-web-i10.rednotecdn.com/202609131332/b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2/keyA!nc_n_webp_mw_1" },
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
  assert.equal(mediaUrlFallback, "http://sns-web-i10.rednotecdn.com/202609131332/b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2/keyA!nc_n_webp_mw_1");
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
    info_list: [{ image_scene: "WB_DFT", url: "http://sns-web-i10.rednotecdn.com/202609131332/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/keyZ!x" }],
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
    url_pre: "http://sns-web-i10.rednotecdn.com/202609131347/9b18d6eb1af3e2b0f7cb503690495580/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg!nd_prv_wlteh_webp_3",
    url_default: "http://sns-web-i10.rednotecdn.com/202609131347/0bdf336689816bd1691a3c351e3be0ab/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg!nd_dft_wlteh_webp_3",
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

/** A `/<timestamp>/<signature>/` prefix, by SHAPE — the thing `toRednoteOriginal` now
 * tests for, and the thing the sanitizer has to preserve. Depth is not enough: rednote's
 * unsigned `/stream/1/110/…` is five segments deep and must never be rewritten. */
function hasSigningPrefix(url) {
  const segments = new URL(url).pathname.split("/").filter(Boolean);
  return segments.length >= 3
    && /^\d{10,14}$/.test(segments[0]) && /^[0-9a-f]{32}$/i.test(segments[1]);
}

test("the live fixture still carries a SIGNED, multi-segment cover url", () => {
  // The fixture is only worth having if it still exercises the rewrite. A sanitizer that
  // flattened these paths, replaced the signing prefix with filler of the wrong shape, or
  // dropped the `!transform` suffix would leave every check below passing VACUOUSLY —
  // `toRednoteOriginal` returns an unsigned path untouched, so such a cover would "pass"
  // the unsigned-original assertion by never being rewritten at all. Asserted on the
  // INPUT, where a future re-capture (or a sanitizer change) would break it.
  for (const note of live.data.notes) {
    for (const url of [note.cover.url_pre, note.cover.url_default]) {
      const { hostname } = new URL(url);
      assert.notEqual(hostname, "sns-i27.rednotecdn.com", "a cover url must still be signed");
      assert.ok(hasSigningPrefix(url),
        `a signed cover needs <timestamp>/<signature>/<key>: ${url}`);
      assert.ok(url.includes("!"), `the transform suffix must survive sanitization: ${url}`);
    }
  }
});

test("the live board page parses to one item per note, all distinct", () => {
  const page = parseBoardFeedPage(live, { host: "www.rednote.com" });
  const notes = live.data.notes;
  assert.equal(page.error, null);
  // K3a is one item per NOTE, not per image — the feed carries no image list to fan out.
  assert.equal(page.items.length, notes.length, `expected ${notes.length} items`);
  assert.equal(new Set(page.items.map((i) => i.sourceId)).size, notes.length, "no key collisions");
  assert.equal(page.items.every((i) => i.mediaUrl), true, "every note yielded a cover");
  assert.equal(page.endOfFeed, false, "this capture is a middle page");
});

test("every live cover resolves to an UNSIGNED original with a signed fallback", () => {
  const page = parseBoardFeedPage(live);
  for (const item of page.items) {
    assert.match(item.mediaUrl, /^http:\/\/sns-i27\.rednotecdn\.com\//, item.mediaUrl);
    assert.equal(item.mediaUrl.includes("!"), false, "no transform suffix survives");
    assert.ok(item.mediaUrlFallback, "the signed url is kept — the bare original can 404");
    assert.notEqual(item.mediaUrl, item.mediaUrlFallback);
  }
});

test("every live row yields an author name and a title, and no token leaks", () => {
  const page = parseBoardFeedPage(live);
  assert.equal(page.items.every((i) => i.provenance.authorName), true, "nick_name read");
  assert.equal(page.items.every((i) => i.provenance.title), true, "display_title read");
  assert.equal(page.items.every((i) => i.xsecToken), true, "the token is available to K3b");
  // Compared as VALUES, not as substrings of the serialized page. A substring test on the
  // real capture happened to be safe; on the sanitized one the synthetic ids are
  // sequential, so `SAMPLE_TOKEN_3` is a substring of `SAMPLE_TOKEN_30` and every run
  // "found" a leak that was not there. The property being asserted was always "no
  // provenance field IS a token".
  const tokens = new Set(page.items.map((i) => i.xsecToken));
  const provenanceValues = new Set();
  (function collect(node) {
    if (Array.isArray(node)) return node.forEach(collect);
    if (node && typeof node === "object") return Object.values(node).forEach(collect);
    if (typeof node === "string") provenanceValues.add(node);
  })(page.items.map((i) => i.provenance));
  for (const token of tokens) {
    assert.equal(provenanceValues.has(token), false, "no xsec_token in provenance");
  }
});

test("the live capture's video-heavy mix is carried through to rawMetadata", () => {
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

// ===========================================================================
// K3b — note detail (098 T5a). Same module, same file: these exercise the SAME
// primitives (`pickRednoteImage`, `rednoteAuthor`, the challenge envelope) from the other
// endpoint, and the trap those primitives exist for — `nick_name` vs `nickname`,
// `data.notes` vs `data.items` — is only visible when both sides sit together.
// ===========================================================================

/** The note-detail capture of 2026-09-13, sanitized. One `normal` note, nine images. */
const DETAIL = new URL("./fixtures/rednote-note-detail.json", import.meta.url);
const detailLive = JSON.parse(readFileSync(DETAIL, "utf8"));

/** One `image_list[]` entry with the real key names and the real key SHAPE — the signed
 * path is `<timestamp>/<signature>/oss-sg/spectrum/<id>`, five segments, so the drop-two
 * rule has a multi-segment key to get right. `n` makes each entry a distinct image. */
const detailImage = (n, over = {}) => ({
  live_photo: false, height: 1660, width: 1242, url: "", stream: {}, trace_id: "",
  file_id: `oss-sg/spectrum/key${n}`,
  url_pre: `http://sns-web-i10.rednotecdn.com/202609131332/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/oss-sg/spectrum/key${n}!nd_prv_wlteh_webp_3`,
  url_default: `http://sns-web-i10.rednotecdn.com/202609131332/b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2/oss-sg/spectrum/key${n}!nd_dft_wlteh_webp_3`,
  info_list: [],
  ...over,
});

/** A `note_card` with every key the live capture carries. */
const card = (over = {}) => ({
  note_id: "nd1", type: "normal", title: "A note title", desc: "A long description",
  time: 1788832110000, last_update_time: 1789099181000, ip_location: "somewhere",
  // The DETAIL spelling. The feed's `nick_name` would read as a null author here.
  user: { user_id: "u9", nickname: "Detail Name", avatar: "a", xsec_token: "utok" },
  image_list: [detailImage(1), detailImage(2), detailImage(3)],
  tag_list: [], at_user_list: [], share_info: {}, interact_info: {}, note_translation: {},
  ...over,
});

/** The real detail envelope: `data.items[]`, each item wrapping one `note_card`. */
const detail = (noteCard, { items } = {}) => ({
  code: 0, success: true, msg: "成功",
  data: {
    cursor_score: "", current_time: 1789278454517,
    items: items !== undefined ? items
      : [{ id: "nd1", model_type: "note", note_card: noteCard, ignore: false }],
  },
});

// MARK: - the detail route

test("isNoteDetailRequest matches the detail POST and nothing that merely starts like it", () => {
  assert.equal(isNoteDetailRequest(`https://webapi.rednote.com${NOTE_DETAIL_PATH}`), true);
  assert.equal(isNoteDetailRequest(`//webapi.rednote.com${NOTE_DETAIL_PATH}/`), true);
  assert.equal(isNoteDetailRequest(`//webapi.rednote.com${NOTE_DETAIL_PATH}?x=1`), true);
  // The routes that would slip past a prefix match. A homefeed page handed to
  // `parseNoteDetail` has no `note_card` to read and would degrade every note it touched.
  assert.equal(isNoteDetailRequest(`https://webapi.rednote.com${NOTE_DETAIL_PATH}/homefeed`), false);
  assert.equal(isNoteDetailRequest("https://webapi.rednote.com/api/sns/web/v1/feedback"), false);
  // And the two matchers must not overlap in either direction.
  assert.equal(isNoteDetailRequest(`https://webapi.rednote.com${BOARD_FEED_PATH}?board_id=1`), false);
  assert.equal(isBoardFeedRequest(`https://webapi.rednote.com${NOTE_DETAIL_PATH}`), false);
  assert.equal(isNoteDetailRequest(null), false);
});

// MARK: - the shared challenge envelope, specialised per payload

test("the two challenge recognizers share every envelope rule and differ ONLY in the payload", () => {
  // The generalisation is only safe if it did not blur the two: a board page is not a
  // detail payload and a detail payload is not a board page, and each recognizer must say
  // so. A single `data.notes || data.items` check would pass both and is the defect this
  // pins against.
  const boardPage = { code: 0, success: true, data: { has_more: true, notes: [], cursor: "" } };
  const detailPage = detail(card());
  assert.equal(detectRednoteChallenge(boardPage), null);
  assert.equal(detectRednoteDetailChallenge(boardPage), "no_feed_payload");
  assert.equal(detectRednoteDetailChallenge(detailPage), null);
  assert.equal(detectRednoteChallenge(detailPage), "no_feed_payload");
  // Every rule ABOVE the payload check applies identically to both.
  for (const detect of [detectRednoteChallenge, detectRednoteDetailChallenge]) {
    assert.equal(detect({ code: 461, success: true, msg: "" }), "code_461");
    assert.equal(detect({ code: 0, success: false, data: { notes: [], items: [] } }), "request_failed");
    assert.equal(detect(null), "unparseable");
    assert.equal(detect("<html>"), "unparseable");
  }
});

test("the 461-shaped refusal is caught on the DETAIL endpoint too", () => {
  // `success: true, code: 0, msg: ""` with no payload — the shape the signing experiment
  // actually got back, and the detail POST is the request that produced it.
  assert.equal(detectRednoteDetailChallenge({ code: 0, success: true, msg: "" }), "no_feed_payload");
});

// MARK: - the per-image fan-out

test("parseNoteDetail fans out ONE item per image_list entry, keyed <note_id>:<index>", () => {
  const page = parseNoteDetail(detail(card()), { host: "www.rednote.com" });
  assert.equal(page.error, null);
  assert.equal(page.unsupported, null);
  assert.equal(page.noteId, "nd1");
  assert.deepEqual(page.items.map((i) => i.sourceId), ["nd1:0", "nd1:1", "nd1:2"]);
  assert.equal(new Set(page.items.map((i) => i.mediaUrl)).size, 3, "three distinct images");
  for (const item of page.items) {
    assert.equal(item.provenance.platform, "rednote");
    assert.equal(item.provenance.originalURL, "https://www.rednote.com/explore/nd1");
    // The DETAIL spelling of the nickname — the 098 D6 trap, read through the real parser.
    assert.equal(item.provenance.authorName, "Detail Name");
    assert.equal(item.provenance.title, "A note title");
    assert.equal(item.provenance.rawMetadata.desc, "A long description");
    assert.equal(item.provenance.rawMetadata.imageCount, 3);
    assert.equal(item.provenance.rawMetadata.width, 1242);
    assert.equal(item.provenance.rawMetadata.height, 1660);
    assert.equal(item.provenance.rawMetadata.noteType, "normal");
  }
  assert.deepEqual(page.items.map((i) => i.provenance.rawMetadata.imageIndex), [0, 1, 2]);
});

test("the index is the entry's POSITION, so one unusable image never renumbers the rest", () => {
  // If the index were a count of items produced, losing image 1 would re-key images 2 and
  // 3 as `:1` and `:2` — keys a previous sweep already ingested for DIFFERENT pictures.
  // Dedup-skip would then hide two new images and keep two stale ones forever.
  const broken = detailImage(2, { url: "", url_pre: "", url_default: "", info_list: [] });
  const page = parseNoteDetail(detail(card({ image_list: [detailImage(1), broken, detailImage(3)] })));
  assert.deepEqual(page.items.map((i) => i.sourceId), ["nd1:0", "nd1:2"]);
  assert.deepEqual(page.items.map((i) => i.provenance.rawMetadata.imageIndex), [0, 2]);
  // The count still describes the note, not the yield — 3 images were offered.
  assert.deepEqual([...new Set(page.items.map((i) => i.provenance.rawMetadata.imageCount))], [3]);
  assert.equal(page.unsupported, null, "two of three is a success, not a degradation");
});

test("every detail image is an unsigned MULTI-SEGMENT original with a signed fallback", () => {
  const page = parseNoteDetail(detail(card()));
  for (const item of page.items) {
    assert.match(item.mediaUrl, /^http:\/\/sns-i27\.rednotecdn\.com\//, item.mediaUrl);
    assert.equal(item.mediaUrl.includes("!"), false, "no transform suffix survives");
    // `oss-sg/spectrum/<id>` — the key the last-segment rule dropped two thirds of and
    // then 404'd on (098 D2). A one-segment result here would mean the rewrite regressed.
    assert.equal(new URL(item.mediaUrl).pathname.split("/").filter(Boolean).length, 3);
    assert.ok(item.mediaUrlFallback, "the signed url is kept — the bare original can 404");
    assert.notEqual(item.mediaUrl, item.mediaUrlFallback);
    assert.match(item.mediaUrlFallback, /!/, "the fallback is the signed, transformed url");
  }
});

test("the xsec_token is threaded in from the cover and never enters provenance", () => {
  // The detail body carries NO note-level token — only `user.xsec_token`, which authorizes
  // the author's profile rather than this note — so the sweep hands in the one the board
  // row supplied. It rides as a local field for the same reason the cover pass does.
  const page = parseNoteDetail(detail(card()), { xsecToken: "tok-from-cover" });
  assert.equal(page.items.every((i) => i.xsecToken === "tok-from-cover"), true);
  const leaves = new Set();
  (function collect(node) {
    if (Array.isArray(node)) return node.forEach(collect);
    if (node && typeof node === "object") return Object.values(node).forEach(collect);
    if (typeof node === "string") leaves.add(node);
  })(page.items.map((i) => i.provenance));
  assert.equal(leaves.has("tok-from-cover"), false, "no xsec_token in provenance");
  // The AUTHOR's token is a different credential and is not carried at all.
  assert.equal(leaves.has("utok"), false, "user.xsec_token is not the note's token");
  // Absent by default rather than invented.
  assert.equal(parseNoteDetail(detail(card())).items[0].xsecToken, null);
});

// MARK: - Live Photos (098 Open question 4 — deferred, deliberately not dropped)

test("a live_photo entry still yields its STILL, flagged for the deferred motion half", () => {
  const page = parseNoteDetail(detail(card({
    image_list: [detailImage(1), detailImage(2, { live_photo: true }), detailImage(3)],
  })));
  // Deferring the MOTION is not a reason to lose the picture: the entry's urls serve a
  // perfectly good still, and dropping the item would silently cost the user an image.
  assert.deepEqual(page.items.map((i) => i.sourceId), ["nd1:0", "nd1:1", "nd1:2"]);
  assert.deepEqual(page.items.map((i) => i.provenance.rawMetadata.livePhoto), [false, true, false]);
  // Flagged, so a later pass can FIND the notes worth revisiting rather than re-sweeping
  // every board to look for them.
  assert.equal(page.items[1].provenance.rawMetadata.kind, "image");
});

// MARK: - video notes: the stream, and NEVER the poster (098 T6c)

/** The live video capture — one populated `EF4` bucket, one rung, one `backup_urls` entry,
 * and an `image_list` of exactly ONE poster. */
const videoLive = JSON.parse(readFileSync(
  new URL("./fixtures/rednote-note-video.json", import.meta.url), "utf8"));
const videoCard = () => structuredClone(videoLive.data.items[0].note_card);
/** The live video card re-wrapped in this file's envelope helper, so a video test reads the
 * same way as every other test here. */
const videoDetail = (over = {}) => detail(Object.assign(videoCard(), over));

test("a video-typed note is REFUSED with a reason, not fanned out into poster duplicates", () => {
  // A video note's cover is already ingested by K3a as `<note_id>`, and the live capture
  // settled what T5a could only suspect: its `image_list` is ONE entry, the same poster.
  // Fanning out would enqueue it again as `<note_id>:0` — one picture, two keys, two
  // downloads, and a dedup-skip that cannot see the duplicate. T6c lifts the refusal
  // WITHOUT lifting that; with the video toggle off it is still exactly this.
  const page = parseNoteDetail(detail(card({ type: "video" })));
  assert.deepEqual(page.items, []);
  assert.equal(page.unsupported, "video");
  assert.equal(page.error, null, "a video note is not a refusal by rednote");
  assert.equal(page.noteId, "nd1", "the caller still learns WHICH note degraded");
});

test("the LIVE video note's poster is never fanned out, with the toggle off or on", () => {
  // The property the whole T5a/T6c argument rests on, asserted against the real capture
  // rather than against a card this file invented.
  assert.equal(videoCard().image_list.length, 1, "the premise: a video note carries ONE poster");
  const off = parseNoteDetail(videoDetail());
  assert.deepEqual(off.items, []);
  assert.equal(off.unsupported, "video");

  const on = parseNoteDetail(videoDetail(), { resolveVideo: true });
  assert.equal(on.items.length, 1);
  const posterUrls = videoCard().image_list[0];
  for (const item of on.items) {
    assert.equal(item.mediaUrl, null, "the stream item must carry no still");
    assert.equal(item.mediaUrlFallback, null);
    assert.notEqual(item.sourceId, `${on.noteId}:0`, "…and must never take an image index");
  }
  assert.ok(posterUrls.url_default, "the poster is still there — on the COVER item, at <note_id>");
});

test("with the video toggle on, a video note contributes its STREAM, keyed <note_id>:v", () => {
  const page = parseNoteDetail(videoDetail(), { resolveVideo: true, host: "www.rednote.com" });
  assert.equal(page.error, null);
  assert.equal(page.unsupported, null);
  assert.equal(page.noteKind, "video");
  assert.equal(page.items.length, 1, "one stream, not one per rung");

  const stream = page.items[0];
  assert.equal(stream.sourceId, videoSourceId(page.noteId));
  assert.equal(stream.sourceId, `${page.noteId}:${VIDEO_SOURCE_SUFFIX}`);
  assert.equal(stream.provenance.rawMetadata.kind, "video");
  assert.equal(stream.provenance.rawMetadata.noteId, page.noteId);
  assert.equal(stream.provenance.originalURL, `https://www.rednote.com/explore/${page.noteId}`);
});

test("the stream key registers as an EXPANDED CHILD — the re-open trap, closed", () => {
  // Checked against the real `knownNoteIndex` predicate, not against a description of it:
  // it counts a note as expanded by the COLON, so `<note_id>:v` registers and the cover's
  // bare `<note_id>` still does not. Upgrading the cover in place would have left no child
  // at all, and every video note on an 81 %-video board would be re-opened every sweep.
  const page = parseNoteDetail(videoDetail(), { resolveVideo: true });
  const noteId = page.noteId;
  assert.equal(knownNoteIndex(new Set([page.items[0].sourceId])).has(noteId), true);
  assert.equal(knownNoteIndex(new Set([noteId])).has(noteId), false,
    "a cover alone must never read as expanded — that is the mode trap T5b fixed");
});

test("the stream's candidate list is attached OUT of provenance (020 B3)", () => {
  const page = parseNoteDetail(videoDetail(), { resolveVideo: true });
  const stream = page.items[0];
  const expected = videoCandidates(videoCard().video.media.stream).candidates;
  assert.ok(expected.length > 1, "the live rung has a backup, or the ordering claim is untested");
  assert.deepEqual(readVideoCandidates(stream), expected);

  // `provenance` is what ships to the app and what a checkpointed item would carry. 020 B3:
  // the same note served a DIFFERENT ladder minutes apart, so a stored url comes back 404.
  const stored = JSON.stringify(stream.provenance);
  for (const url of expected) assert.equal(stored.includes(url), false, url);
  assert.doesNotMatch(stored, /rednotecdn\.com\/stream\//);
  // …and the whole ITEM, serialized the way a checkpoint would serialize it, loses it too.
  assert.equal(JSON.parse(JSON.stringify(stream)).videoCandidates, undefined);
  assert.equal(structuredClone(stream).videoCandidates, undefined);
});

test("the rung is DESCRIBED in provenance — facts that cannot rot into a dead fetch", () => {
  // The stream_type hypothesis (098 T6b: one good sample at 258, one bad at 020's _330)
  // can only ever gather evidence if what we took is recorded. A url would rot; an integer
  // and a bucket label cannot.
  const page = parseNoteDetail(videoDetail(), { resolveVideo: true });
  const raw = page.items[0].provenance.rawMetadata;
  const rung = videoCard().video.media.stream.EF4[0];
  assert.equal(raw.streamBucket, "EF4");
  assert.equal(raw.streamType, rung.stream_type);
  assert.equal(raw.width, rung.width);
  assert.equal(raw.height, rung.height);
  assert.equal(raw.streamRungs, 1);
});

test("a video note whose ladder gives nothing refuses with WHICH nothing, cover kept", () => {
  // 020's Risks entry: an `ef*`-only note is cover-still-only — a typed skip, never a sweep
  // failure. The reason is `STREAM_REFUSAL`'s own vocabulary, unwrapped rather than
  // collapsed into one word, because "there was no ladder" and "every rung is obfuscated"
  // are different facts about the note.
  const cases = [
    [{ EF4: [], EF5: [], EF6: [], EF7: [] }, STREAM_REFUSAL.emptyLadder],
    [{ EF4: [{ video_codec: "ef51", format: "mp4", master_url: "http://sns-v11.rednotecdn.com/stream/1/110/330/x_330.mp4" }] },
      STREAM_REFUSAL.undecodableCodec],
    [{ EF4: [{ format: "m3u8", master_url: "http://sns-v11.rednotecdn.com/stream/1/110/258/x.m3u8" }] },
      STREAM_REFUSAL.noUsableRung],
  ];
  for (const [stream, reason] of cases) {
    const note = videoCard();
    note.video.media.stream = stream;
    const page = parseNoteDetail(detail(note), { resolveVideo: true });
    assert.deepEqual(page.items, [], reason);
    assert.equal(page.unsupported, reason);
    assert.equal(page.noteKind, "video", "still a video note, so the caller keeps its cover");
    assert.equal(page.error, null, "a refused ladder is not a refusal BY rednote");
  }
  // A `type: video` card with no `video` key at all — the ladder path moved, or the label lies.
  const bare = parseNoteDetail(detail(card({ type: "video" })), { resolveVideo: true });
  assert.equal(bare.unsupported, STREAM_REFUSAL.noLadder);
});

test("mapNoteVideo on its own: a refusal returns no item, and never a half-built one", () => {
  const ctx = { noteId: "nd1", host: "www.rednote.com", xsecToken: "t",
    noteType: "video", author: { handle: null, name: "n", userId: "u" }, title: null, desc: null };
  const refused = mapNoteVideo({ type: "video" }, ctx);
  assert.equal(refused.item, null);
  assert.equal(refused.refusal, STREAM_REFUSAL.noLadder);
  const made = mapNoteVideo(videoCard(), ctx);
  assert.equal(made.refusal, null);
  assert.equal(made.item.sourceId, "nd1:v");
  assert.equal(made.item.xsecToken, "t", "the cover's token is threaded on, as for an image child");
});

test("a `video` KEY outranks the type label — the payload decides, not the name", () => {
  // `type` is a label and labels get renamed; a `video` payload is the thing itself.
  const page = parseNoteDetail(detail(card({ type: "normal", video: { media: {} } })));
  assert.equal(page.unsupported, "video");
  assert.deepEqual(page.items, []);
});

test("an UNRECOGNISED type with real images is still fanned out, with the type recorded", () => {
  // Refusing an unknown label would drop real content on the strength of a name we have
  // never seen. The images are there; the label rides along in rawMetadata so a new kind
  // shows up in what we stored instead of vanishing.
  const page = parseNoteDetail(detail(card({ type: "something_new" })));
  assert.equal(page.items.length, 3);
  assert.equal(page.unsupported, null);
  assert.deepEqual([...new Set(page.items.map((i) => i.provenance.rawMetadata.noteType))],
    ["something_new"]);
});

// MARK: - the empty cases (a note that yields nothing must yield nothing, visibly)

test("every way a note can yield nothing is reported as a REASON, never as silence", () => {
  // The contract T5b depends on: `items: []` with `unsupported` set means "keep this
  // note's cover item", not "this note is empty". A null reason beside an empty list would
  // let expansion replace a good cover with nothing.
  const cases = [
    ["no_note", detail(null, { items: [] })],
    ["no_note", detail(null, { items: [null] })],
    ["no_note_card", detail(null, { items: [{ id: "nd1", model_type: "note" }] })],
    ["no_note_id", detail(card({ note_id: null }))],
    ["no_note_id", detail(card({ note_id: "" }))],
    ["no_images", detail(card({ image_list: [] }))],
    ["no_images", detail(card({ image_list: undefined }))],
    ["no_images", detail(card({ image_list: "nope" }))],
    ["no_usable_images", detail(card({
      image_list: [detailImage(1, { url_pre: "", url_default: "", info_list: [] })],
    }))],
  ];
  for (const [reason, body] of cases) {
    const page = parseNoteDetail(body);
    assert.equal(page.unsupported, reason, `expected ${reason}`);
    assert.deepEqual(page.items, [], `${reason} must yield no doomed items`);
    assert.equal(page.error, null, `${reason} is a degradation, not a refusal`);
  }
});

test("an empty items[] is a missing NOTE, not a challenge — one deleted note must not halt a sweep", () => {
  // The asymmetry with the board feed is deliberate. There, `notes: []` is the terminator;
  // here, `items: []` is a note that did not come back, and halting would cost the other
  // 399 notes of a board because one was deleted. The refusal shape that DOES halt is a
  // body with no `data.items` array at all, which is what the 461 actually looked like.
  const missingNote = parseNoteDetail(detail(null, { items: [] }));
  assert.equal(missingNote.error, null);
  assert.equal(missingNote.unsupported, "no_note");

  const refused = parseNoteDetail({ code: 0, success: true, msg: "" });
  assert.ok(refused.error instanceof RednoteChallengeError);
  assert.equal(refused.unsupported, null, "a refusal is not a per-note degradation");
});

test("parseNoteDetail RETURNS a challenge as `error` and never throws it", () => {
  // Same reason as the board pass: a throw is swallowed by the intercept seam as an
  // unparseable capture, and a swallowed challenge keeps the sweep opening notes against
  // a session rednote has already flagged (098 R10).
  for (const body of [null, "<html>", { code: 461, success: true, msg: "" },
    { code: 0, success: false, data: { items: [] } }, { code: 0, success: true, data: {} }]) {
    const page = parseNoteDetail(body);
    assert.ok(page.error instanceof RednoteChallengeError, JSON.stringify(body));
    assert.equal(page.error.challenge, true);
    assert.deepEqual(page.items, []);
    assert.equal(page.noteId, null);
  }
});

test("the yield invariant: no items ⟺ a stated reason", () => {
  // Asserted across every shape above at once, because the one thing T5b cannot recover
  // from is an empty list with nothing to explain it.
  const bodies = [
    detail(card()), detail(card({ type: "video" })), detail(card({ image_list: [] })),
    detail(card({ note_id: null })), detail(null, { items: [] }),
    detail(card({ image_list: [detailImage(1, { url_pre: "", url_default: "", info_list: [] })] })),
    // The T6c arms, under BOTH settings of the toggle: the live video note, and one whose
    // ladder is empty.
    videoDetail(), emptyLadderDetail(),
  ];
  for (const body of bodies) {
    for (const resolveVideo of [false, true]) {
      const page = parseNoteDetail(body, { resolveVideo });
      assert.equal(page.error, null);
      assert.equal(page.items.length === 0, page.unsupported !== null,
        `empty-vs-reason disagree: ${page.items.length} items, unsupported=${page.unsupported}`);
    }
  }
});

/** The live video card with every bucket emptied — a ladder that is there and holds nothing. */
function emptyLadderDetail() {
  const note = videoCard();
  note.video.media.stream = { EF4: [], EF5: [], EF6: [], EF7: [] };
  return detail(note);
}

// MARK: - mapNoteImage on its own

test("mapNoteImage returns null for an entry with no usable url, rather than a doomed item", () => {
  const ctx = { noteId: "nd1", index: 0, host: "www.rednote.com", imageCount: 1,
    author: { handle: null, name: "n", userId: "u" }, title: null, desc: null,
    noteType: "normal", xsecToken: null };
  for (const empty of [null, undefined, {}, { url: "", info_list: [] }, "nope"]) {
    assert.equal(mapNoteImage(empty, ctx), null);
  }
  assert.ok(mapNoteImage(detailImage(1), ctx).mediaUrl);
});

// MARK: - against the live detail capture

test("the live detail fixture still carries SIGNED, multi-segment image urls", () => {
  // The same trap the board canary nearly walked into: `toRednoteOriginal` passes through
  // anything that is not a signed rednotecdn url, so a sanitizer that moved the host,
  // flattened the path or dropped the `!transform` would leave every assertion below
  // passing VACUOUSLY. Asserted on the INPUT, where a re-capture would break it.
  const images = detailLive.data.items[0].note_card.image_list;
  assert.ok(images.length > 1, "the fixture must actually fan out");
  for (const image of images) {
    const urls = [image.url_pre, image.url_default, ...image.info_list.map((i) => i.url)];
    for (const url of urls) {
      const { pathname, hostname } = new URL(url);
      assert.notEqual(hostname, "sns-i27.rednotecdn.com", "a detail url must still be signed");
      assert.ok(hostname.endsWith("rednotecdn.com"), `not a rednote CDN host: ${url}`);
      // `<timestamp>/<signature>/oss-sg/spectrum/<id>` — five live. The drop-two rule
      // fires on the SHAPE of the first two segments, so that is what is asserted: a
      // five-segment path alone proves nothing (`/stream/1/110/258/x.mp4` is one).
      assert.ok(hasSigningPrefix(url), `no signing prefix to strip: ${url}`);
      assert.equal(pathname.split("/").filter(Boolean).length, 5, `expected a 5-segment path: ${url}`);
      assert.ok(url.includes("!"), `the transform suffix must survive sanitization: ${url}`);
    }
  }
});

test("the live note parses to one item per image, all distinct, all with fallbacks", () => {
  const page = parseNoteDetail(detailLive, { host: "www.rednote.com", xsecToken: "tok-live" });
  const images = detailLive.data.items[0].note_card.image_list;
  assert.equal(page.error, null);
  assert.equal(page.unsupported, null);
  assert.equal(page.items.length, images.length, `expected ${images.length} items`);
  assert.equal(new Set(page.items.map((i) => i.sourceId)).size, images.length, "no key collisions");
  assert.equal(new Set(page.items.map((i) => i.mediaUrl)).size, images.length,
    "every image is a DIFFERENT picture — a shared url would mean the key rule collapsed them");
  // Keyed off the fixture's own id, so a re-capture cannot silently change what is asserted.
  assert.deepEqual(page.items.map((i) => i.sourceId),
    images.map((_, index) => `${page.noteId}:${index}`));
  for (const item of page.items) {
    assert.match(item.mediaUrl, /^http:\/\/sns-i27\.rednotecdn\.com\//, item.mediaUrl);
    assert.equal(item.mediaUrl.includes("!"), false);
    // The live keys are `oss-sg/spectrum/<id>` — multi-segment, which is the whole reason
    // T0 replaced the last-segment rule.
    assert.ok(new URL(item.mediaUrl).pathname.split("/").filter(Boolean).length >= 2,
      `the drop-two rule produced a flat key: ${item.mediaUrl}`);
    assert.ok(item.mediaUrlFallback, "the signed url is kept — the bare original can 404");
    assert.notEqual(item.mediaUrl, item.mediaUrlFallback);
  }
});

test("the live note carries its author, title, desc and dimensions onto every image", () => {
  const page = parseNoteDetail(detailLive);
  const note = detailLive.data.items[0].note_card;
  assert.ok(note.user.nickname, "the fixture must still have a nickname to read");
  assert.equal(page.items.every((i) => i.provenance.authorName === note.user.nickname), true,
    "the DETAIL spelling is read — nick_name-only would give null here");
  assert.equal(page.items.every((i) => i.provenance.title === note.title), true);
  assert.equal(page.items.every((i) => i.provenance.rawMetadata.desc === note.desc), true,
    "desc exists ONLY on the detail response");
  assert.equal(page.items.every((i) => i.provenance.rawMetadata.imageCount === note.image_list.length), true);
  assert.equal(page.items.every((i) => i.provenance.rawMetadata.width > 0
    && i.provenance.rawMetadata.height > 0), true, "per-image dimensions, not the cover's");
  assert.equal(page.items.every((i) => i.provenance.rawMetadata.noteId === page.noteId), true);
});

test("no token reaches the live note's provenance", () => {
  const page = parseNoteDetail(detailLive, { xsecToken: "tok-live" });
  const note = detailLive.data.items[0].note_card;
  // Compared as VALUES, not substrings: the sanitized ids are sequential, so `SAMPLE_TOKEN_3`
  // is a substring of `SAMPLE_TOKEN_30` and a substring test finds leaks that are not there.
  const leaves = new Set();
  (function collect(node) {
    if (Array.isArray(node)) return node.forEach(collect);
    if (node && typeof node === "object") return Object.values(node).forEach(collect);
    if (typeof node === "string") leaves.add(node);
  })(page.items.map((i) => i.provenance));
  assert.equal(leaves.has("tok-live"), false, "no xsec_token in provenance");
  assert.equal(leaves.has(note.user.xsec_token), false, "not the author's token either");
  assert.equal(page.items.every((i) => i.xsecToken === "tok-live"), true);
  assert.equal(page.items.every((i) => !i.provenance.originalURL.includes("xsec_token")), true);
});
