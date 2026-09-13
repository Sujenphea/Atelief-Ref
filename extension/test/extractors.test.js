// Atelier Capture — extractor unit tests (build-order #6, decision T4).
//
// The per-site extractors are the most breakage-prone part of the feature, so
// they are tested against saved harvest fixtures (the object harvestSignals
// produces: { url, title, canonical, metas, media }). Pure functions over plain
// objects → no DOM / jsdom needed.
//
// The fixtures encode what real pages actually do: SPA meta tags + canonical are
// stale/generic, and the reliable signals are the live url + DOM media.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { toOrigName, toOriginals, canonicalPinterestHost } from "../src/extractors/base.js";
import { extractProvenance, findExtractor, web } from "../src/extractors/registry.js";
import { twitter, toStatusPermalink, belongsToStatus } from "../src/extractors/twitter.js";
import { pinterest } from "../src/extractors/pinterest.js";
import { instagram, toPostPermalink } from "../src/extractors/instagram.js";
import { cosmos } from "../src/extractors/cosmos.js";
import { rednote, toRednoteOriginal } from "../src/extractors/rednote.js";

/** Build a harvest fixture. */
function harvest({ url, title = "Fallback", canonical = null, metas = {}, media = [] }) {
  return { url, title, canonical, metas, media };
}
const img = (src, width = 0, height = 0) => ({ kind: "image", src, width, height, alt: null });

