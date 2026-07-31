// Atelier Capture — loopback port resolution (301).
//
// The bug these exist for: the extension hard-coded 47321, change 299 moved the
// DEV app to 47322, and every request then failed with an opaque
// `TypeError: Failed to fetch` — a sweep died on its opening `POST /jobs`.
//
// The two properties that matter are STABLE-FIRST precedence (299's rule: the
// shipping bundle owns 47321) and NOT hunting for a port when the app answered
// and simply said no — a 409 must surface as a 409, not as a port problem.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  STABLE_BASE, DEV_BASE, CANDIDATE_BASES, BASE_OVERRIDE_KEY, BASE_CACHE_KEY,
  candidateOrder, isNetworkError, makeMemoryStorage, probeBase, resolveBase,
  invalidateBase, withBase,
} from "../src/base-url.js";

/** A fetch that answers on `liveBases` and throws Chrome's refused-connection
 * TypeError everywhere else — exactly the shape of the reported failure. */
function fakeNet(liveBases, { status = 403 } = {}) {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    if (liveBases.some((b) => url.startsWith(b))) {
      return { status, json: async () => ({}) };
    }
    throw new TypeError("Failed to fetch");
  };
  return { fetchImpl, calls };
}

// --- candidateOrder --------------------------------------------------------

test("candidateOrder: no override probes stable first, then dev", () => {
  assert.deepEqual(candidateOrder(null), [STABLE_BASE, DEV_BASE]);
  assert.deepEqual(candidateOrder("auto"), [STABLE_BASE, DEV_BASE]);
  assert.deepEqual(CANDIDATE_BASES, [STABLE_BASE, DEV_BASE]);
});

test("candidateOrder: a pinned base is the only candidate, trailing slash trimmed", () => {
  assert.deepEqual(candidateOrder("http://127.0.0.1:47322/"), [DEV_BASE]);
});

test("candidateOrder: a garbage pin is ignored rather than bricking capture", () => {
  assert.deepEqual(candidateOrder("not a url"), [STABLE_BASE, DEV_BASE]);
  assert.deepEqual(candidateOrder(""), [STABLE_BASE, DEV_BASE]);
});

// --- isNetworkError --------------------------------------------------------

test("isNetworkError: Chrome's refused-connection TypeError counts", () => {
  assert.equal(isNetworkError(new TypeError("Failed to fetch")), true);
  assert.equal(isNetworkError(Object.assign(new Error("x"), { name: "AbortError" })), true);
});

test("isNetworkError: an app-level error does NOT trigger a port hunt", () => {
  assert.equal(isNetworkError(new Error("open job failed (HTTP 409)")), false);
  assert.equal(isNetworkError(null), false);
});

// --- probeBase -------------------------------------------------------------

test("probeBase: a token-gated 403 still proves the app is listening", async () => {
  const { fetchImpl, calls } = fakeNet([STABLE_BASE], { status: 403 });
  assert.equal(await probeBase(STABLE_BASE, { fetchImpl }), true);
  assert.match(calls[0], /\/health$/);
});

test("probeBase: a refused connection is not listening", async () => {
  const { fetchImpl } = fakeNet([]);
  assert.equal(await probeBase(STABLE_BASE, { fetchImpl }), false);
});

// --- resolveBase -----------------------------------------------------------

test("resolveBase: finds the DEV app when only it is running (the reported bug)", async () => {
  const { fetchImpl } = fakeNet([DEV_BASE]);
  const storage = makeMemoryStorage();
  assert.equal(await resolveBase({ fetchImpl, storage }), DEV_BASE);
});

test("resolveBase: prefers stable when BOTH are running", async () => {
  const { fetchImpl } = fakeNet([STABLE_BASE, DEV_BASE]);
  const storage = makeMemoryStorage();
  assert.equal(await resolveBase({ fetchImpl, storage }), STABLE_BASE);
});

test("resolveBase: caches the winner so a sweep probes once, not per item", async () => {
  const { fetchImpl, calls } = fakeNet([DEV_BASE]);
  const storage = makeMemoryStorage();
  await resolveBase({ fetchImpl, storage });
  const afterFirst = calls.length;
  await resolveBase({ fetchImpl, storage });
  assert.equal(calls.length, afterFirst, "second resolve should not re-probe");
  assert.equal(await storage.load(BASE_CACHE_KEY), DEV_BASE);
});

test("resolveBase: a pinned override wins outright and never probes", async () => {
  const { fetchImpl, calls } = fakeNet([STABLE_BASE, DEV_BASE]);
  const storage = makeMemoryStorage({ [BASE_OVERRIDE_KEY]: DEV_BASE });
  assert.equal(await resolveBase({ fetchImpl, storage }), DEV_BASE);
  assert.equal(calls.length, 0);
});

test("resolveBase: nothing reachable returns the first candidate, no throw", async () => {
  const { fetchImpl } = fakeNet([]);
  const storage = makeMemoryStorage();
  // The caller's own request then produces the real, attributable error.
  assert.equal(await resolveBase({ fetchImpl, storage }), STABLE_BASE);
});

test("invalidateBase: forces the next resolve to re-probe", async () => {
  const storage = makeMemoryStorage({ [BASE_CACHE_KEY]: STABLE_BASE });
  await invalidateBase(storage);
  assert.equal(await storage.load(BASE_CACHE_KEY), null);
});

// --- withBase --------------------------------------------------------------

test("withBase: a refused connection re-probes and retries on the other port", async () => {
  // Cached stable, but only the dev app is actually up — the exact state after
  // quitting the stable build and running the dev one mid-session.
  const storage = makeMemoryStorage({ [BASE_CACHE_KEY]: STABLE_BASE });
  const { fetchImpl } = fakeNet([DEV_BASE]);
  const attempted = [];
  const result = await withBase(async (base) => {
    attempted.push(base);
    if (base === STABLE_BASE) throw new TypeError("Failed to fetch");
    return "ok";
  }, { fetchImpl, storage });

  assert.equal(result, "ok");
  assert.deepEqual(attempted, [STABLE_BASE, DEV_BASE]);
  assert.equal(await storage.load(BASE_CACHE_KEY), DEV_BASE);
});

test("withBase: an app-level error propagates without a retry", async () => {
  const storage = makeMemoryStorage({ [BASE_CACHE_KEY]: STABLE_BASE });
  const { fetchImpl } = fakeNet([STABLE_BASE, DEV_BASE]);
  let attempts = 0;
  await assert.rejects(() => withBase(async () => {
    attempts += 1;
    throw new Error("open job failed (HTTP 409)");
  }, { fetchImpl, storage }), /409/);
  assert.equal(attempts, 1);
});

test("withBase: nothing anywhere surfaces the ORIGINAL error, not a duplicate try", async () => {
  const storage = makeMemoryStorage();
  const { fetchImpl } = fakeNet([]);
  let attempts = 0;
  await assert.rejects(() => withBase(async () => {
    attempts += 1;
    throw new TypeError("Failed to fetch");
  }, { fetchImpl, storage }), /Failed to fetch/);
  // Both resolves land on the same (unreachable) first candidate, so exactly one try.
  assert.equal(attempts, 1);
});
