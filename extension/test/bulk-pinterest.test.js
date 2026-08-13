// Atelier Capture — Pinterest BulkSource driver tests (Phase 4, [T9]).
//
// The driver is pure over an injected `fetchJson`, so every test runs against the
// committed sanitized fixtures — a Pinterest response-shape drift breaks a unit
// test here, never a live sweep. Covers: the pin→BulkItem mapper (image pick,
// id/provenance, video + no-image edge cases), the page parser (success + error +
// end sentinel), the URL/header builders, the paginator (multi-page walk, resume,
// termination, loop guard, empty-page tolerance), and a full sweep composed with
// the Phase-3 engine.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  mapPinterestPin, pickPinImages, pinIdFrom,
  parseBoardFeedPage, parseBoardsPage, PinterestResourceError,
  buildBoardFeedURL, buildBoardsURL, boardFeedHeaders,
  makeResourceFetch, resourceNameFromURL,
  enumerateBoardFeed, enumerateBoards, pinterestBoardDriver,
  scrapePinterestAppVersion, scrapePinterestAppVersionFromDoc, readCookie, END_BOOKMARK,
} from "../src/bulk-pinterest.js";
import { runSweep, OUTCOMES } from "../src/bulk-engine.js";

const boardFeed = JSON.parse(
  readFileSync(new URL("./fixtures/pinterest-boardfeed.json", import.meta.url)));
const boardsList = JSON.parse(
  readFileSync(new URL("./fixtures/pinterest-boards.json", import.meta.url)));

const HOST = "REDACTED";
const firstPin = boardFeed.resource_response.data[0];

// MARK: - pinIdFrom

test("pinIdFrom: canonical id wins; falls back to the seo_url id; else null", () => {
  assert.equal(pinIdFrom({ id: "123", seo_url: "/pin/999/" }), "123");
  assert.equal(pinIdFrom({ seo_url: "/pin/999/" }), "999");
  assert.equal(pinIdFrom({}), null);
  assert.equal(pinIdFrom(null), null);
});

// MARK: - pickPinImages

test("pickPinImages: prefers orig, keeps the largest sized as fallback", () => {
  const { mediaUrl, mediaUrlFallback } = pickPinImages(firstPin.images);
  assert.equal(mediaUrl, "https://i.pinimg.com/originals/00/00/00/SAMPLE235.jpg");
  assert.equal(mediaUrlFallback, "https://i.pinimg.com/736x/00/00/00/SAMPLE234.jpg");
});

test("pickPinImages: no orig → rewrites the largest sized to /originals/ with a fallback", () => {
  const { mediaUrl, mediaUrlFallback } = pickPinImages({
    "236x": { width: 236, url: "https://i.pinimg.com/236x/a.jpg" },
    "736x": { width: 736, url: "https://i.pinimg.com/736x/a.jpg" },
  });
  assert.equal(mediaUrl, "https://i.pinimg.com/originals/a.jpg");
  assert.equal(mediaUrlFallback, "https://i.pinimg.com/736x/a.jpg");
});

test("pickPinImages: no usable image → nulls", () => {
  assert.deepEqual(pickPinImages(null), { mediaUrl: null, mediaUrlFallback: null });
  assert.deepEqual(pickPinImages({}), { mediaUrl: null, mediaUrlFallback: null });
});

// MARK: - mapPinterestPin

test("mapPinterestPin: maps the fixture pin to a complete BulkItem", () => {
  const item = mapPinterestPin(firstPin, { host: HOST, cursor: "CUR0" });
  assert.equal(item.sourceId, "1000000000000000239");
  assert.equal(item.mediaUrl, "https://i.pinimg.com/originals/00/00/00/SAMPLE235.jpg");
  assert.equal(item.mediaUrlFallback, "https://i.pinimg.com/736x/00/00/00/SAMPLE234.jpg");
  assert.equal(item.cursor, "CUR0");
  assert.deepEqual(item.provenance, {
    platform: "pinterest",
    originalURL: "https://REDACTEDREDACTED",
    mediaUrl: "https://i.pinimg.com/originals/00/00/00/SAMPLE235.jpg",
    mediaUrlFallback: "https://i.pinimg.com/736x/00/00/00/SAMPLE234.jpg",
    authorHandle: "sampleuser",
    authorName: "sujen",
    title: "Sample text",
    rawMetadata: { pinId: "1000000000000000239", isVideo: false, link: "https://example.com/asset/240" },
  });
});

