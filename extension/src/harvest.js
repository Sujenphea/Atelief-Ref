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
    // A video tweet has no still image on the server — Twitter only exposes the
    // poster (a keyframe it chose). To capture the frame the user is actually
    // looking at, draw the video's CURRENT frame to a canvas and read it as a
    // data-URL. Only possible when a frame is decoded (readyState >=
    // HAVE_CURRENT_DATA) and the pixels aren't cross-origin-tainted; on either
    // failure we skip it and the poster below is used instead.
    if (video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0) {
      try {
        const canvas = document.createElement("canvas");
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        canvas.getContext("2d").drawImage(video, 0, 0);
        media.push({
          kind: "video-frame",
          src: canvas.toDataURL("image/png"), // throws SecurityError if tainted
          width: video.videoWidth,
          height: video.videoHeight,
          alt: null,
        });
      } catch {
        // Tainted or unavailable — fall through to the poster.
      }
    }
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
