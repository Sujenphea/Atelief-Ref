// Atelier Capture — Instagram MAIN-world hook config tests (002 · B2, [5A][10A]).
//
// instagram-hook.js is a CLASSIC MAIN-world script (NO export). It's a THIN config over
// hook-core.js (whose machinery is tested in hook-core.test.js); this file pins the two
// things instagram-hook owns — the saved-feed URL matcher and the message tags — plus the
// manifest load-order contract (`["src/hook-core.js", "src/instagram-hook.js"]`).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  IG_SAVED_MESSAGE_SOURCE as MSG_SRC, IG_SAVED_REPLAY_SOURCE as REPLAY_SRC,
} from "../src/bulk-messages.js";

const coreSrc = readFileSync(new URL("../src/hook-core.js", import.meta.url), "utf8");
const igHookSrc = readFileSync(new URL("../src/instagram-hook.js", import.meta.url), "utf8");

// Lift the matcher + tags out of the classic file (a fake `window` with no `.location`
// skips the auto-install tail).
const { isSavedFeedRequest, IG_SAVED_MESSAGE_SOURCE, IG_SAVED_REPLAY_SOURCE } = (() => {
  return new Function(
    "window",
    `${igHookSrc}\nreturn { isSavedFeedRequest, IG_SAVED_MESSAGE_SOURCE, IG_SAVED_REPLAY_SOURCE };`,
  )({});
})();

// MARK: - isSavedFeedRequest

test("isSavedFeedRequest: matches the flat saved-posts feed (± pagination), rejects others", () => {
  assert.equal(isSavedFeedRequest("https://www.instagram.com/api/v1/feed/saved/posts/"), true);
  assert.equal(isSavedFeedRequest("https://www.instagram.com/api/v1/feed/saved/posts/?max_id=ABC123"), true);
  assert.equal(isSavedFeedRequest("/api/v1/feed/saved/posts/"), true); // relative form (XHR.open)
  // A saved COLLECTION loads from a different path — NOT matched in v1 (flat-only, 6A).
  assert.equal(isSavedFeedRequest("https://www.instagram.com/api/v1/feed/collection/123/posts/"), false);
  assert.equal(isSavedFeedRequest("https://www.instagram.com/api/v1/feed/timeline/"), false);
  assert.equal(isSavedFeedRequest("https://scontent.cdninstagram.com/v/t51.jpg"), false);
  assert.equal(isSavedFeedRequest(null), false);
  assert.equal(isSavedFeedRequest(undefined), false);
});

// MARK: - syntax guard + wire-constant sync

test("instagram-hook.js is a valid CLASSIC script (no static export/import → injectable)", () => {
  assert.doesNotThrow(() => new Function("window", igHookSrc));
});

test("hook wire constants stay in sync with bulk-messages (the KEEP IN SYNC duplication)", () => {
  assert.equal(IG_SAVED_MESSAGE_SOURCE, MSG_SRC);
  assert.equal(IG_SAVED_REPLAY_SOURCE, REPLAY_SRC);
});

// MARK: - load-order pairing (hook-core BEFORE the site hook)

/** A fake window an IG hook auto-installs onto: a matching hostname + a cloneable fetch. */
function fakeIgWindow(hostname) {
  const listeners = [];
  return {
    location: { hostname, origin: `https://${hostname}` },
    fetch: async () => ({ clone: () => ({ json: async () => ({}) }) }),
    addEventListener: (type, fn) => { if (type === "message") listeners.push(fn); },
    postMessage: () => {},
  };
}

test("load order [hook-core, instagram-hook]: core first → the IG hook installs", () => {
  const win = fakeIgWindow("www.instagram.com");
  new Function("window", coreSrc)(win);                        // core publishes the installer
  assert.equal(typeof win.__atelierInstallResponseHook, "function");
  new Function("window", "console", igHookSrc)(win, console);  // site auto-installs
  assert.equal(win.__atelierResponseHookInstalled, true);
});

test("wrong order (IG hook without core) fails LOUDLY but never throws into the page", () => {
  const win = fakeIgWindow("www.instagram.com");               // no core → installer absent
  const errors = [];
  const spyConsole = { error: (...a) => errors.push(a.join(" ")) };
  assert.doesNotThrow(() => new Function("window", "console", igHookSrc)(win, spyConsole));
  assert.equal(win.__atelierResponseHookInstalled, undefined); // did NOT install
  assert.equal(errors.length, 1);
  assert.match(errors[0], /hook-core\.js must load before/);
});

test("the IG hook is inert on a non-Instagram host (no install, no error)", () => {
  const win = fakeIgWindow("example.com");
  new Function("window", coreSrc)(win);
  const errors = [];
  new Function("window", "console", igHookSrc)(win, { error: (...a) => errors.push(a) });
  assert.equal(win.__atelierResponseHookInstalled, undefined);
  assert.equal(errors.length, 0);
});
