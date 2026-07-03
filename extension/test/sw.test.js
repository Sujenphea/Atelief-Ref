// Atelier Capture — service-worker core tests (decisions 9A + 8A + 13A).
//
// captureCore is the pure decision function: given a harvest, right-click context
// and token, it returns a semantic result (the glue maps that to a badge). All
// collaborators are injected, so the whole branch matrix — video vs image,
// fail-open fallback, the 8A expected/unexpected split, no-image/no-token, ingest
// vs unreachable — is asserted with no chrome.* and no network. fetchImage is
// tested directly (candidate fallback, non-image rejection, chunked base64).

import { test } from "node:test";
import assert from "node:assert/strict";

import { captureCore, fetchImage, presentation, downloadAndIngestVideo } from "../src/sw.js";

const PROV = {
  platform: "twitter",
  mediaUrl: "https://pbs.twimg.com/media/A?name=orig",
  mediaUrlFallback: null,
  rawMetadata: { tweetId: "42", pinId: "9" },
};

/** A complete deps object with safe no-op defaults; override per test. */
function makeDeps(over = {}) {
  const calls = { log: [], logError: [] };
  const deps = {
    extractProvenance: () => PROV,
    twitterHasVideo: () => false,
    pinterestHasVideo: () => false,
    resolveTwitterVideo: async () => { throw new Error("no video"); },
    resolvePinterestVideo: async () => { throw new Error("no video"); },
    downloadAndIngestVideo: async () => ({ deduplicated: false }),
    fetchImage: async () => ({ base64: "B64", url: PROV.mediaUrl, contentType: "image/jpeg", byteLength: 3 }),
    buildCaptureRequest: (p, b) => ({ image: b, provenance: p }),
    postCapture: async () => ({ status: 200, body: { deduplicated: false } }),
    log: (...a) => calls.log.push(a),
    logError: (...a) => calls.logError.push(a),
    ...over,
  };
  return { deps, calls };
}

// MARK: - captureCore branch matrix

test("no mediaUrl → no-image", async () => {
  const { deps } = makeDeps({ extractProvenance: () => ({ mediaUrl: null }) });
  assert.deepEqual(await captureCore({}, {}, "tok", deps), { status: "no-image" });
});

test("missing token → no-token (after the image check)", async () => {
  const { deps } = makeDeps();
  assert.deepEqual(await captureCore({}, {}, "", deps), { status: "no-token" });
});

test("plain image → saved (not deduplicated)", async () => {
  const { deps } = makeDeps();
  assert.deepEqual(await captureCore({}, {}, "tok", deps), {
    status: "saved", kind: "image", deduplicated: false,
  });
});

test("image already present → saved + deduplicated", async () => {
  const { deps } = makeDeps({
    postCapture: async () => ({ status: 200, body: { deduplicated: true } }),
  });
  const r = await captureCore({}, {}, "tok", deps);
  assert.equal(r.status, "saved");
  assert.equal(r.deduplicated, true);
});

test("twitter video → resolved + ingested as video", async () => {
  const { deps } = makeDeps({
    twitterHasVideo: () => true,
    resolveTwitterVideo: async () => "https://video.twimg.com/hi.mp4",
    downloadAndIngestVideo: async () => ({ deduplicated: false }),
  });
  assert.deepEqual(await captureCore({}, {}, "tok", deps), {
    status: "saved", kind: "video", deduplicated: false,
  });
});

test("8A: video RESOLUTION fails → quiet log, falls back to image", async () => {
  const { deps, calls } = makeDeps({
    twitterHasVideo: () => true,
    resolveTwitterVideo: async () => { throw new Error("syndication 404"); },
  });
  const r = await captureCore({}, {}, "tok", deps);
  assert.equal(r.status, "saved");
  assert.equal(r.kind, "image"); // fell back
  assert.equal(calls.log.length, 1);      // expected path → log
  assert.equal(calls.logError.length, 0); // NOT an error
});

test("8A: RESOLVED video fails to download/ingest → loud logError, still falls back to image", async () => {
  const { deps, calls } = makeDeps({
    twitterHasVideo: () => true,
    resolveTwitterVideo: async () => "https://video.twimg.com/hi.mp4",
    downloadAndIngestVideo: async () => { throw new Error("ingest 500"); },
  });
  const r = await captureCore({}, {}, "tok", deps);
  assert.equal(r.status, "saved");
  assert.equal(r.kind, "image"); // fell back
  assert.equal(calls.logError.length, 1); // unexpected path → logError
});

