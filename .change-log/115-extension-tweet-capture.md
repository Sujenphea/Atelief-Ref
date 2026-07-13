# 115 — Extension tweet content capture (003 · C3 · Option 3)

The browser PRODUCER for tweet content items. A single-item X capture now POSTs
a `tweet` (kind + payload) carrying the SAME card-image bytes it already fetched,
so the tweet lands as a first-class item with its picture (via 114's hybrid
`contentWithImage` path) instead of a bare image. The Swift boundary shipped in
114; this is the JS + node-test follow-on.

## What ships

- **`endpoint.js`** — `buildContentCaptureRequest(provenance, imageBase64,
  {kind, payload}, {jobId, sourceId})` mirrors Swift's `CaptureRequest` with
  `kind` + `payload` set ALONGSIDE the base64 image. `tweetContent(provenance)`
  maps a twitter provenance to `{ kind: "tweet", payload: { tweet } }`, or `null`
  when it isn't a usable tweet (no tweet id, or neither text nor media) → the
  caller falls back to the plain image body. `media` is ALWAYS an array (Swift's
  `TweetPayload.media` is non-optional).
- **`sw.js`** — `captureCore` computes `tweetContent(provenance)` and hands it to
  the shared `ingestOne` tail, which POSTs a content capture when a descriptor is
  present and the plain image body otherwise. A video tweet still ingests as a
  video (the content descriptor is only used on the image path). The bulk X sweep
  is UNCHANGED — it never sets a descriptor, so it stays on the image path for
  now (single-capture scope; bulk tweets are a later step).

## Scope (the two C3-extension decisions)

- **Q1 — Option 3** (tweet item carrying its card image), per 114: a real
  thumbnail now, one asset, dedup by tweet-id.
- **Q2 — single capture only.** Single X → tweet; bulk X stays on the image path.
  Web → link is intentionally NOT switched here: a link's thumbnail is its
  og:image, which needs C2b — converting web captures to text-card links now
  would REGRESS their thumbnails, contradicting the visual-quality reason Option
  3 was chosen. Web stays on the image path until C2b gives links a real card.

## Files changed

- `src/endpoint.js` (`buildContentCaptureRequest`, `tweetContent`).
- `src/sw.js` (import + deps; `captureCore` computes the descriptor; `ingestOne`
  posts a content vs image body; `saved` result reports `kind: "tweet"`).
- `test/endpoint.test.js` (content contract + `tweetContent` null/array matrix),
  `test/sw.test.js` (content-vs-image routing, tweet still-image vs video),
  `test/fixtures/capture-contract.json` — the JS now asserts it PRODUCES the
  `contentCaptureRequest` shape 114's Swift decoder asserts it DECODES.

## Tests

Extension **280** green (`node --test`, +8). No Swift change.

## Remaining (003)

- **Bulk X sweep → tweets** — the big payoff; deferred (single-capture scope).
- **C2b — link resolver enrichment** (= 001 `PageResolver`, SSRF-hardened) — the
  security-sensitive piece; still deferred. Unblocks web→link (and could backfill
  a tweet's card image from `media[]`).
