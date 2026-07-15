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
  isSavedFeedRequest, isCollectionFeedRequest, InstagramChallengeError, InstagramSavedError,
  IG_MEDIA_TYPE, buildSavedFeedURL, savedFeedHeaders, makeSavedFeedFetch, enumerateSavedFeed,
  instagramSavedDriver, IG_WEB_APP_ID,
} from "../src/bulk-instagram.js";

const saved = JSON.parse(readFileSync(new URL("./fixtures/instagram-saved.json", import.meta.url)));
// A second committed fixture derived from a real page-2 capture (002 §B0, 2026-07-15):
// 11 posts (incl. an 11-child carousel + 2 more carousels + 7 reels) → 25 fanned-out
// items. Stresses large-carousel fan-out the small first fixture doesn't.
const savedPage2 = JSON.parse(readFileSync(new URL("./fixtures/instagram-saved-page2.json", import.meta.url)));

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

test("isCollectionFeedRequest: matches a numeric-id collection feed, rejects the flat saved feed", () => {
  assert.equal(isCollectionFeedRequest("https://www.instagram.com/api/v1/feed/collection/1021461010622913/posts/"), true);
  assert.equal(isCollectionFeedRequest("/api/v1/feed/collection/42/posts/?max_id=ABC"), true);
  assert.equal(isCollectionFeedRequest("https://www.instagram.com/api/v1/feed/saved/posts/"), false);
  assert.equal(isCollectionFeedRequest("https://www.instagram.com/api/v1/feed/collection/abc/posts/"), false); // non-numeric id
  assert.equal(isCollectionFeedRequest(null), false);
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

test("parseSavedFeedPage: a mid-feed page exposes next_max_id; items carry the REQUEST cursor", () => {
  const midPage = { status: "ok", more_available: true, next_max_id: "NEXT_CUR",
    items: [{ media: imagePost }] };
  const page = parseSavedFeedPage(midPage, { cursor: "REQ_CUR" });
  assert.equal(page.endOfFeed, false);
  assert.equal(page.nextMaxId, "NEXT_CUR");         // the cursor to fetch the NEXT page
  // Items carry the cursor that REQUESTED this page (resume re-fetches it), NOT next_max_id.
  assert.equal(page.items[0].cursor, "REQ_CUR");
});

test("parseSavedFeedPage: a challenge body → error (InstagramChallengeError), no items, never throws", () => {
  const page = parseSavedFeedPage({ message: "checkpoint_required", status: "fail" }, {});
  assert.ok(page.error instanceof InstagramChallengeError);
  assert.equal(page.error.kind, "checkpoint_required");
  assert.equal(page.error.challenge, true);
  assert.equal(page.items.length, 0);
});

test("parseSavedFeedPage: the real page-2 fixture fans out 11 posts → 25 distinct items (large carousels)", () => {
  const page = parseSavedFeedPage(savedPage2, {});
  assert.equal(page.error, null);

  // Expected fan-out = sum over posts of (carousel ? child count : 1). Computed from the
  // fixture so it stays true if the fixture is re-captured.
  const expected = savedPage2.items.reduce((n, w) => {
    const m = w.media;
    return n + (m.carousel_media ? m.carousel_media.length : 1);
  }, 0);
  assert.equal(page.items.length, expected);                       // 25 in this capture
  assert.equal(new Set(page.items.map((i) => i.sourceId)).size, expected); // every pk distinct
  for (const item of page.items) assert.ok(item.mediaUrl, "every fanned-out item has a poster");

  // The biggest carousel really fanned out (not silently truncated to its cover).
  const biggest = savedPage2.items.map((w) => w.media)
    .filter((m) => m.carousel_media)
    .sort((a, b) => b.carousel_media.length - a.carousel_media.length)[0];
  const childIds = biggest.carousel_media.map((c) => String(c.pk));
  assert.ok(childIds.every((id) => page.items.some((it) => it.sourceId === id)),
    "every child of the largest carousel is present as its own item");

  // Each reel exposed its MP4 for the resolve-video toggle (7A).
  const reels = savedPage2.items.map((w) => w.media).filter((m) => m.media_type === 2).length;
  const withVideo = page.items.filter((i) => i.provenance.rawMetadata.videoUrl).length;
  assert.equal(withVideo, reels);
});

test("parseSavedFeedPage: a malformed / empty page → no items, ends the feed (no loop)", () => {
  assert.deepEqual(parseSavedFeedPage(null, {}).items, []);
  assert.equal(parseSavedFeedPage(null, {}).endOfFeed, true);
  assert.equal(parseSavedFeedPage({ items: [] }, {}).endOfFeed, true);   // no more_available → end
});

// MARK: - the O2 driver (URL / headers / fetch / pagination)

test("buildSavedFeedURL: the saved-feed path, with ?max_id= only when a cursor is set", () => {
  assert.equal(buildSavedFeedURL({ host: "www.instagram.com" }),
    "https://www.instagram.com/api/v1/feed/saved/posts/");
  assert.equal(buildSavedFeedURL({ host: "www.instagram.com", cursor: "CUR2" }),
    "https://www.instagram.com/api/v1/feed/saved/posts/?max_id=CUR2");
  // A real cursor carries base64 `=` padding — it round-trips through the query param.
  const u = new URL(buildSavedFeedURL({ host: "www.instagram.com", cursor: "aQ=b==" }));
  assert.equal(u.searchParams.get("max_id"), "aQ=b==");
});

test("buildSavedFeedURL: a collectionId targets the collection feed path (same ?max_id= pagination)", () => {
  assert.equal(buildSavedFeedURL({ host: "www.instagram.com", collectionId: "1021461010622913" }),
    "https://www.instagram.com/api/v1/feed/collection/1021461010622913/posts/");
  assert.equal(buildSavedFeedURL({ host: "www.instagram.com", collectionId: "42", cursor: "CUR2" }),
    "https://www.instagram.com/api/v1/feed/collection/42/posts/?max_id=CUR2");
});

test("savedFeedHeaders: only the public x-ig-app-id constant (verified live), no scraped secrets", () => {
  const h = savedFeedHeaders();
  assert.equal(h["x-ig-app-id"], IG_WEB_APP_ID);
  assert.equal(h["x-ig-app-id"], "936619743392459");
  assert.equal(h["x-requested-with"], "XMLHttpRequest");
  assert.ok(!("x-csrftoken" in h) && !("x-ig-www-claim" in h), "no csrf / www-claim needed");
});

test("makeSavedFeedFetch: sends the header + credentials, returns { httpStatus, json }", async () => {
  let seen = null;
  const fetchImpl = async (url, opts) => {
    seen = { url, opts };
    return { ok: true, status: 200, json: async () => ({ items: [], more_available: false }) };
  };
  const fetchJson = makeSavedFeedFetch({ fetchImpl });
  const res = await fetchJson("https://www.instagram.com/api/v1/feed/saved/posts/");
  assert.equal(res.httpStatus, 200);
  assert.deepEqual(res.json, { items: [], more_available: false });
  assert.equal(seen.opts.credentials, "include");
  assert.equal(seen.opts.headers["x-ig-app-id"], IG_WEB_APP_ID);
});

test("makeSavedFeedFetch: a 4xx body is still read (so a challenge can be classified)", async () => {
  const fetchImpl = async () => ({ ok: false, status: 400, json: async () => ({ message: "checkpoint_required" }) });
  const res = await makeSavedFeedFetch({ fetchImpl })("u");
  assert.equal(res.httpStatus, 400);
  assert.equal(res.json.message, "checkpoint_required");
});

/** Collect a driver/enumerator's yielded sourceIds. */
async function drain(iter) { const out = []; for await (const it of iter) out.push(it.sourceId); return out; }

/** A scripted fetchJson serving responses in order, recording requested URLs. */
function scripted(responses) {
  const urls = []; let i = 0;
  return { urls, fetchJson: async (url) => { urls.push(url); return responses[Math.min(i++, responses.length - 1)]; } };
}

test("enumerateSavedFeed: paginates via next_max_id, threading the cursor into the next request", async () => {
  const midPage = { status: "ok", more_available: true, next_max_id: "CUR2", items: [{ media: imagePost }] };
  const endPage = { status: "ok", more_available: false, items: [{ media: reelPost }] };
  const { urls, fetchJson } = scripted([{ httpStatus: 200, json: midPage }, { httpStatus: 200, json: endPage }]);

  const ids = await drain(enumerateSavedFeed(fetchJson, { host: "www.instagram.com" }, {}));
  assert.deepEqual(ids, [String(imagePost.pk), String(reelPost.pk)]);
  assert.equal(urls.length, 2);
  assert.ok(!urls[0].includes("max_id"));
  assert.match(urls[1], /max_id=CUR2/);
});

test("enumerateSavedFeed: a single terminal page yields once and stops (no phantom request)", async () => {
  const endPage = { status: "ok", more_available: false, items: [{ media: imagePost }] };
  const { urls, fetchJson } = scripted([{ httpStatus: 200, json: endPage }]);
  const ids = await drain(enumerateSavedFeed(fetchJson, {}, {}));
  assert.deepEqual(ids, [String(imagePost.pk)]);
  assert.equal(urls.length, 1);
});

test("enumerateSavedFeed: a challenge body THROWS InstagramChallengeError (halt, don't burn)", async () => {
  const { fetchJson } = scripted([{ httpStatus: 400, json: { message: "checkpoint_required", status: "fail" } }]);
  await assert.rejects(() => drain(enumerateSavedFeed(fetchJson, {}, {})), InstagramChallengeError);
});

test("enumerateSavedFeed: a non-200 (no challenge shape) THROWS InstagramSavedError", async () => {
  const { fetchJson } = scripted([{ httpStatus: 500, json: {} }]);
  await assert.rejects(() => drain(enumerateSavedFeed(fetchJson, {}, {})), InstagramSavedError);
});

test("enumerateSavedFeed: a repeated cursor stops the walk (loop guard, no infinite loop)", async () => {
  // A pathological feed that keeps returning the SAME next_max_id must not loop forever:
  // the first page yields, then the repeated cursor halts the walk before re-requesting it.
  const loopPage = { status: "ok", more_available: true, next_max_id: "SAME", items: [{ media: imagePost }] };
  const { fetchJson, urls } = scripted([{ httpStatus: 200, json: loopPage }]); // always returns SAME
  const ids = await drain(enumerateSavedFeed(fetchJson, {}, {}));
  // Terminates (no infinite loop): page 1 (no cursor) + one request at SAME, then the
  // repeated SAME is guarded before a third fetch.
  assert.equal(urls.length, 2);
  assert.equal(ids.length, 2);
});

test("instagramSavedDriver: conforms to the engine seam; a bare input walks the flat saved feed", async () => {
  const endPage = { status: "ok", more_available: false, items: [{ media: imagePost }] };
  const { fetchJson, urls } = scripted([{ httpStatus: 200, json: endPage }]);
  const driver = instagramSavedDriver({ fetchJson, host: "www.instagram.com" });
  const ids = await drain(driver.enumerate({ anything: true }, { cursor: null }));
  assert.deepEqual(ids, [String(imagePost.pk)]);
  assert.match(urls[0], /\/feed\/saved\/posts\//);
});

test("instagramSavedDriver: input.collectionId routes the walk to that collection's feed", async () => {
  const endPage = { status: "ok", more_available: false, items: [{ media: imagePost }] };
  const { fetchJson, urls } = scripted([{ httpStatus: 200, json: endPage }]);
  const driver = instagramSavedDriver({ fetchJson, host: "www.instagram.com" });
  const ids = await drain(driver.enumerate({ collectionId: "1021461010622913" }, { cursor: null }));
  assert.deepEqual(ids, [String(imagePost.pk)]);
  assert.match(urls[0], /\/feed\/collection\/1021461010622913\/posts\//);
});