test("mapPinterestPin: a video pin still maps its poster image and flags isVideo", () => {
  const videoPin = { ...firstPin, is_video: true };
  const item = mapPinterestPin(videoPin, { host: HOST });
  assert.equal(item.rawMetadata === undefined, true); // rawMetadata lives on provenance
  assert.equal(item.provenance.rawMetadata.isVideo, true);
  assert.ok(item.mediaUrl.includes("/originals/"));
});

test("mapPinterestPin: a pin with no id or no image is dropped (null)", () => {
  assert.equal(mapPinterestPin({ images: firstPin.images }, { host: HOST }), null); // no id
  assert.equal(mapPinterestPin({ id: "5", images: {} }, { host: HOST }), null);     // no image
});

// MARK: - parseBoardFeedPage / parseBoardsPage

test("parseBoardFeedPage: returns raw pins + the page bookmark", () => {
  const { pins, bookmark } = parseBoardFeedPage(boardFeed);
  assert.equal(pins.length, 1);
  assert.equal(bookmark, "SAMPLE_CURSOR_TOKEN==");
});

test("parseBoardFeedPage: a non-success response throws with the http status", () => {
  const bad = { resource_response: { status: "failure", message: "denied", http_status: 403 } };
  assert.throws(() => parseBoardFeedPage(bad), (err) => {
    assert.ok(err instanceof PinterestResourceError);
    assert.equal(err.httpStatus, 403);
    return true;
  });
});

test("parseBoardFeedPage: a missing resource_response throws", () => {
  assert.throws(() => parseBoardFeedPage({}), PinterestResourceError);
});

test("parseBoardsPage: maps boards to { id, name, url }", () => {
  const { boards, bookmark } = parseBoardsPage(boardsList);
  assert.deepEqual(boards, [{ id: "1000000000000000219", name: "Sample text", url: "/sampleuser/sample/" }]);
  assert.equal(bookmark, "SAMPLE_CURSOR_TOKEN==");
});

// MARK: - URL / header builders

test("buildBoardFeedURL: encodes source_url + data; adds bookmarks only when resuming", () => {
  const first = buildBoardFeedURL({ host: HOST, boardId: "B1", boardUrl: "/u/board/" });
  const u = new URL(first);
  assert.equal(u.origin + u.pathname, "https://REDACTED/resource/BoardFeedResource/get/");
  assert.equal(u.searchParams.get("source_url"), "/u/board/");
  const data = JSON.parse(u.searchParams.get("data"));
  assert.equal(data.options.board_id, "B1");
  assert.equal(data.options.page_size, 25);
  assert.equal("bookmarks" in data.options, false);

  const resumed = buildBoardFeedURL({ host: HOST, boardId: "B1", boardUrl: "/u/board/", cursor: "CUR" });
  const resumedData = JSON.parse(new URL(resumed).searchParams.get("data"));
  assert.deepEqual(resumedData.options.bookmarks, ["CUR"]);
});

test("buildBoardsURL: carries username + sort; bookmarks only when resuming", () => {
  const data = JSON.parse(new URL(
    buildBoardsURL({ host: HOST, username: "u", cursor: "C" })).searchParams.get("data"));
  assert.equal(data.options.username, "u");
  assert.equal(data.options.sort, "last_pinned_to");
  assert.deepEqual(data.options.bookmarks, ["C"]);
});

