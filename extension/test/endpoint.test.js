// Atelier Capture — endpoint contract tests (build-order #6, decision T4).
//
// buildCaptureRequest must produce exactly the shape Swift's CaptureRequest
// decodes; postCapture must send the token + content-type headers and surface
// the status/body. fetch is injected (no network).

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  buildCaptureRequest, postCapture, TOKEN_HEADER, DEFAULT_ENDPOINT,
} from "../src/endpoint.js";

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
