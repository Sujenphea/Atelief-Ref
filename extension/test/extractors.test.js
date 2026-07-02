// Atelier Capture — extractor unit tests (build-order #6, decision T4).
//
// The per-site extractors are the most breakage-prone part of the feature, so
// they are tested against saved harvest fixtures (the object harvestSignals
// produces). Pure functions over plain objects → no DOM / jsdom needed.

import { test } from "node:test";
import assert from "node:assert/strict";

import { extractProvenance, findExtractor } from "../src/extractors/registry.js";
import { twitter } from "../src/extractors/twitter.js";
import { pinterest } from "../src/extractors/pinterest.js";
import { instagram } from "../src/extractors/instagram.js";
import { cosmos } from "../src/extractors/cosmos.js";
import { web } from "../src/extractors/registry.js";

/** Build a harvest fixture. */
function harvest(url, metas = {}, extra = {}) {
  return { url, title: "Fallback Title", canonical: null, metas, ...extra };
}

test("twitter: handle + tweetId from URL, media from og:image", () => {
  const h = harvest("https://x.com/designer/status/1780000000000000000", {
    "og:image": "https://pbs.twimg.com/media/abc.jpg",
    "og:description": "a great reference",
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "twitter");
  assert.equal(p.mediaUrl, "https://pbs.twimg.com/media/abc.jpg");
  assert.equal(p.authorHandle, "@designer");
  assert.equal(p.originalURL, "https://x.com/designer/status/1780000000000000000");
  assert.equal(p.title, "a great reference");
  assert.deepEqual(p.rawMetadata, { tweetId: "1780000000000000000" });
});

test("twitter: twitter.com host also matches", () => {
  assert.equal(twitter.match("https://twitter.com/a/status/1"), true);
  assert.equal(twitter.match("https://mobile.twitter.com/a"), true);
});

test("pinterest: pinId from URL, media from og:image", () => {
  const h = harvest("https://www.pinterest.com/pin/12345/", {
    "og:image": "https://i.pinimg.com/originals/xx.jpg",
    "og:title": "A Pin",
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "pinterest");
  assert.equal(p.mediaUrl, "https://i.pinimg.com/originals/xx.jpg");
  assert.deepEqual(p.rawMetadata, { pinId: "12345" });
  assert.equal(p.title, "A Pin");
});

test("instagram: handle parsed from og:title, shortcode from URL", () => {
  const h = harvest("https://www.instagram.com/p/CxYz123/", {
    "og:image": "https://scontent.cdninstagram.com/v/pic.jpg",
    "og:title": "Jane Doe (@jane.doe) on Instagram: \"caption\"",
    "og:description": "a caption",
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "instagram");
  assert.equal(p.authorHandle, "@jane.doe");
  assert.deepEqual(p.rawMetadata, { shortcode: "CxYz123" });
  assert.equal(p.mediaUrl, "https://scontent.cdninstagram.com/v/pic.jpg");
});

test("cosmos: elementId from /e/{id}", () => {
  const h = harvest("https://www.cosmos.so/e/el-42", {
    "og:image": "https://images.cosmos.so/el.jpg",
    "og:title": "An Element",
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "cosmos");
  assert.deepEqual(p.rawMetadata, { elementId: "el-42" });
});

test("canonical link is preferred over the raw url", () => {
  const h = harvest("https://x.com/designer/status/1?s=20&t=track", {
    "og:image": "https://pbs.twimg.com/media/abc.jpg",
  });
  h.canonical = "https://x.com/designer/status/1";
  const p = extractProvenance(h);
  assert.equal(p.originalURL, "https://x.com/designer/status/1");
});

test("unknown site with og:image → web fallback", () => {
  const h = harvest("https://blog.example.com/post", {
    "og:image": "https://cdn.example.com/hero.png",
    "og:title": "A Post",
    "og:site_name": "Example Blog",
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "web");
  assert.equal(p.mediaUrl, "https://cdn.example.com/hero.png");
  assert.equal(p.authorName, "Example Blog");
});

test("no og:image anywhere → mediaUrl is null (SW will report 'no image')", () => {
  const p = extractProvenance(harvest("https://x.com/designer/status/1", {}));
  assert.equal(p.mediaUrl, null);
});

test("findExtractor routes each host to its extractor", () => {
  assert.equal(findExtractor("https://x.com/a/status/1"), twitter);
  assert.equal(findExtractor("https://www.pinterest.com/pin/1/"), pinterest);
  assert.equal(findExtractor("https://www.instagram.com/p/x/"), instagram);
  assert.equal(findExtractor("https://cosmos.so/e/1"), cosmos);
  assert.equal(findExtractor("https://other.example/"), web);
});
