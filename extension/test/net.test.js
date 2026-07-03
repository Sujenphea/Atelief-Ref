// Atelier Capture — fetchWithTimeout tests.
//
// A hung CDN must become a clean rejection (not an indefinite wedge), and the
// helper must not alter the caller's request beyond attaching an abort signal.
// fetch is injected — no network, no real timers past a few ms.

import { test } from "node:test";
import assert from "node:assert/strict";

import { fetchWithTimeout, DEFAULT_TIMEOUT_MS } from "../src/net.js";

test("fetchWithTimeout: returns the response when fetch resolves before the deadline", async () => {
  const response = { ok: true };
  let seenSignal;
  const fakeFetch = async (_url, init) => {
    seenSignal = init.signal;
    return response;
  };
  const result = await fetchWithTimeout("https://x/y", { method: "GET" }, { fetchImpl: fakeFetch });

  assert.equal(result, response);
  assert.ok(seenSignal instanceof AbortSignal); // a signal was threaded through
  assert.equal(seenSignal.aborted, false); // and cleared, not aborted, on success
});

test("fetchWithTimeout: rejects when the request hangs past the timeout", async () => {
  // A fetch that never settles until its signal aborts — the hung-CDN case.
  const hangingFetch = (_url, { signal }) =>
    new Promise((_, reject) => {
      signal.addEventListener("abort", () => reject(new Error("aborted")));
    });
  await assert.rejects(
    () => fetchWithTimeout("https://x/y", {}, { timeoutMs: 10, fetchImpl: hangingFetch }),
    /aborted/
  );
});

test("fetchWithTimeout: preserves caller opts and has a sane default deadline", async () => {
  let seen;
  const fakeFetch = async (_url, init) => {
    seen = init;
    return { ok: true };
  };
  await fetchWithTimeout(
    "https://x/y",
    { headers: { Accept: "text/html" }, credentials: "omit" },
    { fetchImpl: fakeFetch }
  );
  assert.equal(seen.headers.Accept, "text/html");
  assert.equal(seen.credentials, "omit");
  assert.ok(DEFAULT_TIMEOUT_MS > 0);
});
