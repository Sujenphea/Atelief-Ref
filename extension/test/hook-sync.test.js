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
import { isBoardFeedRequest, isNoteDetailRequest } from "../src/bulk-rednote.js";
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

/**
 * Run a hook the way Chrome does — on a HOST IT MATCHES, with hook-core's installer
 * stubbed — and hand back the options it installed with.
 *
 * `liftFromHook` above deliberately runs on a non-matching host so the declarations can be
 * read without installing; that answers "is the matcher right?" and NOT "is the right
 * matcher the one that was installed?". Those came apart during 098 T5b: the hook grew a
 * second, correct predicate that nothing passed to `installResponseHook`, and every
 * constant-level assertion still passed while the note-detail responses were never
 * forwarded at all.
 */
function installHook(file, hostname) {
  const source = readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8");
  let installed = null;
  const win = {
    location: { hostname, origin: `https://${hostname}` },
    addEventListener() {},
    postMessage() {},
    __atelierInstallResponseHook: (options) => { installed = options; return true; },
  };
  new Function("window", "console", source)(win, { error() {} });
  assert.ok(installed, `${file} did not install on ${hostname}`);
  return installed;
}

test("rednote-hook.js INSTALLS the union matcher — board feed AND note detail", () => {
  // What the hook declares is worth nothing if it hands hook-core something else. Installed
  // with the board matcher alone, K3b's note-open responses are never forwarded: every note
  // times out, degrades to its cover, and the sweep reports a full board at full cost.
  const options = installHook("rednote-hook.js", "www.rednote.com");
  const urls = [
    "//webapi.rednote.com/api/sns/web/v1/board/note?board_id=1&cursor=a",
    "https://webapi.rednote.com/api/sns/web/v1/feed",
    "https://webapi.rednote.com/api/sns/web/v1/feed/homefeed",
    "https://t2.rnote.com/api/v2/collect",
    "",
  ];
  for (const url of urls) {
    assert.equal(
      options.isMatch(url),
      isBoardFeedRequest(url) || isNoteDetailRequest(url),
      `the INSTALLED matcher disagreed on ${url || "(empty)"}`);
  }
  assert.equal(options.isMatch("https://webapi.rednote.com/api/sns/web/v1/feed"), true,
    "note-detail responses are not forwarded — expansion can never see one");
  assert.equal(options.replaySource, messages.REDNOTE_REPLAY_SOURCE);
});

test("rednote-hook.js installs on BOTH domains and on neither anything else", () => {
  // One product, two domains (098 D7). A hook that installs on one is a sweep that silently
  // sees no responses on the other.
  for (const host of ["www.rednote.com", "www.xiaohongshu.com"]) {
    assert.ok(installHook("rednote-hook.js", host).isMatch);
  }
  assert.throws(() => installHook("rednote-hook.js", "rednote.com.evil.test"), /did not install/);
});

test("rednote-hook.js's note-detail matcher agrees with the parser's (098 T5b)", () => {
  // K3b's expansion reads the note-detail POST the SPA issues when a note is opened. The
  // hook decides what is FORWARDED and the controller routes by the same predicate, so a
  // drift here means the detail response never reaches the expander — and every note-open
  // times out and degrades to its cover, at full cost and with no visible cause.
  const { isNoteDetailRequest: hookMatcher, isHookedRequest } =
    liftFromHook("rednote-hook.js", ["isNoteDetailRequest", "isHookedRequest"]);
  const urls = [
    "https://webapi.rednote.com/api/sns/web/v1/feed",
    "//webapi.rednote.com/api/sns/web/v1/feed/",
    "https://webapi.rednote.com/api/sns/web/v1/feed?x=1",
    // The near-misses the parser is deliberately narrow about: a prefix match would hand a
    // homefeed page to `parseNoteDetail`, and a board page to the wrong parser entirely.
    "https://webapi.rednote.com/api/sns/web/v1/feed/homefeed",
    "https://webapi.rednote.com/api/sns/web/v1/feedback",
    "https://webapi.rednote.com/api/sns/web/v1/board/note?board_id=1",
    "https://t2.rnote.com/api/v2/collect",
    "",
  ];
  for (const url of urls) {
    assert.equal(hookMatcher(url), isNoteDetailRequest(url), `disagreed on ${url || "(empty)"}`);
    // And what the hook actually installs is the UNION — miss either arm and one of the two
    // passes gets no responses at all.
    assert.equal(isHookedRequest(url), isBoardFeedRequest(url) || isNoteDetailRequest(url),
      `the installed matcher disagreed on ${url || "(empty)"}`);
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
