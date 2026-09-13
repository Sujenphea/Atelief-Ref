// Atelier Capture — the capture DECISION, separated from the transport (096 § D7, T2.5).
//
// `captureCore` / `ingestOne` in `sw.js` hold two things fused together. One is a set of
// decisions any producer needs: is this a video or a still, which URL is tried first and
// which is the fallback, is this a text-only post that captures as a card. The other is
// how the desktop ships it — base64 the bytes (`sw.js:99`), POST to `127.0.0.1`
// (`sw.js:160`), carry the shared-secret token.
//
// Tier 3 needs the first and must not inherit the second: 095 § 5 measured the handler
// killed at 32 MB when bytes travel through a native message, so the phone hands over a
// URL and the native side fetches it. Ported as-is, that fork would put "which URL wins,
// is this a text card, is there a video" in two places — the duplication
// [404](../../.change-log/404-the-mirror-nobody-checked.md) is the changelog of.
//
// So the decision lives here, pure: provenance in, a plan out. No browser API, no fetch,
// no bytes. `sw.js` consumes it and adds the localhost transport; the Safari worker will
// consume the same plan and hand it to the native handler.
//
// **The plan does NOT carry the request body**, which is a deviation from the sketch in
// 096 § D7 and deliberate: a `CaptureRequest` carries base64 image bytes, so building one
// here would drag the very thing tier 3 must avoid back into the shared half. Request
// construction stays in `endpoint.js`, called by whichever transport needs it.

/** What a plan resolves to. `none` is the "nothing to capture" case the caller reports. */
export const CAPTURE_KIND = {
  video: "video",
  content: "content",
  image: "image",
  none: "none",
};

/**
 * The capture decision for one post.
 *
 * @param provenance  The extractor's output (`mediaUrl`, `mediaUrlFallback`, `platform`, …).
 * @param mp4Url      A resolved video URL, or null. RESOLUTION is the caller's job — it
 *                    needs the network and the platform APIs; choosing what to do with the
 *                    result is this function's.
 * @param videoCandidates  Further video URLs to try, in order, when the one before it is
 *                    refused (098 D5). Three of the four platforms resolve exactly ONE url
 *                    and pass nothing here, so their plan carries a one-element list and a
 *                    caller that walks it does exactly what a caller that tried `videoUrl`
 *                    did. rednote passes a whole ladder: `master_url` then its
 *                    `backup_urls[]`, rung after rung, already ordered by
 *                    `rednote-video.js`'s `videoCandidates`. The list is ORDERING, not
 *                    preference — this function never re-sorts it.
 * @param content     A content descriptor (`tweetContent`'s output), or null.
 * @param isAllowedHost  Optional `(platform, url) => boolean` media-host guard. **Null means
 *                    no enforcement**, which is the desktop's behaviour today and is kept as
 *                    the default deliberately: `media-hosts.js`'s `ALLOWED` is deny-by-default
 *                    and names only the four platforms a bulk sweep touches, so enforcing it
 *                    unconditionally would refuse every `cosmos` and `web` capture. Tier 3
 *                    passes `isAllowedMediaHost` because it only ever runs on the three
 *                    platforms that table covers (096 § D6).
 *
 * @returns `{ kind, videoUrl, videoCandidates, urlCandidates, content, blocked, reason }`
 *   · `urlCandidates` is ordered — full-res first, rendered fallback second — and is what a
 *     fetcher walks. `sw.js` hands it to `fetchImage`; the native side walks the same list.
 *   · `videoCandidates` is the same idea one media kind up: ordered, deduped, and ALWAYS an
 *     array. `videoUrl` is its head, kept as its own field because both transports already
 *     read it by that name and because "the one we are trying" and "the ones we may fall
 *     back to" are genuinely different questions. On a `none`/`image`/`content` plan it is
 *     empty, and on every video plan `videoUrl === videoCandidates[0]`.
 *   · `blocked` is the candidates the guard refused, kept rather than dropped so a refusal
 *     is diagnosable instead of looking like a post with no media.
 *   · `reason` is set only when `kind` is `none`, and distinguishes "there was nothing" from
 *     "there was something and the guard refused it".
 */
export function planCapture(
  provenance,
  { mp4Url = null, content = null, isAllowedHost = null, videoCandidates = [] } = {}
) {
  const proposed = [provenance.mediaUrl, provenance.mediaUrlFallback].filter(Boolean);
  const urlCandidates = [];
  const blocked = [];
  for (const url of proposed) {
    if (!isAllowedHost || isAllowedHost(provenance.platform, url)) urlCandidates.push(url);
    else blocked.push(url);
  }

  // `mp4Url` leads, because a caller that resolved ONE url said which one it wanted tried
  // first, and because that is exactly what the three existing platforms do. Deduped so a
  // ladder repeating its head cannot buy the rung-advance a second try against a url that
  // just failed — the same rule `rednote-video.js` applies inside a rung.
  //
  // The host guard is deliberately NOT applied here. It never was for `mp4Url`: video URLs
  // are screened by `bulk-sw.js`'s relay guard, one gate for the whole item, and moving
  // that gate into this function would change what a tier-3 caller (which DOES pass
  // `isAllowedHost`) gets back. Additive means additive.
  const videoUrls = [...new Set(
    [mp4Url, ...(Array.isArray(videoCandidates) ? videoCandidates : [])]
      .filter((url) => typeof url === "string" && url.length > 0),
  )];

  // A resolved video wins, but the still candidates travel WITH it: the desktop falls back
  // to the image when a resolved video fails to download (`sw.js:232`, fail-open), and the
  // plan has to carry what that fallback would be or the caller has to re-derive it.
  if (videoUrls.length) {
    return {
      kind: CAPTURE_KIND.video, videoUrl: videoUrls[0], videoCandidates: videoUrls,
      urlCandidates, content, blocked, reason: null,
    };
  }
  if (urlCandidates.length) {
    return {
      kind: content ? CAPTURE_KIND.content : CAPTURE_KIND.image,
      videoUrl: null, videoCandidates: [], urlCandidates, content, blocked, reason: null,
    };
  }
  // No usable media. A post with real substance still captures as a text card — the
  // media-less content path (003 · C3) — and only a post with neither is nothing.
  if (content) {
    return {
      kind: CAPTURE_KIND.content, videoUrl: null, videoCandidates: [], urlCandidates: [],
      content, blocked, reason: null,
    };
  }
  return {
    kind: CAPTURE_KIND.none, videoUrl: null, videoCandidates: [], urlCandidates: [],
    content: null, blocked, reason: blocked.length ? "blocked-host" : "no-media",
  };
}

/** True when a plan is the media-less text-card case: substance, but nothing to fetch.
 * Named because both transports branch on it and `kind === "content" && !urlCandidates.length`
 * is the kind of condition that gets subtly mis-copied the second time it is written. */
export function isTextCard(plan) {
  return plan.kind === CAPTURE_KIND.content && plan.urlCandidates.length === 0;
}
