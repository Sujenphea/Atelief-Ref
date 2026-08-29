// Atelier Capture — the iOS share extension's page preprocessor (092 · S4b, tier 2).
//
// **Why a test for an iOS file lives in the browser extension's suite.** The file under
// test is `AtelierRefs/AtelierRefsShare/PagePreprocessor.js` — the script Safari runs
// inside a shared page — and it is JavaScript, so `swift test` cannot reach it and no
// Xcode target runs it. `node --test` is the only runner in this repo that can, and this
// is where that runner already looks.
//
// It is the phone's twin of `harvestSignals()` (`src/harvest.js`), which is deliberately
// NOT unit-tested — "minimal and hand-checked", because it is serialized into a page and
// does nothing but read the DOM. This one earns a test anyway, because it does two things
// `harvestSignals` does not: it CAPS what it returns (the snapshot crosses an XPC
// boundary, so a page with 400 images must not) and it indexes elements by their
// containing `<article>` (which is how the Swift extractor scopes a tweet's media to the
// focal tweet rather than a reply's). Those are rules, and rules break.
//
// The DOM is a hand-rolled stub rather than jsdom, matching this suite's zero-dependency
// rule. Only what the file actually touches is implemented, so a stub that drifts fails
// loudly with an undefined function rather than quietly returning nothing.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const SOURCE = fileURLToPath(
  new URL("../../AtelierRefs/AtelierRefsShare/PagePreprocessor.js", import.meta.url),
);

/** An `<img>` / `<video>` / `<meta>` stand-in. `article` names its container, if any. */
function element(properties, article = null) {
  return {
    ...properties,
    article,
    getAttribute(name) {
      return properties[name] ?? null;
    },
    closest(selector) {
      return selector === "article" ? article : null;
    },
  };
}

/**
 * Run the preprocessor against a fake document and return the snapshot it produced.
 * The file assigns a global, so it is evaluated in a `vm` context holding that document —
 * the same way Safari evaluates it in the page's.
 */
function snapshot({ url = "https://example.com/", title = "A page", canonical = null,
                    metas = [], images = [], videos = [], articles = [] } = {}) {
  const document = {
    location: { href: url },
    title,
    querySelector(selector) {
      return selector === "link[rel=canonical]" && canonical ? { href: canonical } : null;
    },
    querySelectorAll(selector) {
      if (selector === "meta[property], meta[name]") return metas;
      if (selector === "img") return images;
      if (selector === "video") return videos;
      if (selector === "article") return articles;
      return [];
    },
  };
  const context = vm.createContext({ document });
  vm.runInContext(readFileSync(SOURCE, "utf8"), context);
  let produced = null;
  context.ExtensionPreprocessingJS.run({
    completionFunction(value) {
      produced = value;
    },
  });
  // Round-tripped through JSON, for two reasons. It is what actually happens to this
  // value — it crosses to the extension as a property list and is decoded from JSON in
  // `PageHarvest.harvest(fromResults:)` — and objects built inside a `vm` context have
  // that context's prototypes, which `assert.deepEqual` refuses to match against this
  // realm's.
  return produced == null ? null : JSON.parse(JSON.stringify(produced));
}

/** A rendered image of a given size. */
function img(src, width, height, article = null) {
  return element({ src, naturalWidth: width, naturalHeight: height, alt: null }, article);
}

test("the snapshot carries the page's identity", () => {
  const result = snapshot({
    url: "https://x.com/ada/status/1",
    title: "  Ada on X  ",
    canonical: "https://x.com/ada/status/1",
    metas: [element({ property: "og:title", content: "hello" })],
  });

  assert.equal(result.url, "https://x.com/ada/status/1");
  assert.equal(result.title, "Ada on X"); // trimmed
  assert.equal(result.canonical, "https://x.com/ada/status/1");
  assert.deepEqual(result.metas, [{ key: "og:title", content: "hello" }]);
});

test("duplicate metas are BOTH returned — which one wins is Swift's decision", () => {
  const result = snapshot({
    metas: [
      element({ property: "og:title", content: "first" }),
      element({ property: "og:title", content: "second" }),
    ],
  });

  assert.equal(result.metas.length, 2);
});

test("images below the icon floor are skipped", () => {
  const result = snapshot({
    images: [
      img("https://example.com/avatar.jpg", 48, 48),
      img("https://example.com/pixel.gif", 1, 1),
      img("https://example.com/wide-but-short.jpg", 1200, 40),
      img("https://example.com/hero.jpg", 1200, 900),
    ],
  });

  assert.deepEqual(result.images.map((i) => i.src), ["https://example.com/hero.jpg"]);
});

