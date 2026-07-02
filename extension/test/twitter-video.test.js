// Atelier Capture — Twitter video resolution tests.
//
// The syndication payload shapes and the highest-bitrate-MP4 selection are the
// breakable parts; assert them against saved fixtures. The live fetch (token +
// network) is not unit-tested here — it's verified manually (see README).

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  selectBestVideo, syndicationURL, resolveTwitterVideo,
} from "../src/twitter-video.js";

// A representative tweet-result payload for a video tweet (mediaDetails shape).
const videoResult = {
  mediaDetails: [
    {
      type: "video",
      video_info: {
        variants: [
          { bitrate: 256000, content_type: "video/mp4", url: "https://video.twimg.com/lo.mp4" },
          { content_type: "application/x-mpegURL", url: "https://video.twimg.com/hls.m3u8" },
          { bitrate: 2176000, content_type: "video/mp4", url: "https://video.twimg.com/hi.mp4" },
          { bitrate: 832000, content_type: "video/mp4", url: "https://video.twimg.com/mid.mp4" },
        ],
      },
    },
  ],
};

test("selectBestVideo: picks the highest-bitrate MP4, ignoring HLS", () => {
  assert.equal(selectBestVideo(videoResult), "https://video.twimg.com/hi.mp4");
});

test("selectBestVideo: supports the top-level `video` shape too", () => {
  const result = {
    video: {
      variants: [
        { bitrate: 100, content_type: "video/mp4", url: "https://video.twimg.com/a.mp4" },
        { bitrate: 900, content_type: "video/mp4", url: "https://video.twimg.com/b.mp4" },
      ],
    },
  };
  assert.equal(selectBestVideo(result), "https://video.twimg.com/b.mp4");
});

test("selectBestVideo: a photo-only / HLS-only payload → null", () => {
  assert.equal(selectBestVideo({ mediaDetails: [{ type: "photo" }] }), null);
  assert.equal(selectBestVideo({}), null);
  assert.equal(selectBestVideo({
    mediaDetails: [{ type: "video", video_info: { variants: [
      { content_type: "application/x-mpegURL", url: "https://video.twimg.com/only.m3u8" },
    ] } }],
  }), null);
});

test("syndicationURL: targets the tweet-result endpoint with the id + a token", () => {
  const url = syndicationURL("1780000000000000000");
  assert.match(url, /^https:\/\/cdn\.syndication\.twimg\.com\/tweet-result\?/);
  assert.match(url, /[?&]id=1780000000000000000(&|$)/);
  assert.match(url, /[?&]token=[^&]+/); // some derived, non-empty token
});

test("resolveTwitterVideo: fetches the payload and returns the best MP4", async () => {
  let seenUrl;
  const fakeFetch = async (url) => {
    seenUrl = url;
    return { ok: true, json: async () => videoResult };
  };
  const url = await resolveTwitterVideo("123", { fetchImpl: fakeFetch });
  assert.equal(url, "https://video.twimg.com/hi.mp4");
  assert.match(seenUrl, /tweet-result\?id=123/);
});

test("resolveTwitterVideo: throws on a non-ok response", async () => {
  const fakeFetch = async () => ({ ok: false, status: 404 });
  await assert.rejects(
    () => resolveTwitterVideo("123", { fetchImpl: fakeFetch }),
    /syndication HTTP 404/
  );
});

test("resolveTwitterVideo: throws when there is no MP4 variant", async () => {
  const fakeFetch = async () => ({ ok: true, json: async () => ({ mediaDetails: [] }) });
  await assert.rejects(
    () => resolveTwitterVideo("123", { fetchImpl: fakeFetch }),
    /no MP4 variant/
  );
});
