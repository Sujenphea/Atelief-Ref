// Atelier Capture — sweep-context resolver tests (the popup's eligibility matrix).
//
// Pure fixtures, no chrome.*/DOM: every site/page/board-id branch is asserted here so
// a Pinterest DOM reshape or an X route change breaks a unit test, not a live launch.
// The Pinterest board id comes from the real "Collage" button href shape observed live
// (`/collage-creation-tool/?boardId=<digits>`), and the rednote board URL is a real saved
// board copied out of the address bar — a resolver is only as honest as its inputs.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  resolveSweepSpec, extractPinterestBoardId, pinterestBoardPath, platformForHost,
  REASON_MESSAGE,
} from "../src/bulk-context.js";

// The real "Collage" button href shape (relative, as it appears in the DOM).
const collageHref = (boardId) => `/collage-creation-tool/?boardId=${boardId}`;

// A real saved rednote board, copied verbatim out of the address bar (2026-09-14) —
// query string included, because that is the shape a user actually pastes. The id is the
// SAME one the live board-feed capture carries (`resources/rednote-board-page2.json`,
// `board_id=69322476000000001202811f`), so the fixture, the parser and this resolver all
// describe one real board rather than three plausible inventions.
const REDNOTE_BOARD_URL = "https://www.rednote.com/board/69322476000000001202811f?source=web_user_page";
const REDNOTE_BOARD_ID = "69322476000000001202811f";
// The spec any spelling of that board must resolve to. Built from the id, not retyped, so
// the assertion is "scope keys off the board id" and not "scope happens to be this string".
const rednoteSpec = (boardId) => ({
  ok: true,
  spec: { platform: "rednote", input: { boardId }, scope: `board:${boardId}` },
});
const rednoteBoardUrl = (boardId) => `https://www.rednote.com/board/${boardId}`;

// ---- platformForHost -------------------------------------------------------

test("platformForHost: pinterest across TLD/subdomain variants", () => {
  for (const h of ["www.pinterest.com", "nz.pinterest.com", "pinterest.com", "www.pinterest.co.uk"]) {
    assert.equal(platformForHost(h), "pinterest", h);
  }
});

test("platformForHost: x and twitter", () => {
  for (const h of ["x.com", "www.x.com", "twitter.com", "mobile.twitter.com"]) {
    assert.equal(platformForHost(h), "twitter", h);
  }
});

test("platformForHost: instagram across subdomain variants", () => {
  for (const h of ["instagram.com", "www.instagram.com"]) {
    assert.equal(platformForHost(h), "instagram", h);
  }
});

test("platformForHost: rednote answers to BOTH of its domains", () => {
  // One product, two domains — the module comment says both are in host_permissions and
  // both must resolve. Asserted rather than trusted: a user's saved board is on whichever
  // domain they signed up through, and the mainland one has no other coverage here.
  for (const h of ["www.rednote.com", "rednote.com", "www.xiaohongshu.com", "xiaohongshu.com"]) {
    assert.equal(platformForHost(h), "rednote", h);
  }
});

test("platformForHost: unsupported → null", () => {
  for (const h of ["example.com", "notpinterest.evil.com", "notinstagram.evil.com",
    "notrednote.evil.com", "rednote.com.evil.com", ""]) {
    assert.equal(platformForHost(h), null, h);
  }
});

// ---- pinterestBoardPath ----------------------------------------------------

test("pinterestBoardPath: a 2-segment board page", () => {
  assert.deepEqual(pinterestBoardPath("/sujen/design-refs/"),
    { user: "sujen", slug: "design-refs", boardUrl: "/sujen/design-refs/" });
  // no trailing slash normalizes the same
  assert.deepEqual(pinterestBoardPath("/sujen/design-refs"),
    { user: "sujen", slug: "design-refs", boardUrl: "/sujen/design-refs/" });
});

test("pinterestBoardPath: reserved routes and non-board depths → null", () => {
  for (const p of ["/", "/sujen/", "/pin/12345/", "/search/pins/", "/settings/",
    "/sujen/design-refs/a-section/", "/ideas/"]) {
    assert.equal(pinterestBoardPath(p), null, p);
  }
});

// ---- extractPinterestBoardId ----------------------------------------------

test("extractPinterestBoardId: pulls boardId from the collage href", () => {
  assert.equal(extractPinterestBoardId("/collage-creation-tool/?boardId=1084663960195879466"),
    "1084663960195879466");
});

test("extractPinterestBoardId: tolerates an absolute href + extra query params", () => {
  assert.equal(
    extractPinterestBoardId("https://www.pinterest.com/collage-creation-tool/?ref=board&boardId=42&x=1"),
    "42");
});

