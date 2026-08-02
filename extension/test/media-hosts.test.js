// Atelier Capture — media-host allowlist tests (SSRF guard, decision 3A).
//
// The allowlist is the last line before the SW fetches page-supplied media in the
// authenticated session, so its acceptance AND rejection sets are pinned here: real CDN
// hosts pass, everything else (loopback, arbitrary hosts, suffix-spoofs, garbage URLs,
// unknown platforms) is denied by default.

import { test } from "node:test";
import assert from "node:assert/strict";

import { isAllowedMediaHost } from "../src/media-hosts.js";

test("allows the real Twitter media CDNs", () => {
  assert.equal(isAllowedMediaHost("twitter", "https://pbs.twimg.com/media/x.jpg?name=orig"), true);
  assert.equal(isAllowedMediaHost("twitter", "https://video.twimg.com/amplify_video/1/x.mp4"), true);
  assert.equal(isAllowedMediaHost("twitter", "https://twimg.com/x"), true); // apex too
});

test("allows the real Pinterest media CDNs", () => {
  assert.equal(isAllowedMediaHost("pinterest", "https://i.pinimg.com/originals/x.jpg"), true);
  assert.equal(isAllowedMediaHost("pinterest", "https://v.pinimg.com/videos/x.mp4"), true);
});

test("allows the real Instagram media CDNs (cdninstagram.com + the fbcdn.net Meta CDN)", () => {
  // The hosts observed in a live saved-feed response (002 · O2) — a `blocked-host` here is
  // exactly what stranded the whole IG sweep as permanentFailed before the entry existed.
  assert.equal(isAllowedMediaHost("instagram", "https://scontent.cdninstagram.com/v/t51/x.jpg"), true);
  assert.equal(isAllowedMediaHost("instagram", "https://scontent-lhr8-1.cdninstagram.com/v/x.jpg"), true);
  assert.equal(isAllowedMediaHost("instagram", "https://instagram.fhlz4-1.fna.fbcdn.net/v/t51/x.jpg"), true);
  assert.equal(isAllowedMediaHost("instagram", "https://scontent.xx.fbcdn.net/v/x.mp4"), true);
});

test("allows the real rednote media CDN (one entry covers sns-i* images + sns-v* video)", () => {
  // The signed webp the page renders, the unsigned full-res original the extractor
  // prefers, and the video node — all on rednotecdn.com, so ONE apex entry covers
  // the lot. Widening this to `xhscdn.com` etc. is deliberately not done.
  assert.equal(isAllowedMediaHost("rednote", "https://sns-web-i10.rednotecdn.com/1/s/k!nc_n_webp_mw_1"), true);
  assert.equal(isAllowedMediaHost("rednote", "http://sns-i27.rednotecdn.com/1040g2sg31key"), true);
  assert.equal(isAllowedMediaHost("rednote", "https://sns-v28.rednotecdn.com/stream/110/x.mp4"), true);
  assert.equal(isAllowedMediaHost("rednote", "https://rednotecdn.com/x"), true); // apex too
});

test("denies loopback, arbitrary hosts, and cross-platform hosts", () => {
  assert.equal(isAllowedMediaHost("pinterest", "http://127.0.0.1:47321/secret"), false);
  assert.equal(isAllowedMediaHost("twitter", "https://evil.example/x.jpg"), false);
  // A Pinterest sweep must not fetch a twimg URL, and vice-versa; nor an IG sweep a twimg
  // URL, nor a twitter sweep an IG CDN URL.
  assert.equal(isAllowedMediaHost("pinterest", "https://pbs.twimg.com/media/x.jpg"), false);
  assert.equal(isAllowedMediaHost("twitter", "https://i.pinimg.com/originals/x.jpg"), false);
  assert.equal(isAllowedMediaHost("instagram", "https://pbs.twimg.com/media/x.jpg"), false);
  assert.equal(isAllowedMediaHost("twitter", "https://scontent.cdninstagram.com/v/x.jpg"), false);
  assert.equal(isAllowedMediaHost("rednote", "https://i.pinimg.com/originals/x.jpg"), false);
  assert.equal(isAllowedMediaHost("pinterest", "https://sns-i27.rednotecdn.com/x"), false);
  // The rednote PAGE hosts are not media hosts — only the CDN is fetchable.
  assert.equal(isAllowedMediaHost("rednote", "https://www.xiaohongshu.com/explore/x"), false);
  assert.equal(isAllowedMediaHost("rednote", "http://127.0.0.1:47321/secret"), false);
});

test("denies suffix-spoofed look-alike hosts", () => {
  assert.equal(isAllowedMediaHost("twitter", "https://pbs.twimg.com.evil.com/x.jpg"), false);
  assert.equal(isAllowedMediaHost("twitter", "https://eviltwimg.com/x.jpg"), false);
  assert.equal(isAllowedMediaHost("pinterest", "https://notpinimg.com/x.jpg"), false);
  assert.equal(isAllowedMediaHost("instagram", "https://cdninstagram.com.evil.com/x.jpg"), false);
  assert.equal(isAllowedMediaHost("instagram", "https://notfbcdn.net/x.jpg"), false);
  assert.equal(isAllowedMediaHost("rednote", "https://sns-i27.rednotecdn.com.evil.com/x"), false);
  assert.equal(isAllowedMediaHost("rednote", "https://notrednotecdn.com/x"), false);
});

test("denies a garbage URL, an empty host, and an unknown platform (deny-by-default)", () => {
  assert.equal(isAllowedMediaHost("twitter", "not a url"), false);
  assert.equal(isAllowedMediaHost("twitter", ""), false);
  assert.equal(isAllowedMediaHost("twitter", "data:image/png;base64,AAAA"), false); // no host
  assert.equal(isAllowedMediaHost("flickr", "https://pbs.twimg.com/x.jpg"), false);  // unknown platform
  assert.equal(isAllowedMediaHost(undefined, "https://pbs.twimg.com/x.jpg"), false);
});
