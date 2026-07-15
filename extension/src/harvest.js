// Atelier Capture — page-signal harvester, split into an in-page reader and a
// pure shaper.
//
// `harvestSignals()` runs in the PAGE (injected via chrome.scripting.executeScript
// on a user gesture) and MUST be self-contained — no imports, no closure over the
// SW — because it is serialized into the page. So it does only what needs the live
// DOM: enumerate <meta>/<img>/<video> and rasterize the FIRST eligible video frame
// to a data-URL (canvas is DOM-only). It returns a RAW snapshot of plain values.
//
// `buildHarvest(raw)` is a pure module function (imported by the SW, unit-tested):
// it classifies that raw snapshot into the { url, title, canonical, metas, media }
// object the extractors consume — the meta-dedup, media `kind` tagging and skip
// rules that used to be tangled into the page code. Splitting here keeps the
// DOM/canvas part minimal + manual, while the breakable classification is tested
// with plain objects (no jsdom, zero deps).
//
// Why the DOM media matters: Twitter/X, Pinterest, Instagram and Cosmos are
// client-rendered SPAs whose <meta og:image> / <link canonical> are frequently
// STALE or GENERIC. The real media is in the rendered DOM, so we harvest the
// actual <img>/<video> elements and let the pure extractors pick; og:image is a
// last resort.

/**
 * Runs in the page. Returns a raw snapshot — deduped later — of the signals the
 * extractors need: meta pairs, raw <img>/<video> reads, and the first eligible
 * video's frame data-URL. Does NO classification (that's `buildHarvest`), so it
 * stays a thin, self-contained DOM reader.
 */
export function harvestSignals() {
  const metas = [];
  for (const el of document.querySelectorAll("meta[property], meta[name]")) {
    metas.push({
      key: el.getAttribute("property") || el.getAttribute("name"),
      content: el.getAttribute("content"),
    });
  }

  // The index of an element's containing <article>, or -1. On a tweet STATUS page
  // the focal tweet is the first <article> and replies follow, so this lets the X
  // extractor scope media to the focal tweet instead of borrowing a reply's image.
  const articles = Array.from(document.querySelectorAll("article"));
  const articleIndexOf = (el) => {
    const article = el.closest("article");
    return article ? articles.indexOf(article) : -1;
  };

  const images = [];
  for (const img of document.querySelectorAll("img")) {
    images.push({
      src: img.currentSrc || img.src || "",
      width: img.naturalWidth || img.width || 0,
      height: img.naturalHeight || img.height || 0,
      alt: img.alt || null,
      articleIndex: articleIndexOf(img),
    });
  }

  const videos = [];
  let framedOne = false; // 14A: rasterize ONLY the first eligible video, not all.
  for (const video of document.querySelectorAll("video")) {
    // A video tweet has no still on the server — only a poster. To capture the
    // frame the user is actually looking at, draw the video's CURRENT frame to a
    // canvas. Possible only when a frame is decoded (readyState >= HAVE_CURRENT_DATA)
    // and the pixels aren't cross-origin-tainted; on either failure we skip it and
    // the poster is used instead. Only the FIRST such video is rasterized — the
    // extractors use just one frame, and a busy feed can hold several videos.
    let frame = null;
    if (!framedOne && video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0) {
      try {
        const canvas = document.createElement("canvas");
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        canvas.getContext("2d").drawImage(video, 0, 0);
        // JPEG, not PNG: far smaller for a photographic frame (less CPU to encode,
        // less to serialize back), and it's a still either way. Throws
        // SecurityError if the pixels are cross-origin-tainted.
        frame = canvas.toDataURL("image/jpeg", 0.9);
        framedOne = true;
      } catch {
        frame = null; // tainted or unavailable — fall through to the poster
      }
    }
    videos.push({
      frame,
      poster: video.poster || null,
      src: video.currentSrc || video.getAttribute("src") || "",
      width: video.videoWidth || 0,
      height: video.videoHeight || 0,
      articleIndex: articleIndexOf(video),
    });
  }

  const canonicalEl = document.querySelector('link[rel="canonical"]');
  return {
    url: location.href,
    title: document.title || null,
    canonical: canonicalEl ? canonicalEl.getAttribute("href") : null,
    metas,
    images,
    videos,
  };
}

/**
 * Pure: classify a raw snapshot (from `harvestSignals`) into the harvest object
 * the extractors consume: `{ url, title, canonical, metas, media }`. Metas dedup
 * first-wins; media are tagged by `kind` in a stable order (images in DOM order,
 * then per video: frame, poster, src) with data:/blob: sources skipped.
 */
export function buildHarvest(raw) {
  const metas = {};
  for (const { key, content } of raw.metas || []) {
    if (key && content && !(key in metas)) metas[key] = content;
  }

  const media = [];
  // Carry `articleIndex` through when the reader provided it (the X extractor uses it
  // to scope to the focal tweet); absent in older fixtures, so it's added only when set.
  const withArticle = (item, source) => {
    if (source.articleIndex != null) item.articleIndex = source.articleIndex;
    return item;
  };
  for (const img of raw.images || []) {
    if (!img.src || img.src.startsWith("data:")) continue;
    media.push(withArticle({
      kind: "image",
      src: img.src,
      width: img.width || 0,
      height: img.height || 0,
      alt: img.alt || null,
    }, img));
  }
  for (const video of raw.videos || []) {
    if (video.frame) {
      media.push(withArticle({
        kind: "video-frame", src: video.frame,
        width: video.width || 0, height: video.height || 0, alt: null,
      }, video));
    }
    if (video.poster && !video.poster.startsWith("data:")) {
      media.push(withArticle({
        kind: "video-poster", src: video.poster,
        width: video.width || 0, height: video.height || 0, alt: null,
      }, video));
    }
    // A real (non-blob/data) video src is a strong "this is a video" signal even
    // when it's an HLS manifest we can't ingest directly — it tells the SW to
    // resolve the downloadable MP4 (e.g. a Pinterest video pin).
    if (video.src && !video.src.startsWith("blob:") && !video.src.startsWith("data:")) {
      media.push(withArticle({
        kind: "video-src", src: video.src,
        width: video.width || 0, height: video.height || 0, alt: null,
      }, video));
    }
  }

  return {
    url: raw.url,
    title: raw.title || null,
    canonical: raw.canonical || null,
    metas,
    media,
  };
}