test("extractPinterestBoardId: missing/empty/non-numeric/malformed → null (drift signal)", () => {
  assert.equal(extractPinterestBoardId(null), null);
  assert.equal(extractPinterestBoardId(""), null);
  assert.equal(extractPinterestBoardId("/collage-creation-tool/"), null);          // no boardId param
  assert.equal(extractPinterestBoardId("/collage-creation-tool/?boardId=abc"), null); // not digits
});

// ---- resolveSweepSpec: Pinterest ------------------------------------------

test("resolveSweepSpec: pinterest board → full spec (no resolveVideo in spec)", () => {
  const r = resolveSweepSpec({
    url: "https://nz.pinterest.com/sujen/design-refs/", collageHref: collageHref("777"),
  });
  assert.deepEqual(r, {
    ok: true,
    spec: {
      platform: "pinterest",
      input: { boardId: "777", boardUrl: "/sujen/design-refs/" },
      scope: "board:design-refs",
    },
  });
});

test("resolveSweepSpec: board page ignores query string", () => {
  const r = resolveSweepSpec({
    url: "https://pinterest.com/sujen/design-refs/?invite=1", collageHref: collageHref("5"),
  });
  assert.equal(r.ok, true);
  assert.equal(r.spec.input.boardId, "5");
});

test("resolveSweepSpec: pinterest non-board pages → not-a-board", () => {
  for (const url of ["https://pinterest.com/", "https://pinterest.com/pin/999/",
    "https://pinterest.com/search/pins/?q=ui", "https://pinterest.com/sujen/"]) {
    assert.deepEqual(resolveSweepSpec({ url, collageHref: collageHref("1") }),
      { ok: false, reason: "not-a-board" }, url);
  }
});

test("resolveSweepSpec: board page but collage href absent → board-id-missing", () => {
  const r = resolveSweepSpec({ url: "https://pinterest.com/sujen/design-refs/", collageHref: null });
  assert.deepEqual(r, { ok: false, reason: "board-id-missing" });
});

// ---- resolveSweepSpec: X ---------------------------------------------------

test("resolveSweepSpec: x main bookmarks → bookmarks spec (with/without trailing slash, twitter.com)", () => {
  for (const url of ["https://x.com/i/bookmarks", "https://x.com/i/bookmarks/",
    "https://twitter.com/i/bookmarks"]) {
    assert.deepEqual(resolveSweepSpec({ url }),
      { ok: true, spec: { platform: "twitter", input: {}, scope: "bookmarks" } }, url);
  }
});

test("resolveSweepSpec: x bookmark FOLDER → per-folder scope (real folder URL shape)", () => {
  for (const url of ["https://x.com/i/bookmarks/2005398593486864807",
    "https://x.com/i/bookmarks/2005398593486864807/"]) {
    assert.deepEqual(resolveSweepSpec({ url }),
      { ok: true, spec: { platform: "twitter", input: {}, scope: "bookmarks:2005398593486864807" } }, url);
  }
});

test("resolveSweepSpec: other X pages → x-not-bookmarks (never sweep the home feed)", () => {
  for (const url of ["https://x.com/home", "https://x.com/i/likes",
    "https://x.com/someone", "https://x.com/", "https://x.com/i/bookmarks/all"]) {
    assert.deepEqual(resolveSweepSpec({ url }), { ok: false, reason: "x-not-bookmarks" }, url);
  }
});

// ---- resolveSweepSpec: Instagram ------------------------------------------

test("resolveSweepSpec: IG flat saved → saved spec (/saved/ and /saved/all-posts/)", () => {
  for (const url of [
    "https://www.instagram.com/lychee.web/saved/",
    "https://www.instagram.com/lychee.web/saved",
    "https://www.instagram.com/lychee.web/saved/all-posts/",
    "https://instagram.com/lychee.web/saved/all-posts",
  ]) {
    assert.deepEqual(resolveSweepSpec({ url }),
      { ok: true, spec: { platform: "instagram", input: {}, scope: "saved" } }, url);
  }
});

test("resolveSweepSpec: IG saved query string is ignored", () => {
  const r = resolveSweepSpec({ url: "https://www.instagram.com/lychee.web/saved/?hl=en" });
  assert.equal(r.ok, true);
  assert.equal(r.spec.scope, "saved");
});

