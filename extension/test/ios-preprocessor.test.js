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
