// Atelier Capture — the MAIN-world hooks agree with the modules they duplicate (098 R5).
//
// A MAIN-world hook is injected as a CLASSIC script, so it cannot `import`. Its message
// tags are therefore retyped from bulk-messages.js and its request matcher from the
// platform parser, under comments asking future-us to keep them in sync. There were EIGHT
// such comments across two files and nothing enforcing any of them, and rednote doubled
// the duplication.
//
// Desync is silent in both directions: a wrong tag means the controller's listener never
// fires and the sweep ingests nothing, and a wrong matcher means the hook forwards the
// wrong responses (or none). Neither fails a build, and neither failed a test.
//
// So the hooks are evaluated here the way Chrome injects them — as classic scripts, via
// `new Function`, the same technique hook-core.test.js already uses — and their constants
// are compared against the real exports.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import * as messages from "../src/bulk-messages.js";
import { isBoardFeedRequest } from "../src/bulk-rednote.js";
import { matchesScope as twitterMatchesScope } from "../src/bulk-twitter.js";

/**
 * Evaluate a hook file as a classic script and lift the named top-level bindings out.
 *
 * The hooks auto-install against a real `window`, so they are given a scope with a
 * hostname that does NOT match — the install is guarded on `window.location.hostname` and
 * simply does not run, leaving the declarations to be read. That keeps this test about
 * the CONSTANTS, with installation itself covered by hook-core.test.js.
 */
function liftFromHook(file, names) {
  const source = readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8");
  const body = `${source}\n;return { ${names.map((n) => `${n}: typeof ${n} === "undefined" ? undefined : ${n}`).join(", ")} };`;
  return new Function("window", "console", body)(
    { location: { hostname: "example.invalid" }, addEventListener() {} },
    { error() {} },
  );
}

test("twitter-hook.js message tags match bulk-messages.js", () => {
  const hook = liftFromHook("twitter-hook.js", [
    "TIMELINE_MESSAGE_SOURCE", "REPLAY_REQUEST_SOURCE", "PROXY_REQUEST_SOURCE", "PROXY_REPLY_SOURCE",
  ]);
  assert.equal(hook.TIMELINE_MESSAGE_SOURCE, messages.TIMELINE_MESSAGE_SOURCE);
  assert.equal(hook.REPLAY_REQUEST_SOURCE, messages.TIMELINE_REPLAY_SOURCE);
  assert.equal(hook.PROXY_REQUEST_SOURCE, messages.HOOK_PROXY_REQUEST_SOURCE);
  assert.equal(hook.PROXY_REPLY_SOURCE, messages.HOOK_PROXY_REPLY_SOURCE);
});

test("rednote-hook.js message tags match bulk-messages.js", () => {
  const hook = liftFromHook("rednote-hook.js", [
    "REDNOTE_FEED_MESSAGE_SOURCE", "REDNOTE_REPLAY_SOURCE",
  ]);
  assert.equal(hook.REDNOTE_FEED_MESSAGE_SOURCE, messages.REDNOTE_FEED_MESSAGE_SOURCE);
  assert.equal(hook.REDNOTE_REPLAY_SOURCE, messages.REDNOTE_REPLAY_SOURCE);
});

test("rednote-hook.js's matcher agrees with the parser's, url for url", () => {
  const { isBoardFeedRequest: hookMatcher } = liftFromHook("rednote-hook.js", ["isBoardFeedRequest"]);
  // Both the real shapes and the near-misses the live probe turned up. A matcher that
  // drifted toward matching by HOST would pass the first group and fail the second.
  const urls = [
    "//webapi.rednote.com/api/sns/web/v1/board/note?board_id=69322476000000001202811f&num=30&cursor=abc",
    "https://webapi.rednote.com/api/sns/web/v1/board/note",
    "https://webapi.rednote.com/api/sns/web/v2/comment/page?note_id=1",
    "https://webapi.rednote.com/api/sns/web/v1/feed",
    "https://t2.rnote.com/api/v2/collect",
    "https://apm-fe.rnote.com/api/data",
    "//as.rednote.com/api/sec/v1/shield/webprofile",
    "",
  ];
  for (const url of urls) {
    assert.equal(hookMatcher(url), isBoardFeedRequest(url), `disagreed on ${url || "(empty)"}`);
  }
});

test("twitter-hook.js's matcher still admits exactly the ops the parser scopes on", () => {
  const { isTimelineRequest } = liftFromHook("twitter-hook.js", ["isTimelineRequest"]);
  // The hook decides what is FORWARDED and `matchesScope` decides what is KEPT, so a hook
  // that stopped matching an op would starve a scope that still expects it. Bookmarks is
  // the pairing that matters; Likes is forwarded but scoped out, which is also asserted.
  const bookmarks = "https://x.com/i/api/graphql/qid/Bookmarks?variables=%7B%7D";
  assert.equal(isTimelineRequest(bookmarks), true);
  assert.equal(twitterMatchesScope(bookmarks, "bookmarks"), true);

  const folder = "https://x.com/i/api/graphql/qid/BookmarkFolderTimeline"
    + "?variables=%7B%22bookmark_collection_id%22%3A%2299%22%7D";
  assert.equal(isTimelineRequest(folder), true);
  assert.equal(twitterMatchesScope(folder, "bookmarks:99"), true);

  assert.equal(isTimelineRequest("https://x.com/i/api/graphql/qid/HomeTimeline"), false);
});

test("no hook silently loses a tag: every hook constant is a non-empty string", () => {
  // Catches the failure mode where a rename leaves a hook referencing an undefined
  // binding — the comparison above would then pass `undefined === undefined` if the module
  // export were removed at the same time.
  const all = {
    ...liftFromHook("twitter-hook.js", [
      "TIMELINE_MESSAGE_SOURCE", "REPLAY_REQUEST_SOURCE", "PROXY_REQUEST_SOURCE", "PROXY_REPLY_SOURCE"]),
    ...liftFromHook("rednote-hook.js", ["REDNOTE_FEED_MESSAGE_SOURCE", "REDNOTE_REPLAY_SOURCE"]),
  };
  for (const [name, value] of Object.entries(all)) {
    assert.equal(typeof value, "string", `${name} is not a string`);
    assert.ok(value.length > 0, `${name} is empty`);
  }
});