test("resolveSweepSpec: IG a specific collection → collection spec (real URL /saved/<slug>/<id>/)", () => {
  // The live-verified collection URL shape (2026-07-16): a slug then a numeric id.
  const r = resolveSweepSpec({ url: "https://www.instagram.com/lychee.web/saved/test2/1021461010622913/" });
  assert.deepEqual(r, {
    ok: true,
    spec: {
      platform: "instagram",
      input: { collectionId: "1021461010622913", collectionSlug: "test2" },
      scope: "saved:collection:1021461010622913",
    },
  });
  // Trailing slash optional; query string ignored; scope keys off the STABLE id, not the slug.
  const r2 = resolveSweepSpec({ url: "https://instagram.com/me/saved/refs/42?hl=en" });
  assert.equal(r2.ok, true);
  assert.equal(r2.spec.scope, "saved:collection:42");
  assert.equal(r2.spec.input.collectionSlug, "refs");
});

test("resolveSweepSpec: IG a saved subpath that is neither flat nor a collection → typed refusal", () => {
  for (const url of [
    "https://www.instagram.com/lychee.web/saved/interiors/",       // a slug with no numeric id
    "https://www.instagram.com/lychee.web/saved/test2/not-an-id/", // 4 segments but non-numeric id
    "https://www.instagram.com/lychee.web/saved/a/1/b/",           // too deep
  ]) {
    assert.deepEqual(resolveSweepSpec({ url }),
      { ok: false, reason: "instagram-saved-unrecognized" }, url);
  }
});

test("resolveSweepSpec: IG non-saved pages → instagram-not-saved", () => {
  for (const url of [
    "https://www.instagram.com/",
    "https://www.instagram.com/lychee.web/",
    "https://www.instagram.com/p/ABC123/",
    "https://www.instagram.com/reel/XYZ/",
    "https://www.instagram.com/explore/",
  ]) {
    assert.deepEqual(resolveSweepSpec({ url }), { ok: false, reason: "instagram-not-saved" }, url);
  }
});

// ---- resolveSweepSpec: rednote --------------------------------------------

test("resolveSweepSpec: the real rednote board URL → full spec (no resolveVideo in spec)", () => {
  // The verbatim address-bar URL, pinned so this can never drift away from the shape a
  // user actually has. Everything else in this section varies one thing about it.
  const r = resolveSweepSpec({ url: REDNOTE_BOARD_URL });
  assert.deepEqual(r, {
    ok: true,
    spec: {
      platform: "rednote",
      input: { boardId: "69322476000000001202811f" },
      scope: "board:69322476000000001202811f",
    },
  });
  // Said out loud as well as by deepEqual: the resolver decides WHAT can be swept, never
  // HOW. Both toggles are the popup's to fold in (bulk-context.js:19).
  assert.ok(!("resolveVideo" in r.spec), "resolveVideo is the popup's toggle, not the spec's");
  assert.ok(!("expandNotes" in r.spec), "expandNotes is the popup's toggle, not the spec's");
});

test("resolveSweepSpec: rednote board spellings all resolve to ONE spec (both domains)", () => {
  // The query string is the user's real one; the bare and trailing-slash forms are what a
  // hand-typed or copied-from-a-link URL looks like. xiaohongshu.com is the same product on
  // the mainland domain and must land on the same sweep — a board swept from one domain and
  // resumed from the other has to hit the same scope, or it re-walks from zero.
  for (const url of [
    REDNOTE_BOARD_URL,
    `https://www.rednote.com/board/${REDNOTE_BOARD_ID}`,
    `https://www.rednote.com/board/${REDNOTE_BOARD_ID}/`,
    `https://rednote.com/board/${REDNOTE_BOARD_ID}`,
    `https://www.xiaohongshu.com/board/${REDNOTE_BOARD_ID}?source=web_user_page`,
    `https://www.xiaohongshu.com/board/${REDNOTE_BOARD_ID}/`,
    `https://xiaohongshu.com/board/${REDNOTE_BOARD_ID}`,
  ]) {
    assert.deepEqual(resolveSweepSpec({ url }), rednoteSpec(REDNOTE_BOARD_ID), url);
  }
});

test("resolveSweepSpec: rednote scope and input carry the board id, because the driver scopes on it", () => {
  // `matchesScope` filters the hook's replay buffer, which can still hold pages from a
  // board visited earlier in the same tab — so a spec that cannot name its board would
  // sweep the previous one's leftovers into this one.
  const r = resolveSweepSpec({ url: REDNOTE_BOARD_URL });
  assert.equal(r.spec.input.boardId, REDNOTE_BOARD_ID);
  assert.equal(r.spec.scope, `board:${REDNOTE_BOARD_ID}`);
});

test("resolveSweepSpec: rednote board id is hex, matched case-insensitively", () => {
  // The id regex carries the `i` flag, so an id that arrives upper- or mixed-case resolves
  // — and is carried through UNCHANGED, since the scope is compared as a string.
  for (const boardId of [REDNOTE_BOARD_ID.toUpperCase(), "69322476000000001202811F",
    "6932247600000000ABCDef12"]) {
    assert.deepEqual(resolveSweepSpec({ url: rednoteBoardUrl(boardId) }),
      rednoteSpec(boardId), boardId);
  }
});

