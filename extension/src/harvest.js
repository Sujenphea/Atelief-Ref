// Atelier Capture — generic page-signal harvester.
//
// This is the ONLY code that runs in the page's context (injected via
// chrome.scripting.executeScript on a user gesture). It is deliberately
// site-AGNOSTIC: it serializes the stable, cross-site signals (meta tags,
// canonical link, title, url) into a plain object. All per-site interpretation
// happens off-page in the pure extractors, so the fragile part is unit-testable
// without a DOM.
//
// Must be self-contained (no imports / no closure over the SW) so it survives
// serialization into the page.

export function harvestSignals() {
  const metas = {};
  for (const el of document.querySelectorAll("meta[property], meta[name]")) {
    const key = el.getAttribute("property") || el.getAttribute("name");
    const content = el.getAttribute("content");
    // First occurrence wins (og:* tags are usually first and canonical).
    if (key && content && !(key in metas)) metas[key] = content;
  }
  const canonicalEl = document.querySelector('link[rel="canonical"]');
  return {
    url: location.href,
    title: document.title || null,
    canonical: canonicalEl ? canonicalEl.getAttribute("href") : null,
    metas,
  };
}
