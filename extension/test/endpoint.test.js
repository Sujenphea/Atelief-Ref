// Atelier Capture — endpoint contract tests (build-order #6, decision T4).
//
// buildCaptureRequest must produce exactly the shape Swift's CaptureRequest
// decodes; postCapture must send the token + content-type headers and surface
// the status/body. fetch is injected (no network).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  buildCaptureRequest, buildContentCaptureRequest, tweetContent,
  postCapture, TOKEN_HEADER, DEFAULT_ENDPOINT,
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

test("contract (1A): a tweet content-capture produces the canonical wire shape", () => {
  const { provenance } = contract.contentInput;
  const content = tweetContent(provenance);
  const request = buildContentCaptureRequest(
    provenance, contract.contentInput.image, content);
  assert.deepEqual(request, contract.expected.contentCaptureRequest);
});

test("tweetContent returns null when there is no tweet id → plain image fallback", () => {
  assert.equal(tweetContent({ platform: "twitter", title: "hi", mediaUrl: "u" }), null);
});

test("tweetContent returns null for a tweet with neither text nor media", () => {
  assert.equal(
    tweetContent({ platform: "twitter", rawMetadata: { tweetId: "5" } }), null);
});

test("tweetContent always includes a media array (Swift media is non-optional)", () => {
  const content = tweetContent({
    platform: "twitter", title: "just text", rawMetadata: { tweetId: "7" },
  });
  assert.deepEqual(content.payload.tweet.media, []);
  assert.equal(content.payload.tweet.tweetID, "7");
  assert.equal(content.kind, "tweet");
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

// MARK: - bulk-import tags (3A)

test("buildCaptureRequest omits jobId/sourceId when not part of a sweep", async () => {
  const request = buildCaptureRequest({ platform: "web" }, "B64");
  assert.equal("jobId" in request, false);
  assert.equal("sourceId" in request, false);
});

test("buildCaptureRequest includes jobId/sourceId when tagged (bulk)", async () => {
  const request = buildCaptureRequest({ platform: "pinterest" }, "B64", {
    jobId: "11111111-1111-1111-1111-111111111111", sourceId: "pin-7",
  });
  assert.equal(request.jobId, "11111111-1111-1111-1111-111111111111");
  assert.equal(request.sourceId, "pin-7");
  assert.equal(request.image, "B64");
});

test("buildProvenanceHeader carries jobId/sourceId when tagged (video, bulk)", async () => {
  const header = buildProvenanceHeader({ platform: "twitter" }, { jobId: "job-1", sourceId: "t-9" });
  const decoded = JSON.parse(Buffer.from(header, "base64").toString("utf8"));
  assert.equal(decoded.jobId, "job-1");
  assert.equal(decoded.sourceId, "t-9");
  // Untagged → neither key present.
  const plain = JSON.parse(Buffer.from(buildProvenanceHeader({ platform: "twitter" }), "base64").toString("utf8"));
  assert.equal("jobId" in plain, false);
  assert.equal("sourceId" in plain, false);
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