test("resolveSweepSpec: rednote board id length bound (16–32) is pinned at both ends", () => {
  // The real id is 24 hex, but the rule is a RANGE — so both ends are asserted and so is
  // one character outside each, or the bound would be incidental rather than intended.
  for (const length of [16, 24, 32]) {
    const boardId = "a".repeat(length);
    assert.deepEqual(resolveSweepSpec({ url: rednoteBoardUrl(boardId) }),
      rednoteSpec(boardId), `${length} hex chars`);
  }
  for (const length of [15, 33]) {
    assert.deepEqual(resolveSweepSpec({ url: rednoteBoardUrl("a".repeat(length)) }),
      { ok: false, reason: "rednote-board-id-missing" }, `${length} hex chars`);
  }
});

test("resolveSweepSpec: rednote non-board pages → rednote-not-a-board", () => {
  for (const url of ["https://www.rednote.com/", "https://www.rednote.com/explore/abc",
    `https://www.rednote.com/user/profile/${REDNOTE_BOARD_ID}`,
    "https://www.xiaohongshu.com/explore/abc"]) {
    assert.deepEqual(resolveSweepSpec({ url }), { ok: false, reason: "rednote-not-a-board" }, url);
  }
});

test("resolveSweepSpec: a rednote board page with no usable id → rednote-board-id-missing", () => {
  // Told apart from "not a board" on purpose: the page IS the right page, so the copy asks
  // the user to reopen it rather than to go and find a board.
  for (const url of ["https://www.rednote.com/board", "https://www.rednote.com/board/",
    "https://www.rednote.com/board/not-hex",
    `https://www.rednote.com/board/${REDNOTE_BOARD_ID.slice(0, -1)}g`]) {
    assert.deepEqual(resolveSweepSpec({ url }),
      { ok: false, reason: "rednote-board-id-missing" }, url);
  }
});

// ---- resolveSweepSpec: unsupported / malformed ----------------------------

test("resolveSweepSpec: unsupported site and malformed url → not-supported-site", () => {
  assert.deepEqual(resolveSweepSpec({ url: "https://example.com/anything" }),
    { ok: false, reason: "not-supported-site" });
  assert.deepEqual(resolveSweepSpec({ url: "not a url" }),
    { ok: false, reason: "not-supported-site" });
  assert.deepEqual(resolveSweepSpec({}), { ok: false, reason: "not-supported-site" });
});

// ---- REASON_MESSAGE completeness (12A) -------------------------------------

test("REASON_MESSAGE has a non-empty message for every refusal reason the resolver emits", () => {
  // Drive one input down each refusal branch so a NEW reason without a message string
  // fails here (rather than rendering blank guidance in the popup).
  const refusals = [
    resolveSweepSpec({ url: "https://example.com/x" }),                       // not-supported-site
    resolveSweepSpec({ url: "https://www.pinterest.com/pin/12345/" }),        // not-a-board
    resolveSweepSpec({ url: "https://www.pinterest.com/user/board/", collageHref: null }), // board-id-missing
    resolveSweepSpec({ url: "https://x.com/home" }),                          // x-not-bookmarks
    resolveSweepSpec({ url: "https://www.instagram.com/me/saved/interiors/" }), // instagram-saved-unrecognized
    resolveSweepSpec({ url: "https://www.instagram.com/me/" }),               // instagram-not-saved
    resolveSweepSpec({ url: "https://www.rednote.com/explore/abc" }),         // rednote-not-a-board
    resolveSweepSpec({ url: "https://www.rednote.com/board/not-hex" }),       // rednote-board-id-missing
  ];
  const seen = new Set();
  for (const r of refusals) {
    assert.equal(r.ok, false);
    seen.add(r.reason);
    const message = REASON_MESSAGE[r.reason];
    assert.ok(typeof message === "string" && message.length > 0, `no message for "${r.reason}"`);
  }
  // All distinct branches were actually exercised (guards against a copy-paste input).
  assert.deepEqual([...seen].sort(),
    ["board-id-missing", "instagram-not-saved", "instagram-saved-unrecognized",
      "not-a-board", "not-supported-site", "rednote-board-id-missing",
      "rednote-not-a-board", "x-not-bookmarks"]);
  // And no REASON_MESSAGE entry is a placeholder blank.
  for (const [reason, message] of Object.entries(REASON_MESSAGE)) {
    assert.ok(typeof message === "string" && message.length > 0, reason);
  }
});
