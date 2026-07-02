// Atelier Capture — Pinterest video resolution tests.
//
// Fixtures are the REAL structures from pin 1030339221009481451 (verified live):
// a `videoUrls` array mixing H.264 MP4 (/expMp4/), HEVC MP4 (/hevcMp4V3/,
// /h265-pt-mp4/), and HLS/DASH manifests. Selection + parsing are pure; the fetch
// is mocked.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  selectBestVideo, extractVideoUrls, shouldResolveVideo, resolvePinterestVideo,
} from "../src/pinterest-video.js";

const H = "a3ee5d66ee2129057cc0db7ab66419f4";
const B = `https://v1.pinimg.com/videos/iht`;
// The real array (order as served), with H.264 720w, several HEVC widths, HLS/DASH.
const realVideoUrls = [
  `${B}/expMp4/a3/ee/5d/${H}_720w.mp4`,
  `${B}/h265/a3/ee/5d/${H}.m3u8`,
  `${B}/h265-pt/a3/ee/5d/${H}.m3u8`,
  `${B}/h265-pt/a3/ee/5d/${H}.mpd`,
  `${B}/hevcMp4V3/a3/ee/5d/${H}_240w.mp4`,
  `${B}/hevcMp4V3/a3/ee/5d/${H}_360w.mp4`,
  `${B}/hevcMp4V3/a3/ee/5d/${H}_720w.mp4`,
  `${B}/hls/a3/ee/5d/${H}.m3u8`,
  `${B}/hevcMp4V3/a3/ee/5d/${H}_540w.mp4`,
  `${B}/h265-pt-mp4/a3/ee/5d/${H}_720w_t1.mp4`,
];

test("selectBestVideo: prefers H.264 (expMp4), highest width; skips HLS/DASH", () => {
  assert.equal(selectBestVideo(realVideoUrls), `${B}/expMp4/a3/ee/5d/${H}_720w.mp4`);
});

test("selectBestVideo: no H.264 → largest-width HEVC MP4", () => {
  const hevcOnly = realVideoUrls.filter((u) => !/expMp4/.test(u));
  assert.equal(selectBestVideo(hevcOnly), `${B}/hevcMp4V3/a3/ee/5d/${H}_720w.mp4`);
});

test("selectBestVideo: only manifests (HLS/DASH) → null", () => {
  assert.equal(selectBestVideo([`${B}/hls/x.m3u8`, `${B}/h265-pt/x.mpd`]), null);
  assert.equal(selectBestVideo([]), null);
});

test("extractVideoUrls: pulls the array out of server HTML", () => {
  const html = `<script>{"pin":{"videos":{"videoUrls":${JSON.stringify(realVideoUrls)}}}}</script>`;
  assert.deepEqual(extractVideoUrls(html), realVideoUrls);
  assert.deepEqual(extractVideoUrls("<html>no video pin</html>"), []);
});

test("shouldResolveVideo: only for a pin with a pinId AND a video signal", () => {
  const prov = { platform: "pinterest", rawMetadata: { pinId: "1030339221009481451" } };
  const videoHarvest = { media: [
    { kind: "video-poster", src: "https://i.pinimg.com/736x/aa.jpg" },
  ] };
  const videoSrcHarvest = { media: [{ kind: "video-src", src: "https://v1.pinimg.com/videos/iht/hls/x.m3u8" }] };
  const imageHarvest = { media: [{ kind: "image", src: "https://i.pinimg.com/736x/aa.jpg" }] };

  assert.equal(shouldResolveVideo(prov, videoHarvest), true);
  assert.equal(shouldResolveVideo(prov, videoSrcHarvest), true);
  assert.equal(shouldResolveVideo(prov, imageHarvest), false);       // image pin → no fetch
  assert.equal(shouldResolveVideo(prov, { media: [] }), false);
  // Wrong platform / no pinId → never.
  assert.equal(shouldResolveVideo({ platform: "twitter", rawMetadata: { tweetId: "1" } }, videoHarvest), false);
  assert.equal(shouldResolveVideo({ platform: "pinterest", rawMetadata: {} }, videoHarvest), false);
});

test("resolvePinterestVideo: fetches the pin page (cookie-less) and returns the best MP4", async () => {
  let seen;
  const fakeFetch = async (url, init) => {
    seen = { url, init };
    return { ok: true, text: async () => `x"videoUrls":${JSON.stringify(realVideoUrls)}x` };
  };
  const url = await resolvePinterestVideo("1030339221009481451", { fetchImpl: fakeFetch });
  assert.equal(url, `${B}/expMp4/a3/ee/5d/${H}_720w.mp4`);
  assert.match(seen.url, /pinterest\.com\/pin\/1030339221009481451\//);
  // Load-bearing: logged-in Pinterest omits videoUrls, so the fetch must be cookie-less.
  assert.equal(seen.init.credentials, "omit");
});

test("resolvePinterestVideo: throws on non-ok, or a pin with no MP4", async () => {
  await assert.rejects(
    () => resolvePinterestVideo("1", { fetchImpl: async () => ({ ok: false, status: 404 }) }),
    /pinterest HTTP 404/
  );
  await assert.rejects(
    () => resolvePinterestVideo("1", { fetchImpl: async () => ({ ok: true, text: async () => "no video" }) }),
    /no MP4 variant/
  );
});