test("non-200 ingest → ingest-error with the server message", async () => {
  const { deps } = makeDeps({
    postCapture: async () => ({ status: 422, body: { error: "unsupported type" } }),
  });
  assert.deepEqual(await captureCore({}, {}, "tok", deps), {
    status: "ingest-error", message: "unsupported type",
  });
});

test("postCapture throws (app down) → unreachable", async () => {
  const { deps } = makeDeps({
    postCapture: async () => { throw new Error("ECONNREFUSED"); },
  });
  assert.deepEqual(await captureCore({}, {}, "tok", deps), { status: "unreachable" });
});

test("fetchImage throws (all candidates fail) → fetch-error", async () => {
  const { deps } = makeDeps({
    fetchImage: async () => { throw new Error("HTTP 404"); },
  });
  const r = await captureCore({}, {}, "tok", deps);
  assert.equal(r.status, "fetch-error");
  assert.match(r.message, /HTTP 404/);
});

// MARK: - presentation

test("presentation maps every status to a badge", () => {
  assert.equal(presentation({ status: "no-image" }).text, "?");
  assert.equal(presentation({ status: "no-token" }).text, "KEY");
  assert.equal(presentation({ status: "saved", kind: "image", deduplicated: false }).title, "Saved to Atelier.");
  assert.equal(presentation({ status: "saved", kind: "video", deduplicated: false }).title, "Saved video to Atelier.");
  assert.equal(presentation({ status: "saved", kind: "image", deduplicated: true }).title, "Already saved.");
  assert.equal(presentation({ status: "ingest-error", message: "x" }).text, "ERR");
  assert.equal(presentation({ status: "unreachable" }).text, "ERR");
});

// MARK: - fetchImage

/** A fake fetch returning image bytes with a given content-type / status. */
function imageFetch({ ok = true, status = 200, contentType = "image/jpeg", bytes = [72, 105] }) {
  return async () => ({
    ok,
    status,
    headers: { get: () => contentType },
    arrayBuffer: async () => new Uint8Array(bytes).buffer,
  });
}

test("fetchImage: encodes bytes to base64 (chunked path, same output as btoa)", async () => {
  const result = await fetchImage(["https://cdn/a.jpg"], { fetchImpl: imageFetch({ bytes: [72, 105] }) });
  assert.equal(result.base64, Buffer.from([72, 105]).toString("base64")); // "SGk="
  assert.equal(result.byteLength, 2);
  assert.equal(result.contentType, "image/jpeg");
});

test("fetchImage: skips a non-image response, falls through to the next candidate", async () => {
  let call = 0;
  const fetchImpl = async () => {
    call += 1;
    if (call === 1) return { ok: true, status: 200, headers: { get: () => "text/html" }, arrayBuffer: async () => new Uint8Array().buffer };
    return { ok: true, status: 200, headers: { get: () => "image/png" }, arrayBuffer: async () => new Uint8Array([1, 2]).buffer };
  };
  const result = await fetchImage(["https://cdn/orig.jpg", "https://cdn/rendered.jpg"], { fetchImpl });
  assert.equal(result.url, "https://cdn/rendered.jpg");
  assert.equal(call, 2);
});

test("fetchImage: an HTTP error skips to the next candidate", async () => {
  let call = 0;
  const fetchImpl = async () => {
    call += 1;
    if (call === 1) return { ok: false, status: 404, headers: { get: () => "" }, arrayBuffer: async () => new Uint8Array().buffer };
    return { ok: true, status: 200, headers: { get: () => "image/jpeg" }, arrayBuffer: async () => new Uint8Array([9]).buffer };
  };
  const result = await fetchImage(["https://cdn/a", "https://cdn/b"], { fetchImpl });
  assert.equal(result.url, "https://cdn/b");
});

test("fetchImage: throws when every candidate fails", async () => {
  await assert.rejects(
    () => fetchImage(["https://cdn/a"], { fetchImpl: imageFetch({ ok: false, status: 500 }) }),
    /HTTP 500/
  );
});

// MARK: - downloadAndIngestVideo (client-side size cap)

test("downloadAndIngestVideo: rejects an over-cap clip by Content-Length before reading the body", async () => {
  let blobRead = false;
  const headers = {
    get: (h) =>
      h === "content-length" ? String(600 * 1024 * 1024) // > 512 MB cap
        : h === "content-type" ? "video/mp4" : "",
  };
  const fetchImpl = async () => ({
    ok: true,
    headers,
    blob: async () => { blobRead = true; return {}; },
  });
  await assert.rejects(
    () => downloadAndIngestVideo({}, "https://v/x.mp4", "tok", { fetchImpl }),
    /too large/
  );
  assert.equal(blobRead, false); // aborted before downloading the body
});