test("the image count is capped, keeping DOM order", () => {
  const many = [];
  for (let i = 0; i < 200; i += 1) many.push(img(`https://example.com/${i}.jpg`, 400, 400));

  const result = snapshot({ images: many });

  assert.equal(result.images.length, 80);
  // DOM order, not size order: the X extractor takes the FIRST media in the focal
  // article, so re-sorting here would break scoping in Swift.
  assert.equal(result.images[0].src, "https://example.com/0.jpg");
  assert.equal(result.images[79].src, "https://example.com/79.jpg");
});

test("each image reports the index of its containing article, or -1", () => {
  const focal = {};
  const reply = {};
  const result = snapshot({
    articles: [focal, reply],
    images: [
      img("https://pbs.twimg.com/media/A.jpg", 900, 900, focal),
      img("https://pbs.twimg.com/media/B.jpg", 900, 900, reply),
      img("https://example.com/sidebar.jpg", 400, 400),
    ],
  });

  assert.deepEqual(result.images.map((i) => i.articleIndex), [0, 1, -1]);
});

test("a video contributes its poster and source; a poster-less, source-less one does not", () => {
  const result = snapshot({
    videos: [
      element({ poster: "https://example.com/p.jpg", currentSrc: "blob:https://example.com/1",
                videoWidth: 1280, videoHeight: 720 }),
      element({ poster: null, src: null, videoWidth: 0, videoHeight: 0 }),
    ],
  });

  assert.equal(result.videos.length, 1);
  assert.equal(result.videos[0].poster, "https://example.com/p.jpg");
  // The blob: src is returned as-is — Swift drops it (`PageHarvest.build`), because
  // deciding what is fetchable is not this file's job.
  assert.equal(result.videos[0].src, "blob:https://example.com/1");
});

// **The rule this file exists for most.** Safari vends the snapshot as a
// `com.apple.property-list`, and a JS `null` becomes `NSNull`, which is not a valid
// property-list value. One null anywhere and Safari cannot produce the representation:
// every load fails with `NSItemProviderErrorDomain -1000` and the share is LOST, because
// a page share carries no URL item to fall back to. It presents as a transport error, it
// is intermittent (a page whose images all have `alt` has no nulls and works), and it cost
// a day of device testing to find. Absent keys are how "no value" is said here.
test("no value anywhere in a snapshot is null, however empty the page", () => {
  const result = snapshot({
    // Everything optional missing or blank: no canonical, a meta with no content, an
    // image with no alt, a video with a poster but no source.
    canonical: null,
    title: "",
    metas: [element({ property: "og:title" })],
    images: [element({ currentSrc: "https://example.com/a.jpg", naturalWidth: 400,
                       naturalHeight: 400, alt: "" })],
    videos: [element({ poster: "https://example.com/p.jpg", currentSrc: "",
                       videoWidth: 640, videoHeight: 360 })],
  });

  const nulls = [];
  (function walk(value, path) {
    if (value === null) return nulls.push(path);
    if (Array.isArray(value)) return value.forEach((v, i) => walk(v, `${path}[${i}]`));
    if (value && typeof value === "object") {
      for (const key of Object.keys(value)) walk(value[key], `${path}.${key}`);
    }
  })(result, "snapshot");

  assert.deepEqual(nulls, [], `null is not plist-representable; found at: ${nulls}`);
});

test("a page that throws still completes, with the URL it managed to read", () => {
  const context = vm.createContext({
    document: {
      location: { href: "https://example.com/hostile" },
      get title() {
        throw new Error("nope");
      },
      querySelectorAll() {
        return [];
      },
      querySelector() {
        return null;
      },
    },
  });
  vm.runInContext(readFileSync(SOURCE, "utf8"), context);

  let produced = null;
  let calls = 0;
  context.ExtensionPreprocessingJS.run({
    completionFunction(value) {
      calls += 1;
      produced = value;
    },
  });

  // Exactly once, whatever happened — a share sheet waiting on a completion that never
  // arrives is the one outcome this file must not produce.
  assert.equal(calls, 1);
  assert.equal(produced.url, "https://example.com/hostile");
});

// ---------------------------------------------------------------------------
// The two readers, over one DOM (096 review 7A)
// ---------------------------------------------------------------------------

