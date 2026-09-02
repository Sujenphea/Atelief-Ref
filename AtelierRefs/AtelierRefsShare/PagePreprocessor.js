// AtelierRefsShare — the script Safari runs inside a shared page (092 · S4b, tier 2).
//
// `NSExtensionJavaScriptPreprocessingFile` names this file; Safari loads it into the page
// the user shared, calls `run`, and hands whatever is passed to `completionFunction` to
// the extension as a dictionary. That is the ONLY way a share sheet can see a page's DOM,
// and it is what makes the phone the equal of the browser extension on the sites that
// matter: x.com, instagram.com and pinterest.com are auth-walled
// (`PageResolver.isAuthWalledHost`), so a cookie-less fetch from the Mac sees a login
// wall — while Safari here is already signed in and the rendered DOM holds the real image.
//
// **This file decides nothing, and that is the design.** It reads the DOM and returns a
// RAW snapshot of plain values. Which meta wins, which image is the post's, what the media
// URL is, which platform this is — all of it happens in Swift, in `AtelierCapture`
// (`PageHarvest` / `PageExtractor`), where `swift test` can reach it without a device, a
// page or Safari. The same split `extension/src/harvest.js` makes between `harvestSignals`
// (runs in the page, minimal, hand-checked) and `buildHarvest` (pure, unit-tested).
//
// So the rule for changing this file: if you find yourself writing an `if` about a
// hostname here, it belongs in `PageExtractor.swift`.
//
// **The caps, and what they cost.** The snapshot crosses an XPC boundary into a process
// with an observed ~120 MB ceiling, so it stays small, and every axis along which a page
// could make it big is bounded:
//
//   · images below MIN_SIDE are skipped (icons, tracking pixels, avatars — nothing any
//     extractor would pick), and no more than MAX_IMAGES are returned, in DOM order;
//   · no more than MAX_VIDEOS and MAX_METAS, for the same reason and by the same rule;
//   · no harvested string may exceed MAX_TEXT, which is what actually bounds the SIZE —
//     the counts bound how many strings, and this bounds how big one can be;
//   · a `data:` src is dropped here rather than only in Swift, because a `data:` URL is
//     not a reference to bytes, it IS the bytes: a page with eighty inline base64 images
//     shipped megabytes of them across XPC to be discarded on the far side;
//   · no more than MAX_SCAN elements are examined per collection, so a DOM claiming a
//     million `<img>` cannot make a share sheet spin.
//
// DOM order is load-bearing rather than incidental: the X extractor takes the FIRST media
// in the focal article, so re-sorting here would break scoping in Swift. The cost of the
// count caps is that on a very long feed a late image can fall off the end — acceptable,
// because tier 2 is for sharing a POST page, where the media is near the top and few.
//
// **The caps also bound a HOSTILE page, and that is the half worth stating.** Safari runs
// this file in the page's own JavaScript world: `document`, `Element.prototype.closest` and
// `getAttribute` are the page's, and a page that wants to can replace all three. Nothing
// here can prevent that — there is no isolated world to retreat to, and taking references
// early would only capture whatever the page had already installed. What the caps DO close
// is the consequence that costs something: a lying DOM can make the snapshot WRONG (a
// borrowed article index, a fake `naturalWidth`), which loses one capture, but it can no
// longer make the snapshot UNBOUNDED, which loses the process. That distinction is the
// deliberate line, and the veracity half is not closed.
//
// **Never emit `null` — omit the key.** This is not style, it is the boundary's own rule,
// and it cost a day to find. Safari vends this script's return value as a
// `com.apple.property-list` attachment, and a JS `null` becomes `NSNull`, which is not a
// valid property-list value. One null anywhere in the snapshot and Safari cannot produce
// the representation at all: every `loadItem` and `loadDataRepresentation` fails with
// `NSItemProviderErrorDomain -1000` ("Cannot load representation of type
// com.apple.property-list") over an `NSCocoaErrorDomain 4101`, and the share is LOST —
// because a page share carries no URL item to fall back to. It reads as a transport
// failure and is nothing of the kind.
//
// It also fails INTERMITTENTLY, which is what made it expensive: a page whose images all
// carry `alt` text and which has a canonical link produces no nulls and works, while the
// next page over has one image without `alt` and cannot be shared at all.
//
// Every field of `RawPageSignals` is optional, so an absent key decodes to `nil` — which
// is the same "one kind of absent" `text()` was written for, expressed in the one way this
// boundary accepts. `put` is the only way a value should reach a snapshot object.
//
// **No canvas.** The browser extension rasterizes a video's current frame, because a video
// post has no still on the server. Not here: a share sheet is already on screen and
// waiting, `canvas` is tainted for cross-origin video (so it fails on exactly these
// sites), and a data-URL of a decoded frame is an image's worth of bytes crossing XPC —
// which is the memory rule 091 · D2 spends this whole extension avoiding. The poster is
// harvested instead, so a video post still yields a picture.