test("boardFeedHeaders: carries app-version, csrf, and the pws-handler gatekeeper", () => {
  const headers = boardFeedHeaders({
    appVersion: "1df0da9", csrfToken: "TOK",
    pwsHandler: "www/[username]/[slug].js", sourceUrl: "/u/b/",
  });
  assert.equal(headers["X-APP-VERSION"], "1df0da9");
  assert.equal(headers["X-CSRFToken"], "TOK");
  // The sole live gatekeeper (019 §T10): without it the resource endpoint 403s.
  assert.equal(headers["x-pinterest-pws-handler"], "www/[username]/[slug].js");
  assert.equal(headers["x-pinterest-source-url"], "/u/b/");
});

test("boardFeedHeaders: omits pws-handler / source-url when not supplied", () => {
  const headers = boardFeedHeaders({ appVersion: "v", csrfToken: "T" });
  assert.ok(!("x-pinterest-pws-handler" in headers));
  assert.ok(!("x-pinterest-source-url" in headers));
});

test("resourceNameFromURL: extracts the /resource/{Name}/get/ segment", () => {
  assert.equal(
    resourceNameFromURL("https://REDACTED/resource/BoardFeedResource/get/?x=1"),
    "BoardFeedResource");
  assert.equal(resourceNameFromURL("https://REDACTED/other/path"), null);
});

test("makeResourceFetch: sends the pws-handler + derived source-url for a BoardFeed URL", async () => {
  let sent = null;
  const fetchImpl = async (_url, opts) => {
    sent = opts.headers;
    return { ok: true, status: 200, json: async () => ({ resource_response: { data: [] } }) };
  };
  const fetchJson = makeResourceFetch({ appVersion: "1df0da9", csrfToken: "TOK", fetchImpl });
  const url = buildBoardFeedURL({ host: "REDACTED", boardId: "B", boardUrl: "/u/b/" });
  await fetchJson(url);
  // The gatekeeper header is derived from the resource name in the URL — the exact
  // regression this guards (a bare request 403s live).
  assert.equal(sent["x-pinterest-pws-handler"], "www/[username]/[slug].js");
  assert.equal(sent["x-pinterest-source-url"], "/u/b/");
  assert.equal(sent["X-APP-VERSION"], "1df0da9");
});

