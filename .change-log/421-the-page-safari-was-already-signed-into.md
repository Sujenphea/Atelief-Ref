# 421 — the page Safari was already signed into

092 · S4b tier 2. The phone shares from Safari now, and what it sends is what the DOM said.

## Why tier 2 is worth having at all

`PageResolver.isAuthWalledHost` names **x.com, instagram.com, pinterest.com** and three
others: a cookie-less fetch of those pages returns a login wall or a 270px share card,
never the post. That is why the Mac's answer for a pasted link from one of them is "capture
it with the extension" — the extension rides an authenticated browser session.

**Safari on the phone IS that session.** `NSExtensionJavaScriptPreprocessingFile` is the
one mechanism by which a share sheet can see a page's DOM, and behind the login wall the
DOM has the real image URL, the author, and the post's own canonical URL. Without it, a
link shared from X lands as a bare card and stays one forever, because nothing downstream
can ever resolve it.

## What decides what

The script reads the DOM and **decides nothing**. Which meta wins, which image is the
post's, what the media URL is, which platform this is — all of it is Swift, in
`AtelierCapture`, tested under `swift test` with no device, no Safari and no page.

That is not a new idea; it is this repo's own split, applied to the phone.
`extension/src/harvest.js` separates `harvestSignals()` (runs in the page, serialized, no
imports, hand-checked) from `buildHarvest(raw)` (pure, unit-tested with plain objects).
`PagePreprocessor.js` is the first and `PageHarvest.build(from:)` is the second, rule for
rule. **The rule for changing the JS: if you are writing an `if` about a hostname, it
belongs in `PageExtractor.swift`.**

Platform dispatch does not re-implement the five JS `match(url)` functions either — it asks
`ShareCapture.platform(forURLString:)`, whose host table is already gated against the JS
extractors by `extension/src/host-table.js` in CI. One table, one gate, two readers.

## The fetch, and why it is defensible in an extension

The user chose: **the phone fetches.** The extension downloads the scraped URL and writes
an ordinary byte-backed capture — the identical shape a photo share produces, so the drain,
the archive format and the Mac need *nothing new* for it. It is also what the other
producer does: the browser extension fetches in-browser and POSTs bytes.

Bounded on every axis that can hurt:

| bound | why |
|---|---|
| http(s) only | decided in `ShareCapture.mediaCandidates`, where a test can see it — a `javascript:` src reaching a URLSession would be a decision, not an accident |
| 8s timeout | a receipt the user is watching is on the other side of it |
| `InboxWriter.maximumPayloadBytes` | checked against `expectedContentLength` before a byte moves, and against the file's real size after, because servers lie |
| streamed to a file | `URLSession.download` never holds the body, so a 12 MB photo costs this process nothing (091 · D2) |
| cookie-less ephemeral session | `PageResolver`'s posture on the Mac; this is a public CDN asset and has no business with anyone's cookies |

**Every failure degrades to the tier-1 link, carrying the richer provenance.** A text-only
tweet, a 404 on a `/originals/` rewrite, and a phone with no signal all arrive at the same
place, and it is a better place than tier 1 alone: the author, the post's own URL and the
tweet id came from the DOM. *Tier 2 failing is tier 1 succeeding* — which is the property
that makes attempting a fetch here safe rather than reckless.

## Three deliberate removals from the browser extension's version

- **No `context`.** The JS extractors prefer the right-clicked element, because a browser
  capture is usually a right-click in a feed. A share sheet has no right-click: the user
  shared THE PAGE. Every `firstPostURL([context…])` collapses to the live URL.
- **No canvas video frame.** A share sheet is already on screen waiting, `canvas` is
  tainted for cross-origin video (so it fails on exactly these sites), and a data-URL of a
  decoded frame is an image's worth of bytes crossing XPC. The poster is harvested instead,
  so a video post still yields a picture.
**One ordering worth stating.** When a share carries page results AND image bytes — a
long-pressed image in Safari — the provenance is the DOM's and the picture is the bytes
that arrived. Re-fetching "the largest image on the page" would hand the user a different
picture than the one they pressed. It is tier 1's own rule (image bytes beat a URL) applied
one level up.

- **No `mediaUrls[]`.** The extension carries up to four photos of a tweet as payload
  references. The phone fetches one file into one sidecar (092 · S2), so a second URL would
  be a promise nothing keeps.

## Two caps in the script, and what they cost

The snapshot crosses an XPC boundary, so images under 100px a side are skipped (icons,
avatars, tracking pixels — nothing any extractor would pick) and at most 80 are returned,
**in DOM order**. DOM order is load-bearing rather than incidental: the X extractor takes
the first media in the focal `<article>`, so sorting here would break scoping in Swift. The
cost is that a very long feed can lose a late image — acceptable, because tier 2 is for
sharing a POST page.

## Verification

`AtelierCapture` **124/7**, up from 104/5. The rules each test pins are the ones that have
actually gone wrong somewhere:

| test | the claim |
|---|---|
| `twitterTextOnlyIgnoresReplies` | a text-only tweet does not borrow a reply's photo, and does not adopt X's generic card |
| `twitterFallsBackWithoutArticles` | …but with no article structure, `og:image` may stand in |
| `pinterestLargest` | the biggest `i.pinimg`, at `/originals/`, and NOT the enormous `s.pinimg` share logo |
| `liveURLWins` | an SPA's live URL beats its stale canonical |
| `pageWithoutBytesDegradesToALink` | the degradation, with provenance intact |
| `mediaCandidatesAreFiltered` | best-first, http(s) only |

Plus **7 node tests** for the script itself, in `extension/test/` — the only runner in this
repo that can execute it. `harvestSignals` is deliberately untested (it only reads a DOM);
this one earns tests because it CAPS and it INDEXES, and those are rules.

`npm test` 541/541. `npm run drift-check` — no drift; the host table is unchanged.
`verify.sh fast` 10 stages. Both apps and the extension build; `PagePreprocessor.js` is in
the built `.appex` and the plist carries the key.

**Unverified, and stated rather than glossed:** no share has been made from Safari on a
device or a simulator. The activation rule, the script's presence and the key are checked
in the built bundle; what a real page yields is not. Everything downstream of the snapshot
is under test, so the untested span is the DOM read itself — which is the span a simulator
share would exercise and nothing else can.

## Files

    AtelierCapture/Sources/AtelierCapture/       the raw snapshot, classified
      PageHarvest.swift
    AtelierCapture/Sources/AtelierCapture/       twitter / pinterest / instagram / web
      PageExtractor.swift
    AtelierCapture/Sources/AtelierCapture/       the `.page` case and its draft
      ShareCapture.swift
    AtelierRefs/AtelierRefsShare/                the script Safari runs
      PagePreprocessor.js
    AtelierRefs/AtelierRefsShare/Info.plist      SupportsWebPage + the script key
    AtelierRefs/AtelierRefsShare/                reads the results, fetches the media
      ShareViewController.swift
    extension/test/ios-preprocessor.test.js      7 tests, where node runs

## Migration notes

None. The wire contract is untouched — a tier-2 capture with bytes is the shape a photo
share already produced, and one without is the shape a link share already produced. A Mac
running today's build imports both without knowing tier 2 exists.

**What tier 2 still owes:** a share from Safari on a real device. And the rewrite rules
(`name=orig`, `/originals/`) are a second mirror of `base.js` that the host-table gate does
not cover — they fail softly, yielding a smaller image rather than a lost capture, which is
why they ship without one, and why one would still be worth adding.