var ExtensionPreprocessingJS = new (function PagePreprocessor() {
  /** Below this on either side, an image is chrome: an icon, an avatar, a pixel. */
  var MIN_SIDE = 100;
  /** Enough for any post page; a bound rather than a judgement. */
  var MAX_IMAGES = 80;
  /** A post page has one video, or two. Twenty is a bound, not a judgement either. */
  var MAX_VIDEOS = 20;
  /** A generous page declares thirty `<meta>`; a hundred is well past every real one. */
  var MAX_METAS = 100;
  /** The longest harvested string. A signed CDN URL runs to ~1500 characters and an
   * `og:description` to a few hundred, so this clears both with room; what it does not
   * clear is an inline base64 image, which is the point. */
  var MAX_TEXT = 2048;
  /** How many elements one `querySelectorAll` result is examined for. A page with more
   * `<img>` than this is not a post page, and iterating it is a share sheet that hangs. */
  var MAX_SCAN = 2000;
  /** The one field with no cap: `document.location.href`.
   *
   * Every other over-long value is DROPPED, and dropping this one would lose the whole
   * capture rather than shorten it — `PageHarvest.harvest(fromResults:)` returns nil for a
   * snapshot with no URL, and `SupportsWebPage` means there is no URL item to fall back to
   * (`Info.plist:49-53`). It is also one string rather than a repeated one, and the browser
   * bounds what its own address bar will hold, so it is not the axis that can go big. */
  var MAX_URL = Infinity;

  /** A `data:` src is the image's bytes rather than a reference to them. */
  var DATA_URL = /^data:/i;

  /** A string within `limit`, or null — never "" and never undefined. Null never reaches
   * the snapshot: `put` drops it, and the key is simply absent. See the header.
   *
   * **The length is checked BEFORE the trim**, deliberately: `trim()` on a five-megabyte
   * base64 string copies five megabytes to decide it is too long. The cost is that a value
   * padded past the limit with whitespace is dropped rather than trimmed into range, which
   * is not a page anyone has. */
  function text(value, limit) {
    if (typeof value !== "string") return null;
    if (value.length > limit) return null;
    var trimmed = value.trim();
    return trimmed === "" ? null : trimmed;
  }

  /** A media src worth carrying: a string within MAX_TEXT that is not an inline `data:`
   * URL. Swift drops `data:` as well (`PageHarvest.usable`) and both are wanted — Swift's
   * is the tested rule for the shape it decodes, and this one is what keeps the bytes from
   * crossing XPC in the first place, which is the cost this file exists to avoid. */
  function src(value) {
    var out = text(value, MAX_TEXT);
    return out !== null && DATA_URL.test(out) ? null : out;
  }

  /** Assign only what exists. The one way a value reaches a snapshot object — a `null`
   * that gets through is a share that cannot be loaded at all (see the header). */
  function put(target, key, value) {
    if (value !== null && value !== undefined) target[key] = value;
    return target;
  }

  /** Every `<meta property|name>` pair, in document order. Duplicates are kept: which
   * one wins is a decision, and decisions are Swift's (`PageHarvest.build`). */
  function metas() {
    var out = [];
    var nodes = document.querySelectorAll("meta[property], meta[name]");
    for (var i = 0; i < nodes.length && out.length < MAX_METAS; i += 1) {
      var meta = {};
      put(meta, "key",
        text(nodes[i].getAttribute("property") || nodes[i].getAttribute("name"), MAX_TEXT));
      put(meta, "content", text(nodes[i].getAttribute("content"), MAX_TEXT));
      out.push(meta);
    }
    return out;
  }

  /** The index of an element's containing `<article>`, or -1.
   *
   * This is what lets the X extractor scope media to the FOCAL tweet: on a status page
   * the tweet is the first `<article>` and every reply follows it, so without this a
   * text-only tweet would borrow a reply's photo. */
  function articleIndexer() {
    var articles = document.querySelectorAll("article");
    return function (element) {
      var article = element.closest ? element.closest("article") : null;
      if (!article) return -1;
      for (var i = 0; i < articles.length; i += 1) {
        if (articles[i] === article) return i;
      }
      return -1;
    };
  }

  /** Rendered `<img>` elements worth reporting. `currentSrc` first: on a responsive
   * image it is the source the browser ACTUALLY chose, which is the one that loaded. */
  function images(indexOf) {
    var out = [];
    var nodes = document.querySelectorAll("img");
    for (var i = 0; i < nodes.length && i < MAX_SCAN && out.length < MAX_IMAGES; i += 1) {
      var img = nodes[i];
      var source = src(img.currentSrc || img.src);
      if (!source) continue;
      var width = img.naturalWidth || img.width || 0;
      var height = img.naturalHeight || img.height || 0;
      if (width < MIN_SIDE || height < MIN_SIDE) continue;
      out.push(
        put(
          { src: source, width: width, height: height, articleIndex: indexOf(img) },
          "alt", text(img.alt, MAX_TEXT)));
    }
    return out;
  }

  /** `<video>` posters and real sources. No frame grab — see the header. */
  function videos(indexOf) {
    var out = [];
    var nodes = document.querySelectorAll("video");
    for (var i = 0; i < nodes.length && i < MAX_SCAN && out.length < MAX_VIDEOS; i += 1) {
      var video = nodes[i];
      var poster = src(video.poster);
      var source = src(video.currentSrc || video.src);
      if (!poster && !source) continue;
      var entry = {
        width: video.videoWidth || 0,
        height: video.videoHeight || 0,
        articleIndex: indexOf(video),
      };
      put(entry, "poster", poster);
      put(entry, "src", source);
      out.push(entry);
    }
    return out;
  }

  function canonical() {
    var link = document.querySelector("link[rel=canonical]");
    return link ? text(link.href, MAX_TEXT) : null;
  }

  this.run = function (parameters) {
    var indexOf = articleIndexer();
    // Wrapped because a page that throws from a getter (an over-eager framework, an
    // extension of its own) must not leave the share sheet waiting: the completion
    // function has to be called exactly once, whatever happens. A snapshot with only a
    // URL still classifies — `PageExtractor` falls back to the URL's platform — and one
    // with nothing at all is refused in Swift and becomes a tier-1 link.
    var snapshot;
    try {
      snapshot = { metas: metas(), images: images(indexOf), videos: videos(indexOf) };
      put(snapshot, "url", text(document.location.href, MAX_URL));
      put(snapshot, "title", text(document.title, MAX_TEXT));
      put(snapshot, "canonical", canonical());
    } catch (error) {
      // `String(error)` is a page-controlled string on a page that threw, so it is capped
      // like every other one: a getter that throws a megabyte must not become the payload
      // the snapshot could not otherwise be.
      snapshot = {};
      put(snapshot, "error", text(String(error), MAX_TEXT));
      put(snapshot, "url", text(document.location.href, MAX_URL));
    }
    parameters.completionFunction(snapshot);
  };

  // No `finalize`. It runs when the extension completes its request WITH items, and this
  // one completes with none (`ShareViewController.complete()`): the capture is already
  // durable in the inbox by then, and a share sheet has nothing to hand back to the page.
})();
