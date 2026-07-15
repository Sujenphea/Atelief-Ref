// Atelier Capture — Instagram saved-feed parser tests (002 · B3, [T9][1A][3A][7A]).
//
// The parsers run against the committed sanitized saved-feed fixture, so an IG
// response-shape drift breaks a unit test, not a live sweep. Covers the per-media fan-out
// (1A: a carousel → one item per child, single/reel → one), the poster/video pickers,
// the reel videoUrl stash (7A), the challenge recognizer (3A), pagination / end-of-feed,
// and the malformed / tombstone edges.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  parseSavedFeedPage, mapSavedMedia, pickImage, pickVideo, detectChallenge,
  isSavedFeedRequest, InstagramChallengeError, IG_MEDIA_TYPE,
} from "../src/bulk-instagram.js";

const saved = JSON.parse(readFileSync(new URL("./fixtures/instagram-saved.json", import.meta.url)));

/** The fixture's three posts by media_type (1 image, 2 reel, 8 carousel). */
const medias = saved.items.map((w) => w.media);
const imagePost = medias.find((m) => m.media_type === IG_MEDIA_TYPE.image);
const reelPost = medias.find((m) => m.media_type === IG_MEDIA_TYPE.video);
const carouselPost = medias.find((m) => m.media_type === IG_MEDIA_TYPE.carousel);

// MARK: - isSavedFeedRequest (KEEP IN SYNC with the hook)

test("isSavedFeedRequest: matches the saved-posts feed, rejects other feeds", () => {
  assert.equal(isSavedFeedRequest("https://www.instagram.com/api/v1/feed/saved/posts/"), true);
  assert.equal(isSavedFeedRequest("/api/v1/feed/saved/posts/?max_id=ABC"), true);
  assert.equal(isSavedFeedRequest("https://www.instagram.com/api/v1/feed/collection/9/posts/"), false);
  assert.equal(isSavedFeedRequest(null), false);
});

// MARK: - pickImage / pickVideo

test("pickImage: takes the largest-by-width candidate + a smaller fallback (defensive sort)", () => {
  // Deliberately smallest-first to prove the sort (candidates are observed largest-first).
  const iv = { candidates: [
    { width: 320, height: 320, url: "small.jpg" },
    { width: 1080, height: 1080, url: "big.jpg" },
  ] };
  assert.deepEqual(pickImage(iv), { mediaUrl: "big.jpg", mediaUrlFallback: "small.jpg" });
});

test("pickImage: a single candidate has no fallback; empty → nulls", () => {
  assert.deepEqual(pickImage({ candidates: [{ width: 10, url: "only.jpg" }] }),
    { mediaUrl: "only.jpg", mediaUrlFallback: null });
  assert.deepEqual(pickImage({ candidates: [] }), { mediaUrl: null, mediaUrlFallback: null });
  assert.deepEqual(pickImage(null), { mediaUrl: null, mediaUrlFallback: null });
});

test("pickVideo: picks the largest-by-width MP4; null when there are none", () => {
  const vv = [{ width: 480, url: "sd.mp4" }, { width: 1080, url: "hd.mp4" }];
  assert.equal(pickVideo(vv), "hd.mp4");
  assert.equal(pickVideo([]), null);
  assert.equal(pickVideo(null), null);
});

// MARK: - mapSavedMedia (fan-out)

test("mapSavedMedia: a single image → ONE item keyed by its per-media pk (1A)", () => {
  const items = mapSavedMedia(imagePost, { host: "www.instagram.com" });
  assert.equal(items.length, 1);
  const item = items[0];
  assert.equal(item.sourceId, String(imagePost.pk));
  assert.equal(item.provenance.platform, "instagram");
  assert.equal(item.provenance.rawMetadata.kind, "image");
  assert.equal(item.provenance.rawMetadata.videoUrl, null);
  assert.ok(item.mediaUrl, "has a poster to fetch");
  assert.equal(item.provenance.originalURL, `https://www.instagram.com/p/${imagePost.code}/`);
  assert.equal(item.provenance.authorHandle, `@${imagePost.user.username}`);
});

test("mapSavedMedia: a reel → ONE item, poster card + best MP4 stashed in videoUrl (7A)", () => {
  const items = mapSavedMedia(reelPost, {});
  assert.equal(items.length, 1);
  const item = items[0];
  assert.equal(item.sourceId, String(reelPost.pk));
  assert.equal(item.provenance.rawMetadata.kind, "video");
  // The card is the POSTER (from image_versions2), not the MP4; the MP4 rides in videoUrl.
  assert.ok(item.mediaUrl && !item.mediaUrl.includes(".mp4"), "card is the poster image, not the video");
  assert.match(item.provenance.rawMetadata.videoUrl, /\.mp4/, "the reel's MP4 is stashed for the resolve-video toggle");
  assert.equal(item.provenance.originalURL, `https://www.instagram.com/reel/${reelPost.code}/`);
});

