// Atelier Capture — generic page-signal harvester.
//
// This is the ONLY code that runs in the page's context (injected via
// chrome.scripting.executeScript on a user gesture). It is deliberately
// site-AGNOSTIC: it serializes the stable, cross-site signals (meta tags,
// canonical link, title, url) AND the real media elements actually in the DOM.
//
// Why the DOM media matters: Twitter/X, Pinterest, Instagram and Cosmos are
// client-rendered SPAs whose <meta og:image> and <link canonical> are frequently
// STALE (left over from the first page load) or GENERIC (a site logo / share
// card), not the post you're looking at. The real media is in the rendered DOM
// (pbs.twimg.com/media/…, i.pinimg.com/…). So we harvest the actual <img>/<video>
// elements and let the pure extractors pick; og:image is only a last resort.
//
// Must be self-contained (no imports / no closure over the SW) so it survives
// serialization into the page.

export function harvestSignals() {
  const metas = {};
  for (const el of document.querySelectorAll("meta[property], meta[name]")) {
    const key = el.getAttribute("property") || el.getAttribute("name");
    const content = el.getAttribute("content");
    if (key && content && !(key in metas)) metas[key] = content;
  }

  const media = [];
  for (const img of document.querySelectorAll("img")) {
    const src = img.currentSrc || img.src;
    if (!src || src.startsWith("data:")) continue;
    media.push({
      kind: "image",
      src,
      width: img.naturalWidth || img.width || 0,
      height: img.naturalHeight || img.height || 0,
      alt: img.alt || null,
    });
  }
  for (const video of document.querySelectorAll("video")) {
    if (video.poster && !video.poster.startsWith("data:")) {
      media.push({
        kind: "video-poster",
        src: video.poster,
        width: video.videoWidth || 0,
        height: video.videoHeight || 0,
        alt: null,
      });
    }
  }

  const canonicalEl = document.querySelector('link[rel="canonical"]');
  return {
    url: location.href,
    title: document.title || null,
    canonical: canonicalEl ? canonicalEl.getAttribute("href") : null,
    metas,
    media,
  };
}