// There are TWO in-page DOM readers in this repo doing the same job for two runtimes:
// `harvestSignals()` in `src/harvest.js` (the browser extension, injected by
// `scripting.executeScript`) and `PagePreprocessor.js` (the phone, loaded by Safari as an
// `NSExtensionJavaScriptPreprocessingFile`). They read the same elements and feed
// structurally the same shape — `buildHarvest` in JS, `RawPageSignals` / `PageHarvest.build`
// in Swift.
//
// They differ in five places and EVERY ONE is deliberate and documented:
//
//   1. the phone caps images below `MIN_SIDE` (chrome, avatars, pixels);
//   2. the phone caps the COUNT at `MAX_IMAGES`, because the snapshot crosses XPC;
//   3. the phone must OMIT an absent key where the browser emits `alt: null` — a JS `null`
//      becomes `NSNull`, which is not a valid property-list value, and one of them makes
//      the whole share unloadable (422);
//   4. the browser rasterizes a video frame to a canvas; the phone will not (tainted for
//      cross-origin video, and a data-URL frame is an image's worth of bytes crossing XPC);
//   5. the phone reports `videoWidth`/`videoHeight` as 0 rather than omitting a video.
//
// That is the problem. Every divergence is justified, so nothing looks wrong, and there was
// no mechanism that would notice a SIXTH one arriving by accident. `harvestSignals` is
// deliberately untested ("minimal and hand-checked"); this file tested only the phone's.
//
// So both are run over one document and held to the subset they are supposed to agree on.
// The list above is the allowlist: a difference not on it fails here. Cheap, no runtime
// cost, and it is the same shape of fix as the cross-language rewrite contract in
// `extractors.test.js` — make the agreement mechanical instead of aspirational.

import { harvestSignals } from "../src/harvest.js";

/** The document both readers see. Extracted from `snapshot()` so there is exactly one
 * description of the page and neither reader can be handed a different one.
 *
 * **It answers two spellings of the canonical selector, and that is a finding rather than
 * a convenience.** `PagePreprocessor.js` asks for `link[rel=canonical]`; `harvestSignals`
 * asks for `link[rel="canonical"]`. Both are valid CSS selecting the same element, so no
 * page has ever behaved differently — but they are two spellings of one rule in two files
 * that are supposed to mirror each other, and the first thing this comparison did was trip
 * over it. Left as-is rather than unified: changing a live selector to satisfy a stub is
 * the tail wagging the dog, and the stub can honestly serve both.
 *
 * The returned element answers `.href` (the phone reads the property) and
 * `getAttribute("href")` (the browser reads the attribute) — the same difference again, one
 * layer down. */
function makeDocument({ url = "https://example.com/", title = "A page", canonical = null,
                        metas = [], images = [], videos = [], articles = [] } = {}) {
  const CANONICAL_SELECTORS = ['link[rel=canonical]', 'link[rel="canonical"]'];
  return {
    location: { href: url },
    title,
    querySelector(selector) {
      if (!CANONICAL_SELECTORS.includes(selector) || !canonical) return null;
      return { href: canonical, getAttribute: (name) => (name === "href" ? canonical : null) };
    },
    querySelectorAll(selector) {
      if (selector === "meta[property], meta[name]") return metas;
      if (selector === "img") return images;
      if (selector === "video") return videos;
      if (selector === "article") return articles;
      return [];
    },
  };
}

/** Run the BROWSER's reader against the same stub.
 *
 * It closes over the globals `document` and `location` — it is serialized into a page, so
 * it cannot import anything — which is exactly how Chrome calls it. Both are set for the
 * duration and restored after, so nothing leaks between tests.
 *
 * `location` being a separate global is itself the third spelling difference: the phone
 * reads `document.location.href`, the browser reads bare `location.href`. Same value, two
 * ways, in two files that mirror each other. */
function browserHarvest(description) {
  const previousDocument = globalThis.document;
  const previousLocation = globalThis.location;
  const stub = makeDocument(description);
  globalThis.document = stub;
  globalThis.location = stub.location;
  try {
    return JSON.parse(JSON.stringify(harvestSignals()));
  } finally {
    if (previousDocument === undefined) delete globalThis.document;
    else globalThis.document = previousDocument;
    if (previousLocation === undefined) delete globalThis.location;
    else globalThis.location = previousLocation;
  }
}

/** A page with enough shape to exercise everything both readers claim to do: duplicate
 * metas, images above and below the icon floor, and two articles to be scoped to. */