test("mapSavedMedia: a carousel fans out to ONE item per child, each its own pk (1A)", () => {
  const items = mapSavedMedia(carouselPost, {});
  assert.equal(items.length, carouselPost.carousel_media.length);
  // Distinct per-media pks — the dedup keys.
  const ids = items.map((i) => i.sourceId);
  assert.equal(new Set(ids).size, ids.length);
  assert.deepEqual(ids, carouselPost.carousel_media.map((c) => String(c.pk)));
  // Every child shares the POST's permalink + caption + author, but carries its own index.
  for (const [i, item] of items.entries()) {
    assert.equal(item.provenance.originalURL, `https://www.instagram.com/p/${carouselPost.code}/`);
    assert.equal(item.provenance.rawMetadata.carouselIndex, i);
    assert.ok(item.mediaUrl);
  }
});

test("mapSavedMedia: a media with no pk or no image → no item (never enqueue a doomed one)", () => {
  assert.deepEqual(mapSavedMedia({ media_type: 1, image_versions2: { candidates: [{ url: "x.jpg" }] } }, {}), []); // no pk
  assert.deepEqual(mapSavedMedia({ pk: "9", media_type: 1, image_versions2: { candidates: [] } }, {}), []);        // no image
  assert.deepEqual(mapSavedMedia(null, {}), []);
});

// MARK: - detectChallenge (3A)

test("detectChallenge: recognizes checkpoint / login / rate-limit / bare-fail bodies", () => {
  assert.equal(detectChallenge({ message: "checkpoint_required", status: "fail" }), "checkpoint_required");
  assert.equal(detectChallenge({ checkpoint_url: "/challenge/", status: "fail" }), "checkpoint_required");
  assert.equal(detectChallenge({ message: "login_required", status: "fail" }), "login_required");
  assert.equal(detectChallenge({ message: "challenge_required" }), "challenge_required");
  assert.equal(detectChallenge({ message: "Please wait a few minutes before you try again.", status: "fail" }), "rate_limited");
  assert.equal(detectChallenge({ spam: true, status: "fail" }), "rate_limited");
  assert.equal(detectChallenge({ status: "fail" }), "unknown_fail"); // a bare failure still halts
});

test("detectChallenge: a normal feed page is NOT a challenge", () => {
  assert.equal(detectChallenge(saved), null);
  assert.equal(detectChallenge({ status: "ok", items: [], more_available: false }), null);
  assert.equal(detectChallenge(null), null);
});

// MARK: - parseSavedFeedPage

test("parseSavedFeedPage: fans out the whole fixture (image + reel + carousel children)", () => {
  const page = parseSavedFeedPage(saved, { host: "www.instagram.com" });
  assert.equal(page.error, null);
  // 1 image + 1 reel + N carousel children.
  const expected = 1 + 1 + carouselPost.carousel_media.length;
  assert.equal(page.items.length, expected);
  assert.equal(new Set(page.items.map((i) => i.sourceId)).size, expected); // all distinct pks
  for (const item of page.items) assert.ok(item.mediaUrl);
});

test("parseSavedFeedPage: end-of-feed when more_available is false (the fixture), no cursor", () => {
  const page = parseSavedFeedPage(saved, {});
  assert.equal(page.endOfFeed, true);       // fixture is a terminal page
  assert.equal(page.nextMaxId, null);
  for (const item of page.items) assert.equal(item.cursor, null);
});

test("parseSavedFeedPage: a mid-feed page carries next_max_id and is NOT end-of-feed", () => {
  // The recon account was single-page; synthesize the paginating shape (README documents
  // this — the field name is IG convention, re-verify against a multi-page feed).
  const midPage = { status: "ok", more_available: true, next_max_id: "QVFC_cursor_123",
    items: [{ media: imagePost }] };
  const page = parseSavedFeedPage(midPage, {});
  assert.equal(page.endOfFeed, false);
  assert.equal(page.nextMaxId, "QVFC_cursor_123");
  assert.equal(page.items[0].cursor, "QVFC_cursor_123"); // items stamped with the checkpoint token
});

test("parseSavedFeedPage: a challenge body → error (InstagramChallengeError), no items, never throws", () => {
  const page = parseSavedFeedPage({ message: "checkpoint_required", status: "fail" }, {});
  assert.ok(page.error instanceof InstagramChallengeError);
  assert.equal(page.error.kind, "checkpoint_required");
  assert.equal(page.error.challenge, true);
  assert.equal(page.items.length, 0);
});

test("parseSavedFeedPage: a malformed / empty page → no items, ends the feed (no loop)", () => {
  assert.deepEqual(parseSavedFeedPage(null, {}).items, []);
  assert.equal(parseSavedFeedPage(null, {}).endOfFeed, true);
  assert.equal(parseSavedFeedPage({ items: [] }, {}).endOfFeed, true);   // no more_available → end
});