// BoardsResource used to be the unmapped resource here. It gained a handler on
// 2026-08-14 once a live probe showed the header is presence-checked rather than
// route-matched, so this points at a resource that genuinely has no entry — the
// behaviour under test is "unmapped sends nothing", not "boards are deferred".
test("makeResourceFetch: no pws-handler for a resource with no PWS_HANDLERS entry", async () => {
  let sent = null;
  const fetchImpl = async (_url, opts) => {
    sent = opts.headers;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  const fetchJson = makeResourceFetch({ appVersion: "v", csrfToken: "T", fetchImpl });
  await fetchJson("https://REDACTED/resource/PinResource/get/?source_url=/pin/1/&data=%7B%7D");
  assert.ok(!("x-pinterest-pws-handler" in sent));
});

test("makeResourceFetch: BoardsResource now sends its own handler", async () => {
  let sent = null;
  const fetchImpl = async (_url, opts) => {
    sent = opts.headers;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  const fetchJson = makeResourceFetch({ appVersion: "v", csrfToken: "T", fetchImpl });
  await fetchJson(buildBoardsURL({ host: "REDACTED", username: "u" }));
  assert.equal(sent["x-pinterest-pws-handler"], "www/[username].js");
});

// MARK: - enumerateBoardFeed (paginator)

/** A fetchJson that serves scripted pages keyed by the request's `bookmarks` value
 * (null for page 1), recording every requested cursor. */
function pagedFetch(pagesByCursor) {
  const requested = [];
  const fetchJson = async (url) => {
    const data = JSON.parse(new URL(url).searchParams.get("data"));
    const cursor = data.options.bookmarks ? data.options.bookmarks[0] : null;
    requested.push(cursor);
    if (!(cursor in pagesByCursor)) throw new Error(`no page for cursor ${cursor}`);
    return pagesByCursor[cursor];
  };
  return { fetchJson, requested };
}

/** A minimal board-feed page: pins with the given ids + a next bookmark. */
function feedPage(ids, bookmark) {
  return {
    resource_response: {
      status: "success",
      http_status: 200,
      data: ids.map((id) => ({ id, seo_url: `/pin/${id}/`, images: firstPin.images })),
      bookmark,
    },
  };
}

test("enumerateBoardFeed: walks pages to -end-, threading each page's request cursor", async () => {
  const { fetchJson, requested } = pagedFetch({
    null: feedPage(["p1", "p2"], "BM1"),
    BM1: feedPage(["p3"], END_BOOKMARK),
  });
  const items = [];
  for await (const item of enumerateBoardFeed(fetchJson, { host: HOST, boardId: "B", boardUrl: "/u/b/" }, {})) {
    items.push(item);
  }
  assert.deepEqual(items.map((i) => i.sourceId), ["p1", "p2", "p3"]);
  // page-1 pins carry cursor null; the page-2 pin carries BM1 (its request bookmark).
  assert.deepEqual(items.map((i) => i.cursor), [null, null, "BM1"]);
  assert.deepEqual(requested, [null, "BM1"]); // exactly two fetches, none past -end-
});

test("enumerateBoardFeed: resumes from a saved cursor (first fetch uses it)", async () => {
  const { fetchJson, requested } = pagedFetch({ BM5: feedPage(["p9"], END_BOOKMARK) });
  const items = [];
  for await (const item of enumerateBoardFeed(
    fetchJson, { host: HOST, boardId: "B", boardUrl: "/u/b/" }, { cursor: "BM5" })) {
    items.push(item);
  }
  assert.deepEqual(items.map((i) => i.sourceId), ["p9"]);
  assert.deepEqual(requested, ["BM5"]);
});

test("enumerateBoardFeed: a repeated bookmark stops the walk (loop guard)", async () => {
  const { fetchJson, requested } = pagedFetch({
    null: feedPage(["p1"], "LOOP"),
    LOOP: feedPage(["p2"], "LOOP"), // points back at itself
  });
  const ids = [];
  for await (const item of enumerateBoardFeed(fetchJson, { host: HOST, boardId: "B", boardUrl: "/u/b/" }, {})) {
    ids.push(item.sourceId);
  }
  assert.deepEqual(ids, ["p1", "p2"]);        // p2's page requested once, then guarded
  assert.deepEqual(requested, [null, "LOOP"]); // no infinite re-request
});

test("enumerateBoardFeed: an empty page with -end- yields nothing", async () => {
  const { fetchJson } = pagedFetch({ null: feedPage([], END_BOOKMARK) });
  const items = [];
  for await (const item of enumerateBoardFeed(fetchJson, { host: HOST, boardId: "B", boardUrl: "/u/b/" }, {})) {
    items.push(item);
  }
  assert.equal(items.length, 0);
});

// MARK: - enumerateBoards

test("enumerateBoards: yields the fixture's boards then stops at the end", async () => {
  const fetchJson = async () => boardsList; // single page (bookmark is a token, then done)
  // boardsList's bookmark is a token, not -end-; a second identical page would loop,
  // so serve -end- on the second request via a cursor-aware fetch.
  let call = 0;
  const paged = async () => (call++ === 0 ? boardsList
    : { resource_response: { status: "success", http_status: 200, data: [], bookmark: END_BOOKMARK } });
  const boards = [];
  for await (const board of enumerateBoards(paged, { host: HOST, username: "sampleuser" }, {})) {
    boards.push(board);
  }
  assert.deepEqual(boards.map((b) => b.id), ["1000000000000000219"]);
});

// MARK: - session bootstrap helpers

test("scrapePinterestAppVersion: pulls the app_version hash from page bootstrap", () => {
  assert.equal(scrapePinterestAppVersion('window.__X={"app_version":"1df0da9","x":1}'), "1df0da9");
  assert.equal(scrapePinterestAppVersion('"app_version" : "abcdef12"'), "abcdef12");
  assert.equal(scrapePinterestAppVersion("no version here"), null);
  assert.equal(scrapePinterestAppVersion(null), null);
});

test("scrapePinterestAppVersionFromDoc: finds it in a <script> body without serializing the DOM (14A)", () => {
  // The bootstrap lives in an inline script; scanning script bodies must find it WITHOUT
  // touching documentElement.innerHTML (which, on a real board, is megabytes to serialize).
  let innerHTMLReads = 0;
  const doc = {
    scripts: [
      { textContent: "console.log('noise')" },
      { textContent: 'window.__PWS_DATA__={"app_version":"beadf1","other":1}' },
    ],
    documentElement: { get innerHTML() { innerHTMLReads += 1; return ""; } },
  };
  assert.equal(scrapePinterestAppVersionFromDoc(doc), "beadf1");
  assert.equal(innerHTMLReads, 0, "the whole-DOM serialize was avoided");
});

test("scrapePinterestAppVersionFromDoc: falls back to the full page when no script carries it (14A)", () => {
  const doc = {
    scripts: [{ textContent: "nothing useful here" }],
    documentElement: { innerHTML: 'meta app_version":"cafe99" somewhere in the page' },
  };
  assert.equal(scrapePinterestAppVersionFromDoc(doc), "cafe99");
});

test("scrapePinterestAppVersionFromDoc: no scripts / empty page → null (never throws)", () => {
  assert.equal(scrapePinterestAppVersionFromDoc({ documentElement: { innerHTML: "" } }), null);
  assert.equal(scrapePinterestAppVersionFromDoc({}), null);
  assert.equal(scrapePinterestAppVersionFromDoc(null), null);
});

test("readCookie: extracts a named cookie value, trimming whitespace", () => {
  assert.equal(readCookie("a=1; csrftoken=TOK123; b=2", "csrftoken"), "TOK123");
  assert.equal(readCookie("csrftoken=ONLY", "csrftoken"), "ONLY");
  assert.equal(readCookie("a=1; b=2", "csrftoken"), null);
  assert.equal(readCookie("", "csrftoken"), null);
});

// MARK: - full sweep: Pinterest driver × the Phase-3 engine

test("pinterestBoardDriver drives a complete engine sweep end-to-end", async () => {
  const { fetchJson } = pagedFetch({
    null: feedPage(["p1", "p2"], "BM1"),
    BM1: feedPage(["p3", "p4"], END_BOOKMARK),
  });
  const driver = pinterestBoardDriver({ fetchJson, host: HOST });

  const ingested = [];
  const relay = async (item) => {
    ingested.push(item.sourceId);
    // The relay receives the mapped provenance the app would ingest.
    assert.equal(item.provenance.platform, "pinterest");
    return { outcome: OUTCOMES.ingested };
  };

  const result = await runSweep(driver, { boardId: "B", boardUrl: "/u/b/" }, {
    relay,
    random: () => 0,
    sleep: () => Promise.resolve(),
    config: { MAX_CONCURRENCY: 2, PACING_MS: 0, PACING_JITTER_MS: 0 },
  });

  assert.equal(result.status, "complete");
  assert.equal(result.counts.ingested, 4);
  assert.deepEqual(ingested.sort(), ["p1", "p2", "p3", "p4"]);
  assert.equal(result.cursor, "BM1"); // last contiguous page's request cursor
});

test("a driver fetch failure halts the sweep gracefully (checkpoint preserved)", async () => {
  const fetchJson = async () => { throw new PinterestResourceError("http 403", { httpStatus: 403 }); };
  const driver = pinterestBoardDriver({ fetchJson, host: HOST });
  const result = await runSweep(driver, { boardId: "B", boardUrl: "/u/b/" }, {
    relay: async () => ({ outcome: OUTCOMES.ingested }),
    sleep: () => Promise.resolve(),
    random: () => 0,
    config: { MAX_CONCURRENCY: 1, PACING_MS: 0 },
  });
  assert.equal(result.status, "halted");
  assert.equal(result.counts.ingested, 0);
  assert.match(result.error, /403/);
});