const SHARED_PAGE = () => {
  const focal = {};
  const reply = {};
  return {
    url: "https://x.com/ada/status/1",
    title: "Ada on X",
    canonical: "https://x.com/ada/status/1",
    metas: [
      element({ property: "og:title", content: "first" }),
      element({ property: "og:title", content: "second" }),
      element({ name: "twitter:description", content: "a description" }),
    ],
    images: [
      img("https://pbs.twimg.com/profile_images/avatar.jpg", 48, 48, focal),
      img("https://pbs.twimg.com/media/HERO.jpg", 1200, 900, focal),
      img("https://pbs.twimg.com/media/REPLY.jpg", 800, 600, reply),
      img("https://example.com/orphan.jpg", 400, 400, null),
    ],
    articles: [focal, reply],
  };
};

test("both readers agree on the page's identity", () => {
  const description = SHARED_PAGE();
  const phone = snapshot(description);
  const browser = browserHarvest(description);

  // Three fields reached three different ways in the two files — `document.location.href`
  // against bare `location.href`, `.href` against `getAttribute("href")`,
  // `link[rel=canonical]` against `link[rel="canonical"]`. They must still arrive equal,
  // because `PageExtractor.liveURL` and the JS extractors both key provenance off them and
  // 18A dedup keys off provenance.
  assert.equal(phone.url, browser.url);
  assert.equal(phone.canonical, browser.canonical);
  assert.equal(phone.title, browser.title);
});

test("both readers agree on the page's metas, in order", () => {
  const description = SHARED_PAGE();
  const phone = snapshot(description);
  const browser = browserHarvest(description);

  // Divergence 3 is invisible here: both emit `key` and `content` as present strings when
  // the attributes are there, which is the ordinary case.
  assert.deepEqual(phone.metas, browser.metas);
  // Duplicates survive on both sides — which one wins is a DECISION, and decisions belong
  // to the pure half in each language, not to the DOM read.
  assert.equal(phone.metas.length, 3);
});

test("both readers agree on which article each image belongs to", () => {
  const description = SHARED_PAGE();
  const phone = snapshot(description);
  const browser = browserHarvest(description);

  // This is the one that matters most and is hardest to notice breaking: the X extractor
  // scopes media to the FOCAL article, so an index that disagrees between the two producers
  // means the phone captures a reply's photo where the browser captures the tweet's.
  const browserIndexBySrc = new Map(browser.images.map((i) => [i.src, i.articleIndex]));
  for (const image of phone.images) {
    assert.equal(
      image.articleIndex, browserIndexBySrc.get(image.src),
      `article index disagrees for ${image.src}`);
  }
  assert.deepEqual(
    phone.images.map((i) => i.articleIndex).sort(), [-1, 0, 1],
    "the fixture exercised a focal, a reply and an orphan");
});

test("the phone's images are the browser's, minus exactly the documented caps", () => {
  const description = SHARED_PAGE();
  const phone = snapshot(description);
  const browser = browserHarvest(description);

  // Divergences 1 and 2, stated as an equation rather than as prose. Anything the phone
  // drops that this filter does not explain is a sixth divergence, and it fails here.
  const MIN_SIDE = 100;
  const MAX_IMAGES = 80;
  const expected = browser.images
    .filter((i) => i.src && i.width >= MIN_SIDE && i.height >= MIN_SIDE)
    .slice(0, MAX_IMAGES);

  assert.deepEqual(phone.images.map((i) => i.src), expected.map((i) => i.src));
  // And the dimensions travel identically for the ones that survive — the filter is the
  // whole difference, not a different reading of the same element.
  for (const [index, image] of phone.images.entries()) {
    assert.equal(image.width, expected[index].width);
    assert.equal(image.height, expected[index].height);
  }
});

test("the null discipline is the phone's alone, and it is a real difference", () => {
  const description = SHARED_PAGE();
  const phone = snapshot(description);
  const browser = browserHarvest(description);

  // Divergence 3, pinned so it cannot quietly reverse. Every image in the fixture has
  // `alt: null`; the browser SAYS so and the phone must not, because one `NSNull` makes the
  // entire share unloadable (422). A future edit that "tidies" the preprocessor by emitting
  // nulls fails right here, with the reason attached.
  for (const image of browser.images) {
    assert.ok("alt" in image, "the browser emits alt even when it is null");
  }
  for (const image of phone.images) {
    assert.ok(
      !("alt" in image),
      "the phone must OMIT an absent alt — a JS null becomes NSNull, which no property "
      + "list can carry, and the share fails to load entirely (422)");
  }
});