test("twitter: picks the real DOM media (pbs.twimg/media), not og:image, at full res", () => {
  const h = harvest({
    url: "https://x.com/designer/status/1780000000000000000",
    metas: {
      "og:image": "https://pbs.twimg.com/profile_images/generic_card.jpg",
      "og:description": "a great reference",
    },
    media: [
      img("https://pbs.twimg.com/profile_images/avatar.jpg", 48, 48), // avatar — ignored
      img("https://pbs.twimg.com/media/REAL?format=jpg&name=small", 1200, 800), // the post
    ],
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "twitter");
  assert.equal(p.mediaUrl, "https://pbs.twimg.com/media/REAL?format=jpg&name=orig");
  assert.equal(p.authorHandle, "@designer");
  assert.equal(p.originalURL, "https://x.com/designer/status/1780000000000000000");
  assert.deepEqual(p.rawMetadata, { tweetId: "1780000000000000000" });
});

test("twitter: scopes DOM media to the focal tweet — a reply's image is NOT borrowed", () => {
  // The focal tweet (article 0) is text-only; a reply (article 1) has an image. The
  // extractor must ignore the reply's image AND not fall back to X's generic og:image
  // → no mediaUrl, so the capture becomes a text card.
  const h = harvest({
    url: "https://x.com/a/status/1",
    metas: { "og:image": "https://pbs.twimg.com/generic_card.jpg" },
    media: [
      { kind: "image", src: "https://pbs.twimg.com/media/REPLY.jpg", width: 500, height: 500, alt: null, articleIndex: 1 },
    ],
  });
  assert.equal(twitter.extract(h).mediaUrl, null);
});

test("twitter: the focal tweet's OWN image wins over a reply's", () => {
  const h = harvest({
    url: "https://x.com/a/status/1",
    media: [
      { kind: "image", src: "https://pbs.twimg.com/media/FOCAL?format=jpg&name=small", width: 900, height: 900, alt: null, articleIndex: 0 },
      { kind: "image", src: "https://pbs.twimg.com/media/REPLY.jpg", width: 500, height: 500, alt: null, articleIndex: 1 },
    ],
  });
  assert.equal(twitter.extract(h).mediaUrl, "https://pbs.twimg.com/media/FOCAL?format=jpg&name=orig");
});

test("twitter: a right-clicked image is honored even if it's outside the focal tweet", () => {
  const h = harvest({
    url: "https://x.com/a/status/1",
    media: [{ kind: "image", src: "https://pbs.twimg.com/media/FOCAL.jpg", width: 9, height: 9, alt: null, articleIndex: 0 }],
  });
  const p = twitter.extract(h, { srcUrl: "https://pbs.twimg.com/media/CLICKED?format=jpg&name=large" });
  assert.equal(p.mediaUrl, "https://pbs.twimg.com/media/CLICKED?format=jpg&name=orig");
});

// MARK: - twitter multi-photo media[] (003 · C3 — single-capture backfill, decision 8A)

/** A focal-article photo (articleIndex 0 by default). `statusId` is the status its
 * permalink anchor named, omitted when the reader had no anchor to read (buildHarvest
 * omits the key rather than writing null, so the fixture does too). */
const xphoto = (name, articleIndex = 0, statusId = null) => ({
  kind: "image", src: `https://pbs.twimg.com/media/${name}?format=jpg&name=small`,
  width: 900, height: 900, alt: null, articleIndex,
  ...(statusId == null ? {} : { statusId }),
});
const orig = (name) => `https://pbs.twimg.com/media/${name}?format=jpg&name=orig`;

test("twitter: a multi-photo tweet collects ALL focal photos into media[], card first", () => {
  const h = harvest({ url: "https://x.com/a/status/1", media: [xphoto("P1"), xphoto("P2"), xphoto("P3")] });
  const p = twitter.extract(h);
  assert.deepEqual(p.mediaUrls, [orig("P1"), orig("P2"), orig("P3")]);
  assert.equal(p.mediaUrl, p.mediaUrls[0]); // the card is media[0]
});

test("twitter: media[] dedupes a repeated src", () => {
  const h = harvest({ url: "https://x.com/a/status/1", media: [xphoto("P1"), xphoto("P1")] });
  assert.deepEqual(twitter.extract(h).mediaUrls, [orig("P1")]);
});

test("twitter: media[] is capped at X's max of 4 photos", () => {
  const h = harvest({
    url: "https://x.com/a/status/1",
    media: [xphoto("P1"), xphoto("P2"), xphoto("P3"), xphoto("P4"), xphoto("P5")],
  });
  assert.deepEqual(twitter.extract(h).mediaUrls, [orig("P1"), orig("P2"), orig("P3"), orig("P4")]);
});

test("twitter: a single-photo tweet → media[] is just the card", () => {
  const p = twitter.extract(harvest({ url: "https://x.com/a/status/1", media: [xphoto("SOLO")] }));
  assert.deepEqual(p.mediaUrls, [orig("SOLO")]);
  assert.equal(p.mediaUrl, orig("SOLO"));
});

test("twitter: a right-clicked photo leads media[], the focal photos following", () => {
  const h = harvest({ url: "https://x.com/a/status/1", media: [xphoto("P1"), xphoto("P2")] });
  const p = twitter.extract(h, { srcUrl: "https://pbs.twimg.com/media/CLICKED?format=jpg&name=large" });
  assert.equal(p.mediaUrl, orig("CLICKED"));
  assert.deepEqual(p.mediaUrls, [orig("CLICKED"), orig("P1"), orig("P2")]);
});

test("twitter: a text-only focal tweet → empty media[] (no image to reference)", () => {
  const p = twitter.extract(harvest({
    url: "https://x.com/a/status/1",
    media: [{ kind: "image", src: "https://pbs.twimg.com/media/REPLY.jpg", width: 5, height: 5, alt: null, articleIndex: 1 }],
  }));
  assert.equal(p.mediaUrl, null);
  assert.deepEqual(p.mediaUrls, []);
});

// MARK: - twitter quoted-tweet exclusion (099 · P11 — the per-photo status id)
//
// A quoted tweet renders INSIDE the quoter's <article>, so `articleIndex === 0` keeps
// its photo. The photo's own permalink anchor names the QUOTED status, and that is the
// signal that separates them. 124 reverted a `[role="link"]` version of this exclusion
// because it dropped the tweet's OWN photos — which is why every case below asserts what
// SURVIVES as well as what goes: a rule that drops everything must not pass here.

const FOCAL = "1780000000000000000";
const QUOTED = "1770000000000000009";

test("belongsToStatus: drops only a photo that names a DIFFERENT status", () => {
  assert.equal(belongsToStatus({ statusId: FOCAL }, FOCAL), true);
  assert.equal(belongsToStatus({ statusId: QUOTED }, FOCAL), false);
  // No signal → keep. An older harvest, the phone's preprocessor, a render with no
  // anchor: none of them are evidence that the photo is somebody else's.
  assert.equal(belongsToStatus({}, FOCAL), true);
  // No focal id (a non-status URL) → nothing to compare against, so keep.
  assert.equal(belongsToStatus({ statusId: QUOTED }, null), true);
});

test("twitter: a quoted tweet's photo is excluded, the tweet's OWN photos kept", () => {
  const h = harvest({
    url: `https://x.com/designer/status/${FOCAL}`,
    media: [
      xphoto("OWN1", 0, FOCAL),
      xphoto("QUOTED", 0, QUOTED), // the quoted tweet's, inside the SAME article
      xphoto("OWN2", 0, FOCAL),
    ],
  });
  const p = twitter.extract(h);
  // Excluded — the whole point.
  assert.equal(p.mediaUrls.includes(orig("QUOTED")), false);
  // Kept — the other half of the point. Both own photos, in DOM order, and the card is
  // the tweet's own rather than the quoted one.
  assert.deepEqual(p.mediaUrls, [orig("OWN1"), orig("OWN2")]);
  assert.equal(p.mediaUrl, orig("OWN1"));
});

test("twitter: a quote tweet with no photo of its own → a text card, not the quoted image", () => {
  // The card follows the same list, so a quoter who added nothing captures as text
  // rather than borrowing an image whose provenance would be the quoter's permalink.
  const p = twitter.extract(harvest({
    url: `https://x.com/designer/status/${FOCAL}`,
    media: [xphoto("QUOTED", 0, QUOTED)],
  }));
  assert.equal(p.mediaUrl, null);
  assert.deepEqual(p.mediaUrls, []);
});

test("twitter: a harvest with no status ids keeps every focal photo", () => {
  // Back-compat, and the phone: `PagePreprocessor.js` does not read the anchor, so its
  // snapshots carry no `statusId` and must behave exactly as they did before P11.
  const p = twitter.extract(harvest({
    url: `https://x.com/designer/status/${FOCAL}`,
    media: [xphoto("P1"), xphoto("P2")],
  }));
  assert.deepEqual(p.mediaUrls, [orig("P1"), orig("P2")]);
});

test("twitter: a right-clicked quoted photo is still honored — an explicit choice wins", () => {
  // `context.srcUrl` is the user pointing at an image and asking for THAT one; the
  // exclusion is about what the extractor collects on its own.
  const h = harvest({
    url: `https://x.com/designer/status/${FOCAL}`,
    media: [xphoto("OWN1", 0, FOCAL), xphoto("QUOTED", 0, QUOTED)],
  });
  const p = twitter.extract(h, { srcUrl: "https://pbs.twimg.com/media/QUOTED?format=jpg&name=large" });
  assert.equal(p.mediaUrl, orig("QUOTED"));
  assert.deepEqual(p.mediaUrls, [orig("QUOTED"), orig("OWN1")]);
});

test("twitter: prefers the LIVE url over a stale canonical", () => {
  const h = harvest({
    url: "https://x.com/designer/status/42?s=20&t=abc",
    canonical: "https://x.com/", // stale SPA canonical
    media: [img("https://pbs.twimg.com/media/X?format=jpg&name=large", 900, 900)],
  });
  const p = twitter.extract(h);
  assert.equal(p.originalURL, "https://x.com/designer/status/42"); // live url, query stripped
});

test("twitter: video tweet → uses the video poster", () => {
  const h = harvest({
    url: "https://x.com/a/status/1",
    media: [
      { kind: "video-poster", src: "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg", width: 1280, height: 720, alt: null },
    ],
  });
  assert.equal(
    twitter.extract(h).mediaUrl,
    "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg"
  );
});

test("twitter: video tweet → captured live frame wins over the poster, poster is the fallback", () => {
  const frame = "data:image/png;base64,AAAABBBBCCCC"; // canvas grab of the on-screen frame
  const h = harvest({
    url: "https://x.com/a/status/1",
    media: [
      { kind: "video-frame", src: frame, width: 1280, height: 720, alt: null },
      { kind: "video-poster", src: "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg", width: 1280, height: 720, alt: null },
    ],
  });
  const p = twitter.extract(h);
  assert.equal(p.mediaUrl, frame); // the exact frame, not rewritten
  assert.equal(p.mediaUrlFallback, "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg");
});

test("twitter: video tweet with no decodable frame → falls back to the poster", () => {
  // readyState/taint failures mean harvest emits only the poster (no video-frame).
  const h = harvest({
    url: "https://x.com/a/status/1",
    media: [
      { kind: "video-poster", src: "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg", width: 1280, height: 720, alt: null },
    ],
  });
  assert.equal(
    twitter.extract(h).mediaUrl,
    "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg"
  );
});

test("twitter: a real photo still beats a video frame (higher fidelity than a canvas grab)", () => {
  const h = harvest({
    url: "https://x.com/a/status/1",
    media: [
      { kind: "video-frame", src: "data:image/png;base64,ZZZZ", width: 640, height: 360, alt: null },
      img("https://pbs.twimg.com/media/PHOTO?format=jpg&name=medium", 1200, 800),
    ],
  });
  assert.equal(
    twitter.extract(h).mediaUrl,
    "https://pbs.twimg.com/media/PHOTO?format=jpg&name=orig"
  );
});

test("twitter: no DOM media → falls back to og:image", () => {
  const h = harvest({
    url: "https://x.com/a/status/1",
    metas: { "og:image": "https://pbs.twimg.com/media/FALLBACK.jpg" },
    media: [],
  });
  assert.equal(twitter.extract(h).mediaUrl, "https://pbs.twimg.com/media/FALLBACK.jpg");
});

test("pinterest: largest i.pinimg image, rewritten to originals; ignores generic og logo + stale canonical", () => {
  const h = harvest({
    url: "https://www.pinterest.com/pin/12345/",
    canonical: "https://www.pinterest.com/", // the reported bug: stale root
    metas: { "og:image": "https://s.pinimg.com/images/facebook_share_image.png" }, // generic logo
    media: [
      img("https://i.pinimg.com/236x/aa/bb/cc/related.jpg", 236, 300), // related pin thumb
      img("https://i.pinimg.com/736x/dd/ee/ff/closeup.jpg", 736, 980), // the closeup pin
    ],
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "pinterest");
  // NOT pinterest.com, NOT the s.pinimg logo:
  assert.equal(p.originalURL, "https://www.pinterest.com/pin/12345/");
  assert.equal(p.mediaUrl, "https://i.pinimg.com/originals/dd/ee/ff/closeup.jpg");
  // rendered size is kept as a fetch fallback in case /originals/ 404s
  assert.equal(p.mediaUrlFallback, "https://i.pinimg.com/736x/dd/ee/ff/closeup.jpg");
  assert.deepEqual(p.rawMetadata, { pinId: "12345" });
});

test("instagram: handle from og:title, largest cdn image, shortcode from live url", () => {
  const h = harvest({
    url: "https://www.instagram.com/p/CxYz123/",
    metas: {
      "og:title": "Jane Doe (@jane.doe) on Instagram",
      "og:description": "a caption",
      "og:image": "https://scontent.cdninstagram.com/low.jpg",
    },
    media: [img("https://scontent.cdninstagram.com/v/hi-res.jpg", 1080, 1080)],
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "instagram");
  assert.equal(p.authorHandle, "@jane.doe");
  assert.equal(p.mediaUrl, "https://scontent.cdninstagram.com/v/hi-res.jpg");
  assert.deepEqual(p.rawMetadata, { shortcode: "CxYz123" });
});

test("cosmos: elementId from /e/{id}, media from cosmos cdn", () => {
  const h = harvest({
    url: "https://www.cosmos.so/e/el-42",
    media: [img("https://images.cosmos.so/el.jpg", 1000, 1000)],
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "cosmos");
  assert.equal(p.mediaUrl, "https://images.cosmos.so/el.jpg");
  assert.deepEqual(p.rawMetadata, { elementId: "el-42" });
});

test("web fallback: og:image preferred (reliable on non-SPA articles)", () => {
  const h = harvest({
    url: "https://blog.example.com/post",
    metas: {
      "og:image": "https://cdn.example.com/hero.png",
      "og:site_name": "Example Blog",
    },
    media: [img("https://cdn.example.com/tiny-logo.png", 32, 32)],
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "web");
  assert.equal(p.mediaUrl, "https://cdn.example.com/hero.png");
  assert.equal(p.authorName, "Example Blog");
});

test("no media and no og:image → mediaUrl null (SW reports 'no image')", () => {
  const p = extractProvenance(harvest({ url: "https://x.com/a/status/1" }));
  assert.equal(p.mediaUrl, null);
});

test("pinterest FROM THE FEED: right-clicked pin link+image → pin URL + that image", () => {
  // The reported scenario: user is on the feed (location.href = pinterest.com),
  // right-clicks a specific pin. context carries the pin's link + image.
  const h = harvest({
    url: "https://www.pinterest.com/", // the feed, NOT a pin
    canonical: "https://www.pinterest.com/",
    media: [img("https://i.pinimg.com/474x/aa/bb/cc/other.jpg", 474, 600)],
  });
  const context = {
    linkUrl: "https://www.pinterest.com/pin/999/",
    srcUrl: "https://i.pinimg.com/474x/dd/ee/ff/clicked.jpg",
  };
  const p = extractProvenance(h, context);
  assert.equal(p.originalURL, "https://www.pinterest.com/pin/999/"); // not pinterest.com
  assert.equal(p.mediaUrl, "https://i.pinimg.com/originals/dd/ee/ff/clicked.jpg"); // the clicked image
  assert.equal(p.mediaUrlFallback, "https://i.pinimg.com/474x/dd/ee/ff/clicked.jpg");
  assert.deepEqual(p.rawMetadata, { pinId: "999" });
});

test("twitter: right-clicked image (context.srcUrl) wins, at full res", () => {
  const h = harvest({
    url: "https://x.com/designer/status/42",
    media: [img("https://pbs.twimg.com/media/OTHER?format=jpg&name=small", 100, 100)],
  });
  const context = { srcUrl: "https://pbs.twimg.com/media/CLICKED?format=jpg&name=360x360" };
  const p = extractProvenance(h, context);
  assert.equal(p.mediaUrl, "https://pbs.twimg.com/media/CLICKED?format=jpg&name=orig");
  assert.equal(p.mediaUrlFallback, "https://pbs.twimg.com/media/CLICKED?format=jpg&name=360x360");
  assert.equal(p.originalURL, "https://x.com/designer/status/42");
});

test("instagram FROM THE FEED: right-clicked post link + image → post URL + that image", () => {
  const h = harvest({
    url: "https://www.instagram.com/", // the feed, NOT a post
    canonical: "https://www.instagram.com/",
    media: [img("https://scontent.cdninstagram.com/other.jpg", 500, 500)],
  });
  const context = {
    linkUrl: "https://www.instagram.com/p/CxYz123/",
    srcUrl: "https://scontent.cdninstagram.com/v/clicked.jpg",
  };
  const p = extractProvenance(h, context);
  assert.equal(p.platform, "instagram");
  assert.equal(p.originalURL, "https://www.instagram.com/p/CxYz123/"); // not the feed
  assert.equal(p.mediaUrl, "https://scontent.cdninstagram.com/v/clicked.jpg"); // the clicked image
  assert.deepEqual(p.rawMetadata, { shortcode: "CxYz123" });
});

test("cosmos: right-clicked element link + image → element URL + that image", () => {
  const h = harvest({
    url: "https://www.cosmos.so/", // a listing page, NOT the element
    media: [img("https://images.cosmos.so/other.jpg", 800, 800)],
  });
  const context = {
    linkUrl: "https://www.cosmos.so/e/el-99",
    srcUrl: "https://images.cosmos.so/clicked.jpg",
  };
  const p = extractProvenance(h, context);
  assert.equal(p.platform, "cosmos");
  assert.equal(p.originalURL, "https://www.cosmos.so/e/el-99");
  assert.equal(p.mediaUrl, "https://images.cosmos.so/clicked.jpg");
  assert.deepEqual(p.rawMetadata, { elementId: "el-99" });
});

test("findExtractor routes each host to its extractor", () => {
  assert.equal(findExtractor("https://x.com/a/status/1"), twitter);
  assert.equal(findExtractor("https://www.pinterest.com/pin/1/"), pinterest);
  assert.equal(findExtractor("https://www.instagram.com/p/x/"), instagram);
  assert.equal(findExtractor("https://cosmos.so/e/1"), cosmos);
  assert.equal(findExtractor("https://www.xiaohongshu.com/explore/1"), rednote);
  assert.equal(findExtractor("https://www.rednote.com/explore/1"), rednote);
  assert.equal(findExtractor("https://other.example/"), web);
});

// MARK: - rednote (020 · K2)
// One product on two domains, and a signed-webp → unsigned-original media rule.

test("rednote: noteId from /explore/{id}, media rewritten to the unsigned original", () => {
  const h = harvest({
    url: "https://www.xiaohongshu.com/explore/6650a1b2c3d4e5f600000001",
    metas: { "og:site_name": "小红书", "og:title": "Editorial grid study" },
    media: [
      img("https://sns-avatar-qc.rednotecdn.com/avatar/tiny.jpg", 48, 48),
      img("https://sns-web-i10.rednotecdn.com/1717000000/9f3c1d/1040g2sg31key!nc_n_webp_mw_1", 1200, 1600),
    ],
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "rednote");
  assert.equal(p.originalURL, "https://www.xiaohongshu.com/explore/6650a1b2c3d4e5f600000001");
  // The signature segments and the `!` transform suffix are gone; the bare key
  // is served full-resolution by the plain image node.
  assert.equal(p.mediaUrl, "http://sns-i27.rednotecdn.com/1040g2sg31key");
  assert.equal(
    p.mediaUrlFallback,
    "https://sns-web-i10.rednotecdn.com/1717000000/9f3c1d/1040g2sg31key!nc_n_webp_mw_1");
  assert.equal(p.authorName, "小红书");
  assert.equal(p.title, "Editorial grid study");
  assert.deepEqual(p.rawMetadata, { noteId: "6650a1b2c3d4e5f600000001" });
});

test("rednote: the rednote.com domain and /discovery/item/{id} both resolve a note", () => {
  const h = harvest({
    url: "https://www.rednote.com/discovery/item/6650a1b2c3d4e5f600000002",
    media: [img("https://sns-web-i5.rednotecdn.com/1/s/keyB!nc_n_webp_mw_1", 900, 1200)],
  });
  const p = extractProvenance(h);
  assert.equal(p.platform, "rednote");
  assert.equal(p.mediaUrl, "http://sns-i27.rednotecdn.com/keyB");
  assert.deepEqual(p.rawMetadata, { noteId: "6650a1b2c3d4e5f600000002" });
});

test("rednote FROM A BOARD: right-clicked note link + image → note URL + that image", () => {
  const h = harvest({
    url: "https://www.xiaohongshu.com/board/6650000000000000000000ff", // the board, NOT a note
    canonical: "https://www.xiaohongshu.com/",
    media: [img("https://sns-web-i10.rednotecdn.com/1/s/other!nc_n_webp_mw_1", 800, 800)],
  });
  const context = {
    linkUrl: "https://www.xiaohongshu.com/explore/6650a1b2c3d4e5f600000003?xsec_token=ABC",
    srcUrl: "https://sns-web-i10.rednotecdn.com/1717/9f3c/clickedKey!nc_n_webp_mw_1",
  };
  const p = extractProvenance(h, context);
  // The `xsec_token` query is dropped by cleanURL — a short-lived credential has
  // no business in stored provenance.
  assert.equal(p.originalURL, "https://www.xiaohongshu.com/explore/6650a1b2c3d4e5f600000003");
  assert.equal(p.mediaUrl, "http://sns-i27.rednotecdn.com/clickedKey");
  assert.deepEqual(p.rawMetadata, { noteId: "6650a1b2c3d4e5f600000003" });
});

test("rednote: a board page with no note link keeps the board URL and no noteId", () => {
  const h = harvest({
    url: "https://www.xiaohongshu.com/board/6650000000000000000000ff",
    metas: { "og:image": "https://ci.xiaohongshu.com/generic-card.png" },
  });
  const p = rednote.extract(h);
  assert.equal(p.originalURL, "https://www.xiaohongshu.com/board/6650000000000000000000ff");
  // No CDN media on the page → og:image, unrewritten, and no fallback to keep.
  assert.equal(p.mediaUrl, "https://ci.xiaohongshu.com/generic-card.png");
  assert.equal(p.mediaUrlFallback, null);
  assert.deepEqual(p.rawMetadata, {});
});

test("rednote: match covers both domains and their subdomains, but not a suffix spoof", () => {
  assert.equal(rednote.match("https://www.xiaohongshu.com/explore/1"), true);
  assert.equal(rednote.match("https://xiaohongshu.com/explore/1"), true);
  assert.equal(rednote.match("https://www.rednote.com/explore/1"), true);
  assert.equal(rednote.match("https://rednote.com/"), true);
  assert.equal(rednote.match("https://edith.xiaohongshu.com/api/x"), true);
  // Suffix spoofs and near-misses must NOT match.
  assert.equal(rednote.match("https://rednote.com.evil.com/explore/1"), false);
  assert.equal(rednote.match("https://xiaohongshu.com.evil.com/"), false);
  assert.equal(rednote.match("https://notrednote.com/"), false);
  assert.equal(rednote.match("https://myxiaohongshu.com/"), false);
  assert.equal(rednote.match("not a url"), false);
});

test("toRednoteOriginal: strips signing segments + `!` suffix, is idempotent, passes others through", () => {
  assert.equal(
    toRednoteOriginal("https://sns-web-i10.rednotecdn.com/1717000000/9f3c1d/keyA!nc_n_webp_mw_1"),
    "http://sns-i27.rednotecdn.com/keyA");
  // Already bare → itself (idempotent, so a re-run of the rule is harmless).
  assert.equal(
    toRednoteOriginal("http://sns-i27.rednotecdn.com/keyA"),
    "http://sns-i27.rednotecdn.com/keyA");
  // A non-rednote URL, garbage, and null are passed straight through.
  assert.equal(
    toRednoteOriginal("https://i.pinimg.com/474x/a.jpg"), "https://i.pinimg.com/474x/a.jpg");
  assert.equal(toRednoteOriginal("not a url"), "not a url");
  assert.equal(toRednoteOriginal(null), null);
});

// The key is EVERYTHING after the two signing segments, which is not always one
// segment. Reading only the last one dropped `oss-sg/spectrum/` and produced a
// verified 404 (098 D2 / changelog 467) — masked by `mediaUrlFallback` as a
// silent 5x quality loss rather than a visible failure, which is why it needs a
// regression test rather than a comment. Both URLs below are verbatim from the
// live captures of 2026-09-13.
test("toRednoteOriginal: a MULTI-SEGMENT key keeps every segment (the 404 regression)", () => {
  assert.equal(
    toRednoteOriginal(
      "http://sns-web-i10.rednotecdn.com/202609131347/0bdf336689816bd1691a3c351e3be0ab"
      + "/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg!nd_dft_wlteh_webp_3"),
    // Verified live: this returns 200 image/jpeg 240,729 B. Dropping `oss-sg/spectrum/`
    // returns 404.
    "http://sns-i27.rednotecdn.com/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg");
  // A board-feed cover is single-segment and must keep working unchanged.
  assert.equal(
    toRednoteOriginal(
      "http://sns-web-i10.rednotecdn.com/202609131332/43d5d4fbe9c41cf7739cdb99c9da6a47"
      + "/1040g2sg323m6dg190oeg45k492l2qtne6ac1ld0!nc_n_webp_prv_1"),
    "http://sns-i27.rednotecdn.com/1040g2sg323m6dg190oeg45k492l2qtne6ac1ld0");
});

test("rednote: a note-detail image (multi-segment key) captures full-res, not the webp", () => {
  // The end-to-end shape of the 467 bug: `mediaUrlFallback` always loads, so a
  // broken `mediaUrl` never surfaced as an error — the capture just silently
  // became the 47 KB signed webp instead of the 240 KB original. Both fields are
  // asserted together because it is the PAIR that made the fault invisible.
  const signed =
    "http://sns-web-i10.rednotecdn.com/202609131347/0bdf336689816bd1691a3c351e3be0ab"
    + "/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg!nd_dft_wlteh_webp_3";
  const h = harvest({
    url: "https://www.rednote.com/explore/6a9f696e000000000d020daa",
    media: [img(signed, 1242, 1660)],
  });
  const p = extractProvenance(h);
  assert.equal(
    p.mediaUrl,
    "http://sns-i27.rednotecdn.com/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg");
  assert.equal(p.mediaUrlFallback, signed);
});

test("toRednoteOriginal: idempotent on a multi-segment key, and leaves short paths alone", () => {
  const bare = "http://sns-i27.rednotecdn.com/oss-sg/spectrum/1040g3ug324rbosk72m005qk4p310rhpvdg92bqg";
  // Re-running the rule must not eat the `oss-sg/spectrum/` prefix a second time.
  assert.equal(toRednoteOriginal(bare), bare);
  assert.equal(toRednoteOriginal(toRednoteOriginal(bare)), bare);
  // Too short to be `<ts>/<sig>/<key>` — an avatar is not a signed note asset, so
  // it is left exactly as it is rather than rewritten onto the origin host.
  assert.equal(
    toRednoteOriginal("https://sns-avatar-qc.rednotecdn.com/avatar/tiny.jpg"),
    "https://sns-avatar-qc.rednotecdn.com/avatar/tiny.jpg");
  assert.equal(
    toRednoteOriginal("https://sns-web-i10.rednotecdn.com/onlyone"),
    "https://sns-web-i10.rednotecdn.com/onlyone");
});

// MARK: - shared full-resolution rewrites (base.js, 6A)
// The exact rules the DOM extractors AND the future bulk JSON mappers reuse.

test("toOrigName rewrites name= to orig; passes through data: and unparseable", () => {
  assert.equal(
    toOrigName("https://pbs.twimg.com/media/A?format=jpg&name=small"),
    "https://pbs.twimg.com/media/A?format=jpg&name=orig");
  // No name param → unchanged host/path (still a valid URL round-trip).
  assert.equal(
    toOrigName("https://pbs.twimg.com/media/B.jpg"),
    "https://pbs.twimg.com/media/B.jpg");
  assert.equal(toOrigName("data:image/jpeg;base64,AAAA"), "data:image/jpeg;base64,AAAA");
  assert.equal(toOrigName(null), null);
  assert.equal(toOrigName("not a url"), "not a url");
});

test("toOrigName moves webp to jpg, since orig cannot serve webp", () => {
  // The pair 404s. A rewrite that yields a dead URL is worse than no rewrite: the caller
  // falls back to the rendered size and the capture looks fine at the wrong resolution.
  assert.equal(
    toOrigName("https://pbs.twimg.com/media/A?format=webp&name=small"),
    "https://pbs.twimg.com/media/A?format=jpg&name=orig",
  );
  // Only that one incompatibility — a format that serves orig is left alone.
  assert.equal(
    toOrigName("https://pbs.twimg.com/media/A?format=png&name=small"),
    "https://pbs.twimg.com/media/A?format=png&name=orig",
  );
  // Nothing is rewritten when there is no name= to rewrite, format included.
  assert.equal(
    toOrigName("https://pbs.twimg.com/media/A?format=webp"),
    "https://pbs.twimg.com/media/A?format=webp",
  );
});

test("toOrigName { addIfAbsent } adds name=orig to a bare URL (bulk X mapper path)", () => {
  // Default: a bare URL is left alone (the DOM extractor's contract).
  assert.equal(toOrigName("https://pbs.twimg.com/media/B.jpg"), "https://pbs.twimg.com/media/B.jpg");
  // addIfAbsent: X's timeline JSON gives a bare media_url_https → request orig.
  assert.equal(
    toOrigName("https://pbs.twimg.com/media/B.jpg", { addIfAbsent: true }),
    "https://pbs.twimg.com/media/B.jpg?name=orig");
  assert.equal(toOrigName("data:image/png;base64,AA", { addIfAbsent: true }), "data:image/png;base64,AA");
});

test("toOriginals rewrites an i.pinimg sized segment to /originals/", () => {
  assert.equal(
    toOriginals("https://i.pinimg.com/474x/ab/cd/ef.jpg"),
    "https://i.pinimg.com/originals/ab/cd/ef.jpg");
  assert.equal(
    toOriginals("https://i.pinimg.com/236x/ab/cd/ef.jpg"),
    "https://i.pinimg.com/originals/ab/cd/ef.jpg");
  // Already-original / non-pinimg → unchanged.
  assert.equal(
    toOriginals("https://i.pinimg.com/originals/ab/cd/ef.jpg"),
    "https://i.pinimg.com/originals/ab/cd/ef.jpg");
  assert.equal(toOriginals(null), null);
});

// ---------------------------------------------------------------------------
// Status permalink normalization — the provenance fork found on a live feed.
// ---------------------------------------------------------------------------

test("toStatusPermalink: drops the sub-pages X hangs off a tweet", () => {
  const canonical = "https://x.com/Starlink/status/2077559767858589763";
  for (const suffix of ["/analytics", "/photo/1", "/photo/3", "/history", "/likes", "/retweets"]) {
    assert.equal(toStatusPermalink(canonical + suffix), canonical, `failed for ${suffix}`);
  }
});

test("toStatusPermalink: a canonical permalink is unchanged, and it is idempotent", () => {
  const canonical = "https://x.com/designer/status/1780000000000000000";
  assert.equal(toStatusPermalink(canonical), canonical);
  assert.equal(toStatusPermalink(toStatusPermalink(canonical + "/photo/1")), canonical);
});

test("toStatusPermalink: a NON-status URL passes through untouched", () => {
  for (const url of [
    "https://x.com/designer",
    "https://x.com/search",
    "https://x.com/i/bookmarks",
    "https://x.com/",
  ]) {
    assert.equal(toStatusPermalink(url), url);
  }
});

test("toStatusPermalink: preserves the origin, so twitter.com stays twitter.com", () => {
  assert.equal(
    toStatusPermalink("https://twitter.com/designer/status/1780000000000000000/photo/1"),
    "https://twitter.com/designer/status/1780000000000000000",
  );
});

test("toStatusPermalink: a truncated or unparseable status URL is passed back, not mangled", () => {
  assert.equal(toStatusPermalink("https://x.com/designer/status"), "https://x.com/designer/status");
  assert.equal(toStatusPermalink("not a url"), "not a url");
  assert.equal(toStatusPermalink(""), "");
});

test("twitter: a right-clicked PHOTO link yields the post permalink, not /photo/1", () => {
  // The desktop fork: right-clicking the image gives linkUrl=/photo/1, right-clicking the
  // text gives the bare permalink. Both must produce ONE originalURL, because 18A dedup
  // keys on provenance.
  const h = harvest({
    url: "https://x.com/home",
    media: [img("https://pbs.twimg.com/media/REAL?format=jpg&name=small", 1200, 800)],
  });
  const viaPhoto = extractProvenance(h, {
    linkUrl: "https://x.com/designer/status/1780000000000000000/photo/1",
    srcUrl: "https://pbs.twimg.com/media/REAL?format=jpg&name=small",
  });
  const viaText = extractProvenance(h, {
    linkUrl: "https://x.com/designer/status/1780000000000000000",
    srcUrl: "https://pbs.twimg.com/media/REAL?format=jpg&name=small",
  });
  assert.equal(viaPhoto.originalURL, "https://x.com/designer/status/1780000000000000000");
  assert.equal(viaPhoto.originalURL, viaText.originalURL);
  assert.deepEqual(viaPhoto.rawMetadata, { tweetId: "1780000000000000000" });
});

test("twitter: an /analytics-only post (a promoted tweet) still yields the permalink", () => {
  // Observed live: a promoted post whose ONLY status link was /analytics, so no anchor
  // choice could have rescued it — normalization is the only fix.
  const h = harvest({ url: "https://x.com/home", media: [] });
  const p = extractProvenance(h, {
    linkUrl: "https://x.com/Starlink/status/2077559767858589763/analytics",
  });
  assert.equal(p.originalURL, "https://x.com/Starlink/status/2077559767858589763");
  assert.equal(p.authorHandle, "@Starlink");
  assert.deepEqual(p.rawMetadata, { tweetId: "2077559767858589763" });
});

test("twitter: a LIVE url sitting on the photo lightbox normalizes too", () => {
  const h = harvest({
    url: "https://x.com/designer/status/1780000000000000000/photo/1",
    media: [img("https://pbs.twimg.com/media/REAL?format=jpg&name=small", 1200, 800)],
  });
  const p = extractProvenance(h);
  assert.equal(p.originalURL, "https://x.com/designer/status/1780000000000000000");
});

test("twitter: the DOM path now agrees with the bulk mapper's composed permalink", () => {
  // bulk-twitter.js:280 composes `https://{host}/{screenName}/status/{tweetId}`. A DOM
  // capture of the same tweet must produce that exact string or the two producers fork.
  const h = harvest({
    url: "https://x.com/designer/status/1780000000000000000/photo/1",
    media: [img("https://pbs.twimg.com/media/REAL?format=jpg&name=small", 1200, 800)],
  });
  const p = extractProvenance(h);
  assert.equal(p.originalURL, `https://x.com/designer/status/1780000000000000000`);
});

// ---------------------------------------------------------------------------
// Instagram permalink normalization — measured on a live feed, not reasoned about.
// ---------------------------------------------------------------------------

test("toPostPermalink: drops a post sub-page, keeping the trailing slash bulk composes", () => {
  const canonical = "https://www.instagram.com/p/DceVsiRH8HO/";
  for (const suffix of ["liked_by/", "comments/", "liked_by", "related/"]) {
    assert.equal(toPostPermalink(canonical + suffix), canonical, `failed for ${suffix}`);
  }
});

test("toPostPermalink: a reel keeps its /reel/ segment (honest provenance, per bulk)", () => {
  assert.equal(
    toPostPermalink("https://www.instagram.com/reel/ABC123/liked_by/"),
    "https://www.instagram.com/reel/ABC123/",
  );
});

test("toPostPermalink: adds the trailing slash a bare link may omit, and is idempotent", () => {
  const canonical = "https://www.instagram.com/p/DceVsiRH8HO/";
  assert.equal(toPostPermalink("https://www.instagram.com/p/DceVsiRH8HO"), canonical);
  assert.equal(toPostPermalink(canonical), canonical);
  assert.equal(toPostPermalink(toPostPermalink(canonical + "liked_by/")), canonical);
});

test("toPostPermalink: a NON-post URL passes through untouched", () => {
  for (const url of [
    "https://www.instagram.com/someone/",
    "https://www.instagram.com/explore/",
    "https://www.instagram.com/",
    "not a url",
  ]) {
    assert.equal(toPostPermalink(url), url);
  }
});

test("instagram: a /liked_by/ feed link yields the post permalink", () => {
  // Measured: on a mobile-width feed EVERY post link was /liked_by/ and no bare /p/{code}/
  // appeared, so this is the normal case rather than an edge one.
  const h = harvest({
    url: "https://www.instagram.com/",
    media: [img("https://scontent.cdninstagram.com/v/REAL.jpg", 1080, 1080)],
  });
  const p = extractProvenance(h, { linkUrl: "https://www.instagram.com/p/DceVsiRH8HO/liked_by/" });
  assert.equal(p.originalURL, "https://www.instagram.com/p/DceVsiRH8HO/");
  assert.deepEqual(p.rawMetadata, { shortcode: "DceVsiRH8HO" });
});

test("instagram: the DOM path agrees with bulk-instagram.js's composed permalink", () => {
  // bulk-instagram.js:179 → `https://{host}/{p|reel}/{code}/`. A DOM capture of the same
  // post must produce that exact string or the two producers fork.
  const h = harvest({ url: "https://www.instagram.com/p/DceVsiRH8HO/liked_by/", media: [] });
  assert.equal(extractProvenance(h).originalURL, "https://www.instagram.com/p/DceVsiRH8HO/");
});

// ---------------------------------------------------------------------------
// Pinterest host canonicalization (issue 21A) — regional subdomains fork provenance.
// ---------------------------------------------------------------------------

test("canonicalPinterestHost: regional subdomains and the bare apex fold to www", () => {
  for (const host of ["REDACTED", "uk.pinterest.com", "de.pinterest.com",
                      "pinterest.com", "www.pinterest.com"]) {
    assert.equal(canonicalPinterestHost(host), "www.pinterest.com", `failed for ${host}`);
  }
});

test("canonicalPinterestHost: pinterest.co.uk is a DIFFERENT domain and is left alone", () => {
  // A separate domain, not a subdomain — folding it in is a bigger claim than the
  // observation supports, and hostIs is false for it.
  assert.equal(canonicalPinterestHost("pinterest.co.uk"), "pinterest.co.uk");
  assert.equal(canonicalPinterestHost("www.pinterest.co.uk"), "www.pinterest.co.uk");
  assert.equal(canonicalPinterestHost("pin.it"), "pin.it");
  assert.equal(canonicalPinterestHost("evil-pinterest.com"), "evil-pinterest.com");
});

test("canonicalPinterestHost: a suffix spoof is not folded", () => {
  assert.equal(canonicalPinterestHost("pinterest.com.evil.com"), "pinterest.com.evil.com");
});

test("pinterest: a pin captured on a regional subdomain gets the canonical permalink", () => {
  const h = harvest({
    url: "https://REDACTED/",
    media: [img("https://i.pinimg.com/474x/ab/cd/PIN.jpg", 736, 1104)],
  });
  const p = extractProvenance(h, {
    linkUrl: "https://REDACTED/pin/804877764689837649/",
    srcUrl: "https://i.pinimg.com/474x/ab/cd/PIN.jpg",
  });
  assert.equal(p.originalURL, "https://www.pinterest.com/pin/804877764689837649/");
  assert.deepEqual(p.rawMetadata, { pinId: "804877764689837649" });
});

test("pinterest: the same pin from two regions yields ONE originalURL", () => {
  const shot = (host) => extractProvenance(
    harvest({ url: `https://${host}/`, media: [img("https://i.pinimg.com/474x/ab/cd/PIN.jpg", 736, 1104)] }),
    { linkUrl: `https://${host}/pin/804877764689837649/` },
  ).originalURL;
  assert.equal(shot("REDACTED"), shot("www.pinterest.com"));
});

test("pinterest: a pinterest.co.uk capture keeps its own host", () => {
  const p = extractProvenance(
    harvest({ url: "https://www.pinterest.co.uk/", media: [] }),
    { linkUrl: "https://www.pinterest.co.uk/pin/804877764689837649/" },
  );
  assert.equal(p.originalURL, "https://www.pinterest.co.uk/pin/804877764689837649/");
});

// ---------------------------------------------------------------------------
// The cross-extractor invariant `captureCore` leans on (096 § D7 review, 8B)
// ---------------------------------------------------------------------------

// `sw.js`'s `captureCore` asks `planCapture` whether there is anything to capture, and
// `planCapture` builds its candidates from BOTH `mediaUrl` and `mediaUrlFallback`. Before
// that it asked `!provenance.mediaUrl` alone — narrower, and safe only because no extractor
// can produce a fallback without a primary.
//
// That is a real contract and it was asserted nowhere. It holds today because every rewrite
// helper is TOTAL: `toOrigName` returns `src` when `new URL` throws, `toOriginals` returns
// `src` when its regex misses, `toRednoteOriginal` returns `src` in every branch. Each
// extractor then computes `mediaUrlFallback = rendered && mediaUrl !== rendered ? rendered
// : null`, so a null `mediaUrl` can only come from a null `rendered`, which makes the
// fallback null too.
//
// The shape that breaks it is the obvious one to write: a regex-replace helper returning
// `null` when it does not match. Nothing would fail loudly — a capture would report
// `no-image` and be lost with a usable URL sitting in its provenance. So the promise is
// pinned here, at the layer that makes it.

/** Harvests chosen to drive each extractor down its no-media path, plus the shapes most
 * likely to make a rewrite helper hand back null: an unparseable src, and a src that
 * matches no rewrite rule. */
const NO_MEDIA_CASES = [
  { label: "twitter, no media at all", url: "https://x.com/a/status/1", media: [] },
  {
    label: "twitter, an unparseable media src",
    url: "https://x.com/a/status/1",
    media: [img("not a url at all", 800, 600)],
  },
  { label: "pinterest, no media at all", url: "https://www.pinterest.com/pin/1/", media: [] },
  {
    label: "pinterest, a src matching no /NNNx/ rule",
    url: "https://www.pinterest.com/pin/1/",
    media: [img("https://i.pinimg.com/unsized/a.jpg", 800, 600)],
  },
  { label: "instagram, no media at all", url: "https://www.instagram.com/p/ABC/", media: [] },
  { label: "cosmos, no media at all", url: "https://www.cosmos.so/e/1", media: [] },
  { label: "rednote, no media at all", url: "https://www.xiaohongshu.com/explore/1", media: [] },
  {
    label: "rednote, a src off the CDN",
    url: "https://www.xiaohongshu.com/explore/1",
    media: [img("https://elsewhere.example/a.jpg", 800, 600)],
  },
  { label: "web, no media at all", url: "https://example.com/article", media: [] },
];

test("no extractor produces a mediaUrlFallback without a mediaUrl", () => {
  for (const testCase of NO_MEDIA_CASES) {
    const p = extractProvenance(harvest({ url: testCase.url, media: testCase.media }));
    if (p.mediaUrl === null || p.mediaUrl === undefined) {
      assert.ok(
        p.mediaUrlFallback === null || p.mediaUrlFallback === undefined,
        `${testCase.label}: mediaUrl is absent but mediaUrlFallback is `
        + `${JSON.stringify(p.mediaUrlFallback)} — captureCore would report no-image and `
        + `lose a capture that had a usable URL`);
    }
  }
});

// The other half of the same promise, asserted directly on the helpers rather than through
// an extractor: a non-null src must never rewrite to null. This is the property that makes
// the invariant above hold, so it is the one that would break first.
test("every media-URL rewrite helper is total: non-null in, non-null out", () => {
  const inputs = [
    "https://pbs.twimg.com/media/A?format=webp&name=small",
    "https://i.pinimg.com/736x/a.jpg",
    "https://i.pinimg.com/unsized/a.jpg",
    "https://sns-img.rednotecdn.com/x!nd_dft",
    "https://elsewhere.example/a.jpg",
    "not a url at all",
    "data:image/png;base64,AAAA",
    "/relative/path.jpg",
  ];
  for (const src of inputs) {
    for (const [name, rewrite] of [
      ["toOrigName", toOrigName], ["toOriginals", toOriginals],
      ["toRednoteOriginal", toRednoteOriginal],
    ]) {
      assert.ok(
        rewrite(src) != null,
        `${name}(${JSON.stringify(src)}) returned null — a total helper is what keeps `
        + `mediaUrl and mediaUrlFallback from disagreeing`);
    }
  }
});

// ---------------------------------------------------------------------------
// The cross-language rewrite contract (096 review 1A)
// ---------------------------------------------------------------------------

// `PageExtractor.swift` is a hand-written Swift mirror of these rewrite rules, because the
// iOS share extension cannot run JavaScript and the phone needs the same answer the browser
// gives. `host-table.js` already gates the host → platform half of that mirror. It does not
// gate this half — and this half is the one that has actually drifted.
//
// It drifted in THIS branch: `name=orig` and `format=webp` are incompatible, twimg 404s the
// pair, and the fix landed on the phone first (422) and had to be carried back to `base.js`
// by hand afterwards (see .change-log/428 and the `format=webp` note in both files). One
// bug, found once, fixed twice, with nothing to say the second fix was needed.
//
// So the rules move into a fixture both suites read. This is the same device
// `capture-contract.json` uses for the request shape, pointed at the other end of the same
// mirror. The Swift half is in `PageExtractorTests.swift`; if you change a rule here,
// `swift test` in AtelierCapture fails until the mirror agrees.
//
// Deliberately NOT a test of URL normalisation. Every case is a well-formed URL whose
// rewrite is unambiguous, because `URL.toString()` and `URLComponents.string` are entitled
// to disagree about percent-encoding and that is not what this pins.

const REWRITE_CONTRACT = JSON.parse(readFileSync(
  fileURLToPath(new URL("./fixtures/media-rewrite-contract.json", import.meta.url)), "utf8"));

test("rewrite contract: toOrigName matches the fixture the Swift mirror is held to", () => {
  assert.ok(REWRITE_CONTRACT.toOrigName.length > 0, "the contract has toOrigName cases");
  for (const entry of REWRITE_CONTRACT.toOrigName) {
    assert.equal(toOrigName(entry.input), entry.expected, entry.case);
  }
});

test("rewrite contract: toOriginals matches the fixture the Swift mirror is held to", () => {
  assert.ok(REWRITE_CONTRACT.toOriginals.length > 0, "the contract has toOriginals cases");
  for (const entry of REWRITE_CONTRACT.toOriginals) {
    assert.equal(toOriginals(entry.input), entry.expected, entry.case);
  }
});
