// Atelier Capture — endpoint contract tests (build-order #6, decision T4).
//
// buildCaptureRequest must produce exactly the shape Swift's CaptureRequest
// decodes; postCapture must send the token + content-type headers and surface
// the status/body. fetch is injected (no network).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  buildCaptureRequest, postCapture, TOKEN_HEADER, DEFAULT_ENDPOINT,
  buildProvenanceHeader, postVideoCapture, base64Utf8,
  PROVENANCE_HEADER, DEFAULT_VIDEO_ENDPOINT,
} from "../src/endpoint.js";

// The shared cross-language contract fixture (decision 1A). The Swift side
// (CaptureDecoderTests) decodes the SAME file, so a field rename on either side
// breaks a test here or there.
const contract = JSON.parse(
  readFileSync(new URL("./fixtures/capture-contract.json", import.meta.url))
);

const fullProvenance = {
  platform: "twitter",
  originalURL: "https://x.com/a/status/1",
  authorHandle: "@a",
  authorName: "A",
  title: "t",
  rawMetadata: { tweetId: "1" },
};

test("buildCaptureRequest maps a full provenance verbatim", () => {
  const request = buildCaptureRequest(fullProvenance, "BASE64");
  assert.equal(request.image, "BASE64");
  assert.deepEqual(request.provenance, {
    platform: "twitter",
    originalURL: "https://x.com/a/status/1",
    authorHandle: "@a",
    authorName: "A",
    title: "t",
    rawMetadata: { tweetId: "1" },
  });
  // collectionId omitted → app routes to Unsorted.
  assert.equal("collectionId" in request, false);
});

test("buildCaptureRequest fills missing optionals with null / empty rawMetadata", () => {
  const request = buildCaptureRequest({ platform: "web" }, "X");
  assert.equal(request.provenance.originalURL, null);
  assert.equal(request.provenance.authorHandle, null);
  assert.equal(request.provenance.authorName, null);
  assert.equal(request.provenance.title, null);
  assert.deepEqual(request.provenance.rawMetadata, {});
});

test("postCapture sends token + content-type headers and returns status/body", async () => {
  let seen;
  const fakeFetch = async (url, init) => {
    seen = { url, init };
    return {
      status: 200,
      json: async () => ({ status: "ingested", assetId: "id", deduplicated: false }),
    };
  };
  const request = buildCaptureRequest(fullProvenance, "X");
  const result = await postCapture(request, { token: "secret", fetchImpl: fakeFetch });

  assert.equal(seen.url, DEFAULT_ENDPOINT);
  assert.equal(seen.init.method, "POST");
  assert.equal(seen.init.headers[TOKEN_HEADER], "secret");
  assert.equal(seen.init.headers["Content-Type"], "application/json");
  assert.deepEqual(JSON.parse(seen.init.body), request);
  assert.equal(result.status, 200);
  assert.equal(result.body.deduplicated, false);
});

test("contract (1A): buildCaptureRequest produces the canonical wire shape", () => {
  const request = buildCaptureRequest(contract.provenance, contract.image);
  assert.deepEqual(request, contract.expected.captureRequest);
});

test("contract (1A): buildProvenanceHeader decodes to the canonical video header", () => {
  const decoded = JSON.parse(
    Buffer.from(buildProvenanceHeader(contract.provenance), "base64").toString("utf8")
  );
  assert.deepEqual(decoded, contract.expected.videoHeader);
});

test("postCapture propagates a rejected fetch (network error) to the caller", async () => {
  const failing = async () => {
    throw new Error("network down");
  };
  // The SW relies on this throwing so it can fall back / flash "can't reach app".
  await assert.rejects(
    () => postCapture({}, { token: "t", fetchImpl: failing }),
    /network down/
  );
});

test("postVideoCapture propagates a rejected fetch (network error) to the caller", async () => {
  const failing = async () => {
    throw new Error("network down");
  };
  await assert.rejects(
    () => postVideoCapture(new Uint8Array([1]), {
      token: "t", provenanceHeader: "H", fetchImpl: failing,
    }),
    /network down/
  );
});

test("postCapture tolerates a non-JSON body", async () => {
  const fakeFetch = async () => ({
    status: 403,
    json: async () => {
      throw new Error("not json");
    },
  });
  const result = await postCapture({}, { token: "t", fetchImpl: fakeFetch });
  assert.equal(result.status, 403);
  assert.deepEqual(result.body, {});
});

test("base64Utf8 round-trips UTF-8 (btoa alone would throw on non-Latin1)", () => {
  const decoded = Buffer.from(base64Utf8("café — 日本 🎬"), "base64").toString("utf8");
  assert.equal(decoded, "café — 日本 🎬");
});

test("buildProvenanceHeader → base64 of VideoCaptureHeader JSON ({ provenance })", () => {
  const header = buildProvenanceHeader({
    platform: "twitter",
    originalURL: "https://x.com/a/status/1",
    authorHandle: "@a",
    title: "clip",
    rawMetadata: { tweetId: "1" },
    mediaKind: "video", // a client hint — must NOT be sent
  });
  const decoded = JSON.parse(Buffer.from(header, "base64").toString("utf8"));
  assert.deepEqual(decoded, {
    provenance: {
      platform: "twitter",
      originalURL: "https://x.com/a/status/1",
      authorHandle: "@a",
      authorName: null,
      title: "clip",
      rawMetadata: { tweetId: "1" },
    },
  });
  assert.equal("collectionId" in decoded, false);
  assert.equal("mediaKind" in decoded.provenance, false);
});

test("postVideoCapture sends octet-stream body + token + provenance headers", async () => {
  let seen;
  const fakeFetch = async (url, init) => {
    seen = { url, init };
    return { status: 200, json: async () => ({ status: "ingested", deduplicated: false }) };
  };
  const bytes = new Uint8Array([1, 2, 3]);
  const result = await postVideoCapture(bytes, {
    token: "secret", provenanceHeader: "BASE64HEADER", fetchImpl: fakeFetch,
  });

  assert.equal(seen.url, DEFAULT_VIDEO_ENDPOINT);
  assert.equal(seen.init.method, "POST");
  assert.equal(seen.init.headers["Content-Type"], "application/octet-stream");
  assert.equal(seen.init.headers[TOKEN_HEADER], "secret");
  assert.equal(seen.init.headers[PROVENANCE_HEADER], "BASE64HEADER");
  assert.equal(seen.init.body, bytes);
  assert.equal(result.status, 200);
});
