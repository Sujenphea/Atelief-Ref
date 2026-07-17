// 010 · Phase 3 — the extension↔app version handshake. The app's GET /health
// reports its version + the extension range it supports; the extension compares
// its own manifest version and warns on a mismatch. Pure comparators + a thin
// fetch wrapper (fetch injected, no network).

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  parseVersion, compareVersions, checkExtensionCompatibility, fetchHealth,
  TOKEN_HEADER, DEFAULT_BASE,
} from "../src/endpoint.js";

test("parseVersion handles dotted, short, and garbage inputs", () => {
  assert.deepEqual(parseVersion("1.2.3"), [1, 2, 3]);
  assert.deepEqual(parseVersion("2"), [2]);
  assert.deepEqual(parseVersion(""), [0]);
  assert.deepEqual(parseVersion(undefined), [0]);
  assert.deepEqual(parseVersion("1.x.4"), [1, 0, 4]);
});

test("compareVersions orders correctly across differing lengths", () => {
  assert.equal(compareVersions("1.0.0", "1.0.0"), 0);
  assert.equal(compareVersions("1.0", "1.0.0"), 0);
  assert.equal(compareVersions("1.2.0", "1.10.0"), -1);
  assert.equal(compareVersions("2.0.0", "1.9.9"), 1);
  assert.equal(compareVersions("0.1.0", "0.1.1"), -1);
});

test("in-range extension is compatible", () => {
  const health = { appVersion: "0.1.0", minExtensionVersion: "0.1.0", maxExtensionVersion: "0.1.0" };
  const r = checkExtensionCompatibility("0.1.0", health);
  assert.equal(r.compatible, true);
  assert.equal(r.reason, null);
  assert.equal(r.appVersion, "0.1.0");
});

test("too-old extension is flagged to update the extension", () => {
  const health = { appVersion: "0.3.0", minExtensionVersion: "0.2.0", maxExtensionVersion: "0.3.0" };
  const r = checkExtensionCompatibility("0.1.0", health);
  assert.equal(r.compatible, false);
  assert.match(r.reason, /Update the extension/);
});

test("too-new extension is flagged to update the app", () => {
  const health = { appVersion: "0.1.0", minExtensionVersion: "0.1.0", maxExtensionVersion: "0.1.0" };
  const r = checkExtensionCompatibility("0.2.0", health);
  assert.equal(r.compatible, false);
  assert.match(r.reason, /Update the app/);
});

test("a missing range (pre-handshake app) is treated as compatible", () => {
  assert.equal(checkExtensionCompatibility("9.9.9", { appVersion: "0.0.1" }).compatible, true);
  assert.equal(checkExtensionCompatibility("9.9.9", {}).compatible, true);
});

test("fetchHealth: reachable + compatible on a healthy handshake, sends the token", async () => {
  let sentUrl = null;
  let sentHeaders = null;
  const fetchImpl = async (url, opts) => {
    sentUrl = url;
    sentHeaders = opts.headers;
    return {
      ok: true,
      json: async () => ({ appVersion: "0.1.0", minExtensionVersion: "0.1.0", maxExtensionVersion: "0.1.0" }),
    };
  };
  const r = await fetchHealth("0.1.0", { token: "secret", fetchImpl });
  assert.equal(sentUrl, `${DEFAULT_BASE}/health`);
  assert.equal(sentHeaders[TOKEN_HEADER], "secret");
  assert.equal(r.reachable, true);
  assert.equal(r.compatible, true);
  assert.equal(r.appVersion, "0.1.0");
});

test("fetchHealth: a network failure reports unreachable (not incompatible)", async () => {
  const fetchImpl = async () => { throw new Error("ECONNREFUSED"); };
  const r = await fetchHealth("0.1.0", { fetchImpl });
  assert.equal(r.reachable, false);
  assert.equal(r.compatible, true); // can't judge when the app is down
});

test("fetchHealth: a 403 (unpaired) is reachable but doesn't judge compatibility", async () => {
  const fetchImpl = async () => ({ ok: false, status: 403, json: async () => ({}) });
  const r = await fetchHealth("0.1.0", { fetchImpl });
  assert.equal(r.reachable, true);
  assert.equal(r.compatible, true);
  assert.equal(r.status, 403);
});
