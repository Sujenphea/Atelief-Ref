// Atelier Capture — resolve a Pinterest video pin to a downloadable MP4.
//
// A Pinterest video pin renders a <video> whose src is an HLS `.m3u8` (not
// ingestable), and the progressive MP4 variants live only in the pin page's
// server-rendered HTML as `"videoUrls":[ … ]` — NOT in the live SPA DOM. So,
// like Twitter's syndication path, we fetch the pin by id and parse that array.
// (Pinterest's PinResource JSON API is 403 without a CSRF token, so the HTML is
// the reliable public source.)
//
// Selection is pure (tested against a real payload); the fetch is a thin wrapper.

const PIN_BASE = "https://www.pinterest.com/pin";

/** Every video URL on the pin's video CDN, embedded in the pin page's server HTML.
 *
 * A regular video pin exposes a `"videoUrls":[…]` array; a STORY / IDEA pin nests
 * the same MP4/HLS URLs under `storyPinData` instead. Rather than depend on one
 * JSON shape, pull every `v*.pinimg.com/videos/…` URL directly (deduped). The SEO
 * HTML for a pin contains only that pin's own video(s) — related/feed content is
 * loaded client-side — so this doesn't grab unrelated media. */
export function extractVideoUrls(html) {
  const urls = html.match(
    /https:\/\/v\d*\.pinimg\.com\/videos\/[^"\\\s]+?\.(?:mp4|m3u8|mpd)/g
  );
  return urls ? [...new Set(urls)] : [];
}

/** The best downloadable MP4 from a `videoUrls` list, or null. Prefers H.264
 * (`/expMp4/`, universally decodable) over HEVC (`hevcMp4V3` / `h265-pt-mp4`),
 * then the largest width (`_<N>w` in the filename). HLS/DASH are skipped. */
export function selectBestVideo(videoUrls) {
  const mp4s = (videoUrls || []).filter(
    (u) => typeof u === "string" && u.endsWith(".mp4")
  );
  if (!mp4s.length) return null;
  const width = (u) => {
    const m = u.match(/_(\d+)w/);
    return m ? Number(m[1]) : 0;
  };
  const isH264 = (u) => /\/expMp4\//.test(u);
  mp4s.sort(
    (a, b) => Number(isH264(b)) - Number(isH264(a)) || width(b) - width(a)
  );
  return mp4s[0];
}

/** Whether the SW should try to resolve a Pinterest video for this capture. Unlike
 * Twitter (where syndication is cheap), fetching the pin page is ~1 MB, so gate on
 * a real video signal from the harvested page: a `<video>` (its poster / decoded
 * frame / non-blob src) — captured by `harvestSignals`. An image pin has none, so
 * it never triggers the fetch. */
export function shouldResolveVideo(provenance, harvest) {
  if (provenance.platform !== "pinterest") return false;
  if (!provenance.rawMetadata || !provenance.rawMetadata.pinId) return false;
  const media = (harvest && harvest.media) || [];
  return media.some(
    (m) => m.kind === "video-poster" || m.kind === "video-frame" || m.kind === "video-src"
  );
}

/** Resolve a pin id to a downloadable MP4 URL by fetching the pin page and parsing
 * its `videoUrls`. Throws if the request fails or the pin has no MP4 variant.
 *
 * IMPORTANT: `credentials: "omit"` is required. A LOGGED-IN Pinterest request gets
 * a client-rendered shell WITHOUT `videoUrls` (verified); only the logged-OUT SEO
 * HTML carries them. The SW's cross-origin fetch is cookie-less by default, but we
 * force it so a stray cookie can never flip us to the empty shell. */
export async function resolvePinterestVideo(pinId, { fetchImpl = fetch } = {}) {
  const response = await fetchImpl(`${PIN_BASE}/${encodeURIComponent(pinId)}/`, {
    credentials: "omit",
    headers: { Accept: "text/html" },
  });
  if (!response.ok) throw new Error(`pinterest HTTP ${response.status}`);
  const url = selectBestVideo(extractVideoUrls(await response.text()));
  if (!url) throw new Error("no MP4 variant on the pin");
  return url;
}
