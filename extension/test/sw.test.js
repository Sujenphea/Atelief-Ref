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

import { captureCore, ingestOne, fetchImage, presentation, downloadAndIngestVideo } from "../src/sw.js";

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
    // Default OFF: a non-tweet (or bulk) stays on the plain image path. Tweet
    // routing (003 · C3) is opted into per-test by overriding tweetContent.
    tweetContent: () => null,
    buildContentCaptureRequest: (p, b, content) =>
      ({ image: b, provenance: p, kind: content.kind, payload: content.payload }),
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

test("non-200 ingest → ingest-error with the server message + httpStatus (5A)", async () => {
  const { deps } = makeDeps({
    postCapture: async () => ({ status: 422, body: { error: "unsupported type" } }),
  });
  assert.deepEqual(await captureCore({}, {}, "tok", deps), {
    status: "ingest-error", httpStatus: 422, message: "unsupported type",
  });
});

test("ingestOne: a 401/403 ingest surfaces httpStatus so the engine can auth-halt (5A)", async () => {
  const { deps } = makeDeps({
    postCapture: async () => ({ status: 403, body: { error: "forbidden" } }),
  });
  const r = await ingestOne(PROV, { token: "bad" }, deps);
  assert.equal(r.status, "ingest-error");
  assert.equal(r.httpStatus, 403); // classifyIngestResult turns this into a resumable halt
});

