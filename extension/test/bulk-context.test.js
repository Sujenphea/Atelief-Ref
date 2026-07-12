// Atelier Capture — sweep-context resolver tests (the popup's eligibility matrix).
//
// Pure fixtures, no chrome.*/DOM: every site/page/board-id branch is asserted here so
// a Pinterest DOM reshape or an X route change breaks a unit test, not a live launch.
// The Pinterest board id comes from the real "Collage" button href shape observed live
// (`/collage-creation-tool/?boardId=<digits>`).

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  resolveSweepSpec, extractPinterestBoardId, pinterestBoardPath, platformForHost,
  REASON_MESSAGE,
} from "../src/bulk-context.js";

// The real "Collage" button href shape (relative, as it appears in the DOM).
const collageHref = (boardId) => `/collage-creation-tool/?boardId=${boardId}`;

// ---- platformForHost -------------------------------------------------------

test("platformForHost: pinterest across TLD/subdomain variants", () => {
  for (const h of ["www.pinterest.com", "REDACTED", "pinterest.com", "www.pinterest.co.uk"]) {
    assert.equal(platformForHost(h), "pinterest", h);
  }
});

test("platformForHost: x and twitter", () => {
  for (const h of ["x.com", "www.x.com", "twitter.com", "mobile.twitter.com"]) {
    assert.equal(platformForHost(h), "twitter", h);
  }
});

test("platformForHost: unsupported → null", () => {
  for (const h of ["example.com", "notpinterest.evil.com", ""]) {
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
    url: "https://REDACTED/sujen/design-refs/", collageHref: collageHref("777"),
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
  ];
  const seen = new Set();
  for (const r of refusals) {
    assert.equal(r.ok, false);
    seen.add(r.reason);
    const message = REASON_MESSAGE[r.reason];
    assert.ok(typeof message === "string" && message.length > 0, `no message for "${r.reason}"`);
  }
  // All four distinct branches were actually exercised (guards against a copy-paste input).
  assert.deepEqual([...seen].sort(),
    ["board-id-missing", "not-a-board", "not-supported-site", "x-not-bookmarks"]);
  // And no REASON_MESSAGE entry is a placeholder blank.
  for (const [reason, message] of Object.entries(REASON_MESSAGE)) {
    assert.ok(typeof message === "string" && message.length > 0, reason);
  }
});
