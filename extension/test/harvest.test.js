// Atelier Capture — buildHarvest tests (decision 10A).
//
// buildHarvest is the pure classifier: raw page snapshot → the
// { url, title, canonical, metas, media } object the extractors consume. The DOM
// walk + canvas rasterization inside harvestSignals stay manual (no jsdom can
// decode a real <video>); the breakable part — kind tagging, skip rules, ordering
// — is asserted here with plain objects.

import { test } from "node:test";
import assert from "node:assert/strict";

import { buildHarvest } from "../src/harvest.js";

/** A minimal raw snapshot with sensible defaults. */
function raw(over = {}) {
  return {
    url: "https://x.com/a/status/1",
    title: "T",
    canonical: null,
    metas: [],
    images: [],
    videos: [],
    ...over,
  };
}

test("metas: first value wins, empty key/content skipped", () => {
  const h = buildHarvest(raw({
    metas: [
      { key: "og:image", content: "https://cdn/a.jpg" },
      { key: "og:image", content: "https://cdn/DUPLICATE.jpg" }, // ignored (first wins)
      { key: "og:title", content: "" },                          // empty content skipped
      { key: null, content: "orphan" },                          // no key skipped
      { key: "og:site_name", content: "Site" },
    ],
  }));
  assert.deepEqual(h.metas, {
    "og:image": "https://cdn/a.jpg",
    "og:site_name": "Site",
  });
});

test("images: data: URLs skipped, real ones kept with dims/alt", () => {
  const h = buildHarvest(raw({
    images: [
      { src: "data:image/png;base64,AAA", width: 10, height: 10, alt: "x" }, // skipped
      { src: "", width: 0, height: 0, alt: null },                            // skipped (empty)
      { src: "https://pbs.twimg.com/media/REAL.jpg", width: 1200, height: 800, alt: "photo" },
    ],
  }));
  assert.deepEqual(h.media, [
    { kind: "image", src: "https://pbs.twimg.com/media/REAL.jpg", width: 1200, height: 800, alt: "photo" },
  ]);
});

test("video: a captured frame → video-frame record (kind + data-URL src)", () => {
  const frame = "data:image/jpeg;base64,ZZZZ";
  const h = buildHarvest(raw({
    videos: [{ frame, poster: "https://pbs.twimg.com/amplify_video_thumb/1/img/x.jpg", src: "blob:xyz", width: 1280, height: 720 }],
  }));
  assert.deepEqual(h.media, [
    { kind: "video-frame", src: frame, width: 1280, height: 720, alt: null },
    { kind: "video-poster", src: "https://pbs.twimg.com/amplify_video_thumb/1/img/x.jpg", width: 1280, height: 720, alt: null },
    // blob: src is NOT emitted as video-src
  ]);
});

test("video: a real (non-blob) src → video-src signal; data:/blob: posters+srcs skipped", () => {
  const h = buildHarvest(raw({
    videos: [
      { frame: null, poster: "data:image/png;base64,AAA", src: "https://v1.pinimg.com/videos/iht/hls/x.m3u8", width: 720, height: 900 },
    ],
  }));
  assert.deepEqual(h.media, [
    { kind: "video-src", src: "https://v1.pinimg.com/videos/iht/hls/x.m3u8", width: 720, height: 900, alt: null },
  ]);
});

test("ordering: images (DOM order) precede video records; per video frame→poster→src", () => {
  const h = buildHarvest(raw({
    images: [{ src: "https://cdn/1.jpg", width: 1, height: 1, alt: null }],
    videos: [{ frame: "data:image/jpeg;base64,F", poster: "https://cdn/p.jpg", src: "https://cdn/v.mp4", width: 2, height: 2 }],
  }));
  assert.deepEqual(h.media.map((m) => m.kind), [
    "image", "video-frame", "video-poster", "video-src",
  ]);
});

test("passthrough: url/title/canonical carried, defaults applied", () => {
  const h = buildHarvest(raw({ url: "https://cosmos.so/e/1", title: undefined, canonical: "https://cosmos.so/" }));
  assert.equal(h.url, "https://cosmos.so/e/1");
  assert.equal(h.title, null);
  assert.equal(h.canonical, "https://cosmos.so/");
  assert.deepEqual(h.media, []);
});