test("ingestOne: a failed image fetch threads the CDN httpStatus through (5A)", async () => {
  const { deps } = makeDeps({
    fetchImage: async () => { throw Object.assign(new Error("HTTP 401 for u"), { httpStatus: 401 }); },
  });
  const r = await ingestOne(PROV, { token: "tok" }, deps);
  assert.equal(r.status, "fetch-error");
  assert.equal(r.httpStatus, 401);
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

// MARK: - ingestOne (the shared tail, 5A) — the bulk engine reuses this directly

test("ingestOne: image path posts and returns saved", async () => {
  const { deps } = makeDeps();
  const r = await ingestOne(PROV, { token: "tok" }, deps);
  assert.deepEqual(r, { status: "saved", kind: "image", deduplicated: false });
});

// MARK: - tweet content capture (003 · C3, Option 3)

test("ingestOne: a content descriptor posts a content capture (card image + payload)", async () => {
  let posted = null;
  const content = { kind: "tweet", payload: { tweet: { tweetID: "42", media: [] } } };
  const { deps } = makeDeps({
    postCapture: async (req) => { posted = req; return { status: 200, body: { deduplicated: false } }; },
  });
  const r = await ingestOne(PROV, { token: "tok", content }, deps);

  assert.deepEqual(r, { status: "saved", kind: "tweet", deduplicated: false });
  assert.equal(posted.image, "B64");          // the SAME card-image bytes ride in
  assert.equal(posted.kind, "tweet");
  assert.deepEqual(posted.payload, content.payload);
});

test("ingestOne: no content descriptor stays on the plain image body", async () => {
  let posted = null;
  const { deps } = makeDeps({
    postCapture: async (req) => { posted = req; return { status: 200, body: { deduplicated: false } }; },
  });
  await ingestOne(PROV, { token: "tok" }, deps);
  assert.equal("kind" in posted, false);       // plain image request — no kind/payload
});

test("ingestOne: a text-only tweet (no media url) posts a media-less content capture", async () => {
  // A bulk text-only tweet: content descriptor present, but NO card image to fetch. It
  // must post kind+payload with no image (→ the server's `.content` text-card path) and
  // never touch fetchImage.
  let posted = null;
  let fetched = false;
  const content = { kind: "tweet", payload: { tweet: { tweetID: "7", media: [], text: "just text" } } };
  const { deps } = makeDeps({
    fetchImage: async () => { fetched = true; throw new Error("must not fetch"); },
    buildContentCaptureRequest: (p, b, c) => {
      const req = { provenance: p, kind: c.kind, payload: c.payload };
      if (b) req.image = b;                    // omit image when there are no bytes
      return req;
    },
    postCapture: async (req) => { posted = req; return { status: 200, body: { deduplicated: false } }; },
  });
  const prov = { platform: "twitter", mediaUrl: null, rawMetadata: { tweetId: "7" } };
  const r = await ingestOne(prov, { token: "tok", content }, deps);

  assert.deepEqual(r, { status: "saved", kind: "tweet", deduplicated: false });
  assert.equal(fetched, false);                // no image fetch for a media-less tweet
  assert.equal("image" in posted, false);      // media-less content body → no image key
  assert.equal(posted.kind, "tweet");
});

test("ingestOne: a FETCH FAILURE is never downgraded to a media-less card (auth-wall preserved)", async () => {
  // A tweet WITH a card image whose fetch 401s must surface fetch-error (so the engine
  // auth-halts), NOT silently post a text card — the media-less path is only for a tweet
  // that never had a media URL.
  const content = { kind: "tweet", payload: { tweet: { tweetID: "7", media: [{ url: "u" }] } } };
  const { deps } = makeDeps({
    fetchImage: async () => { throw Object.assign(new Error("HTTP 401 for u"), { httpStatus: 401 }); },
  });
  const r = await ingestOne(PROV, { token: "tok", content }, deps);
  assert.equal(r.status, "fetch-error");
  assert.equal(r.httpStatus, 401);
});

test("captureCore: a usable tweet routes through the content capture (still image)", async () => {
  let posted = null;
  const content = { kind: "tweet", payload: { tweet: { tweetID: "42", media: [] } } };
  const { deps } = makeDeps({
    tweetContent: () => content,
    postCapture: async (req) => { posted = req; return { status: 200, body: { deduplicated: false } }; },
  });
  const r = await captureCore({}, {}, "tok", deps);
  assert.deepEqual(r, { status: "saved", kind: "tweet", deduplicated: false });
  assert.equal(posted.kind, "tweet");
});

test("captureCore: a text-only tweet (no image) saves as a media-less text card", async () => {
  // The focal tweet has no image → provenance.mediaUrl is null, but tweetContent yields
  // a usable tweet, so captureCore POSTs a media-less content capture instead of bailing
  // "no-image". (The comment-image bug fix: a text-only tweet no longer borrows a reply's
  // image, so it correctly lands as a text card.)
  let posted = null;
  const content = { kind: "tweet", payload: { tweet: { tweetID: "42", media: [], text: "hi" } } };
  const { deps } = makeDeps({
    extractProvenance: () => ({ platform: "twitter", mediaUrl: null, rawMetadata: { tweetId: "42" } }),
    tweetContent: () => content,
    buildContentCaptureRequest: (p, b, c) => {
      const req = { provenance: p, kind: c.kind, payload: c.payload };
      if (b) req.image = b;
      return req;
    },
    postCapture: async (req) => { posted = req; return { status: 200, body: { deduplicated: false } }; },
  });
  const r = await captureCore({}, {}, "tok", deps);
  assert.deepEqual(r, { status: "saved", kind: "tweet", deduplicated: false });
  assert.equal("image" in posted, false); // media-less text card
});

test("captureCore: no image AND no tweet content → still no-image", async () => {
  const { deps } = makeDeps({
    extractProvenance: () => ({ mediaUrl: null }),
    tweetContent: () => null, // not a tweet (e.g. a generic page with no media)
  });
  assert.deepEqual(await captureCore({}, {}, "tok", deps), { status: "no-image" });
});

test("captureCore: a tweet WITH video still ingests as video (content path not taken)", async () => {
  // A video tweet resolves + posts a video; the content descriptor is ignored
  // because the image path never runs.
  const { deps } = makeDeps({
    twitterHasVideo: () => true,
    resolveTwitterVideo: async () => "https://v/x.mp4",
    tweetContent: () => ({ kind: "tweet", payload: { tweet: { tweetID: "42", media: [] } } }),
    downloadAndIngestVideo: async () => ({ deduplicated: false }),
  });
  const r = await captureCore({}, {}, "tok", deps);
  assert.deepEqual(r, { status: "saved", kind: "video", deduplicated: false });
});

test("ingestOne: a given mp4Url ingests as video (no harvest/context needed)", async () => {
  const { deps } = makeDeps({
    downloadAndIngestVideo: async () => ({ deduplicated: true }),
  });
  const r = await ingestOne(PROV, { token: "tok", mp4Url: "https://v/x.mp4" }, deps);
  assert.deepEqual(r, { status: "saved", kind: "video", deduplicated: true });
});

test("ingestOne: forwards jobId/sourceId to buildCaptureRequest (bulk tagging)", async () => {
  let seen = null;
  const { deps } = makeDeps({
    buildCaptureRequest: (p, b, opts) => { seen = opts; return { image: b, provenance: p }; },
  });
  await ingestOne(PROV, { token: "tok", jobId: "job-1", sourceId: "pin-7" }, deps);
  assert.deepEqual(seen, { jobId: "job-1", sourceId: "pin-7" });
});

test("ingestOne: surfaces the reply's jobStatus (bulk relay feedback), omits it otherwise", async () => {
  const withStatus = makeDeps({
    postCapture: async () => ({ status: 200, body: { deduplicated: false, jobStatus: "paused" } }),
  });
  const paused = await ingestOne(PROV, { token: "tok", jobId: "j", sourceId: "s" }, withStatus.deps);
  assert.equal(paused.jobStatus, "paused");
  // An untagged/open capture carries no jobStatus key.
  const plain = await ingestOne(PROV, { token: "tok" }, makeDeps().deps);
  assert.equal("jobStatus" in plain, false);
});

test("ingestOne: a resolved video that fails to ingest falls back to the image (loud log)", async () => {
  const { deps, calls } = makeDeps({
    downloadAndIngestVideo: async () => { throw new Error("ingest 500"); },
  });
  const r = await ingestOne(PROV, { token: "tok", mp4Url: "https://v/x.mp4" }, deps);
  assert.equal(r.kind, "image");
  assert.equal(calls.logError.length, 1);
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

test("fetchImage: a MISSING content-type is refused too (3B), not ingested as garbage", async () => {
  // An error / login / HTML interstitial often omits content-type entirely. The old
  // guard only rejected a PRESENT non-image type, so a blank one slipped through and the
  // body was ingested as bogus bytes. Now a blank type falls through like any non-image.
  let call = 0;
  const fetchImpl = async () => {
    call += 1;
    if (call === 1) return { ok: true, status: 200, headers: { get: () => "" }, arrayBuffer: async () => new Uint8Array([1]).buffer };
    return { ok: true, status: 200, headers: { get: () => "image/jpeg" }, arrayBuffer: async () => new Uint8Array([9]).buffer };
  };
  const result = await fetchImage(["https://cdn/no-type", "https://cdn/real.jpg"], { fetchImpl });
  assert.equal(result.url, "https://cdn/real.jpg");
  assert.equal(call, 2);
});

test("fetchImage: when the ONLY candidate has no content-type, it throws (no garbage ingest)", async () => {
  await assert.rejects(
    () => fetchImage(["https://cdn/no-type"], { fetchImpl: imageFetch({ contentType: "" }) }),
    /no content-type/);
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

test("downloadAndIngestVideo: a server cap overrides the local MAX_VIDEO_BYTES default (13A)", async () => {
  let blobRead = false;
  const headers = {
    get: (h) => h === "content-length" ? String(2 * 1024 * 1024)   // 2 MB
      : h === "content-type" ? "video/mp4" : "",
  };
  const fetchImpl = async () => ({ ok: true, headers, blob: async () => { blobRead = true; return {}; } });
  // 2 MB is far under the 512 MB default but OVER a 1 MB server cap → rejected early.
  await assert.rejects(
    () => downloadAndIngestVideo({}, "https://v/x.mp4", "tok", { fetchImpl, maxBytes: 1024 * 1024 }),
    /too large/
  );
  assert.equal(blobRead, false);
});

// MARK: - fetchImage / ingestOne server caps (13A)

/** An image fetch with an explicit Content-Length + content-type (for the size check). */
function sizedImageFetch(contentLength, bytes = [1, 2]) {
  return async () => ({
    ok: true, status: 200,
    headers: { get: (h) => h === "content-length" ? String(contentLength) : h === "content-type" ? "image/jpeg" : "" },
    arrayBuffer: async () => new Uint8Array(bytes).buffer,
  });
}

test("fetchImage: rejects an over-cap image by Content-Length before reading the body (13A)", async () => {
  let bodyRead = false;
  const fetchImpl = async () => ({
    ok: true, status: 200,
    headers: { get: (h) => h === "content-length" ? "5000" : h === "content-type" ? "image/jpeg" : "" },
    arrayBuffer: async () => { bodyRead = true; return new Uint8Array([1]).buffer; },
  });
  await assert.rejects(
    () => fetchImage(["https://cdn/big.jpg"], { fetchImpl, maxBytes: 1000 }),
    /image too large/);
  assert.equal(bodyRead, false); // aborted before downloading the body
});

test("fetchImage: an over-cap candidate falls through to a within-cap fallback (13A)", async () => {
  let call = 0;
  const fetchImpl = async () => {
    call += 1;
    return (call === 1 ? sizedImageFetch(5000) : sizedImageFetch(500, [9]))();
  };
  const result = await fetchImage(["https://cdn/orig", "https://cdn/rendered"], { fetchImpl, maxBytes: 1000 });
  assert.equal(result.url, "https://cdn/rendered"); // the smaller variant fit under the cap
  assert.equal(call, 2);
});

test("fetchImage: no maxBytes (single-item capture) skips the size pre-check (13A)", async () => {
  const result = await fetchImage(["https://cdn/x.jpg"], { fetchImpl: sizedImageFetch(9_999_999) });
  assert.equal(result.byteLength, 2); // ingested despite a large declared size — no cap applied
});

test("ingestOne: threads the job's server caps into the image + video size checks (13A)", async () => {
  const seen = {};
  const { deps } = makeDeps({
    fetchImage: async (_urls, opts) => {
      seen.imageMax = opts && opts.maxBytes;
      return { base64: "B", url: "u", contentType: "image/jpeg", byteLength: 1 };
    },
  });
  await ingestOne(PROV, { token: "tok", caps: { maxBodyBytes: 111, maxVideoBodyBytes: 222 } }, deps);
  assert.equal(seen.imageMax, 111);

  const seenV = {};
  const { deps: vdeps } = makeDeps({
    downloadAndIngestVideo: async (_p, _u, _t, opts) => {
      seenV.videoMax = opts && opts.maxBytes;
      return { deduplicated: false };
    },
  });
  await ingestOne(PROV, { token: "tok", mp4Url: "https://v/x.mp4",
    caps: { maxBodyBytes: 111, maxVideoBodyBytes: 222 } }, vdeps);
  assert.equal(seenV.videoMax, 222);
});

test("ingestOne: no caps (single-item capture) passes null limits — the server backstops (13A)", async () => {
  const seen = {};
  const { deps } = makeDeps({
    fetchImage: async (_urls, opts) => {
      seen.imageMax = opts && opts.maxBytes;
      return { base64: "B", url: "u", contentType: "image/jpeg", byteLength: 1 };
    },
  });
  await ingestOne(PROV, { token: "tok" }, deps);
  assert.equal(seen.imageMax, null);
});
