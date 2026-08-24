# 422 — the null that could not cross

Tier 2 works. The switch is on, the UI test passes, and a share from Safari lands a
capture built from the page's own DOM with the picture fetched. 421 shipped it switched
off on the belief that Safari's page item could not be loaded; that belief was wrong,
and this entry is mostly the record of why it looked true for a day.

## The bug

`PagePreprocessor.js` returned `null` for every absent field — `text()` was written to
return "a string, or null … so Swift sees one kind of absent". Safari vends the script's
return value as a `com.apple.property-list` attachment, and a JS `null` becomes `NSNull`,
which **is not a valid property-list value**. One null anywhere in the snapshot and Safari
cannot produce the representation at all. Every `loadItem` and `loadDataRepresentation`
then fails with:

```
NSItemProviderErrorDomain -1000 "Cannot load representation of type com.apple.property-list"
  NSUnderlyingError = NSCocoaErrorDomain 4101 "connection to service with pid N
                      created from an endpoint"
```

Which reads as a dead XPC connection and is nothing of the kind. pid N is MobileSafari,
alive and foreground throughout. The error means what it says on its face — *cannot load
**representation of type com.apple.property-list*** — and the underlying 4101 is the
helper connection reporting it, not the cause.

**And the share is LOST, not degraded.** With `SupportsWebPage` set, Safari sends the page
item INSTEAD of a URL item, so there is nothing to fall back to. That asymmetry is what
made this worth a day: tier 2 failing is acceptable, tier 2 failing worse than tier 1 is
not.

### Why it looked intermittent

A page whose images all carry `alt` text and which has a `<link rel=canonical>` produces
no nulls, and works. The next page has one `<img>` without `alt` and cannot be shared at
all. An x.com post succeeded; a news article and a nine-line loopback fixture both failed.
Chasing that as a property of the *site* (auth walls, CSP, ad-heavy pages reaping the web
content process) cost three wrong hypotheses.

## The fix

`put(target, key, value)` — assign only what exists, so an absent field is an absent KEY.
Every field of `RawPageSignals` is already optional, so an absent key decodes to `nil`:
the same "one kind of absent" `text()` was written for, in the one spelling this boundary
accepts. `null` never reaches a snapshot object now; `put` is the only way a value gets in.

## How it was found

By experiment, after reasoning failed three times. The decisive step was replacing the
whole script with four lines that cannot fail:

```js
var ExtensionPreprocessingJS = new (function Probe() {
  this.run = function (parameters) {
    parameters.completionFunction({ probe: "ran", href: String(document.location.href) });
  };
})();
```

It loaded, `error=none`, results key present. That killed every hypothesis about the
mechanism in one run — Safari **does** run preprocessing scripts for a share extension,
`com.apple.share-services` and all — and moved the fault into our payload, where two
strings worked and our snapshot did not. The difference was the nulls.

Three hypotheses died on evidence along the way, each worth not re-testing:

| Hypothesis | Killed by |
|---|---|
| Simulator WebKit is broken (421's conclusion) | the device produced the identical error |
| Safari waits on the script and times out | `ms=44` — nothing is waiting |
| `loadItem` vs `loadDataRepresentation` | both fail identically; both need the representation |
| The plist value needs `.js` | Apple's Action template pairs `Action.js` with `<string>Action</string>` |
| JS preprocessing is Action-extension-only | the probe ran in a share extension |

## A second bug, found because the first was fixed

With tier 2 finally writing records, the first one read
`originalURL: "http://127.0.0.1/page.html"` — no port. `PageExtractor.cleanURL` rebuilt
the URL as `scheme://host + path`, dropping it. It is the Swift port of `base.js`'s
`cleanURL`, which builds from `url.origin` — and **JS `origin` includes a non-default
port**. So any site not on 80/443 had its URL silently rewritten as a different page's.
Default ports are still dropped, as `origin` drops them, so a phone capture and a browser
capture of the same URL still match.

## Diagnostics kept

The `page item —` line (route, elapsed ms, the dictionary's keys, both errors) and the
`page harvest —` line (media count, kinds, article indices, chosen media URL) stay
permanently. Elapsed time is not decoration: a load that fails in single-digit ms failed
because nothing could be produced, one that fails after seconds failed waiting — opposite
fixes, identical error text. `diagnose(_:)` names which of `harvest(fromResults:)`'s four
guards refused, because a pure function returning `nil` is right for a hundred unit tests
and useless in the one process whose input cannot be reproduced.

## Files

| File | Change |
|---|---|
| `AtelierRefs/AtelierRefsShare/PagePreprocessor.js` | `put()`; no null ever emitted; header records the rule |
| `AtelierRefs/AtelierRefsShare/Info.plist` | `SupportsWebPageWithMaxCount` + `NSExtensionJavaScriptPreprocessingFile` ON |
| `AtelierRefs/AtelierRefsShare/ShareViewController.swift` | keyed-archive decode; both load routes; timing; `diagnose`; load starts first in `viewDidLoad` |
| `AtelierCapture/Sources/AtelierCapture/PageExtractor.swift` | `cleanURL` keeps a non-default port |
| `AtelierCapture/Tests/.../PageExtractorTests.swift` | the port test |
| `extension/test/ios-preprocessor.test.js` | the no-nulls guard |
| `AtelierRefs/AtelierRefsMobileUITests/Tier2ShareUITests.swift` | un-skipped; main-actor annotations |

## Verification

- `./scripts/verify.sh fast` — **all 10 stages passed**; `AtelierCapture` 125 tests.
- `node --test extension/test/ios-preprocessor.test.js` — 8/8. The no-nulls guard was
  mutation-tested: reintroducing a single `alt: null` fails it, restoring passes.
- `Tier2ShareUITests` on the simulator — **TEST SUCCEEDED**, and the record it wrote:

```json
{ "platform": "web", "title": "A concrete stair", "authorName": "Atelier Fixture",
  "payloadFile": "5A1450A9-….bin", "rawMetadata": { "capturedVia": "ios_share" } }
```

with a real 1800×1200 JPEG beside it — DOM provenance and fetched bytes, the whole path.

## Follow-up: the rewrite that downgraded

The first real device capture off x.com logged:

```
chose=    …?format=webp&name=orig    → media fetch returned 404
fallback= …?format=webp&name=medium  → saved
```

The fallback did its job, and that is exactly why this was worth catching: the capture
succeeded at the WRONG RESOLUTION and nothing about it looked wrong. `name=orig` and
`format=webp` are incompatible on twimg — the pair 404s — so every phone capture of a
tweet photo was quietly landing as `medium`.

`base.js` never hit it because a browser capture starts from a right-clicked `srcUrl`,
which is jpg. The phone starts from the DOM's `currentSrc`, which Safari has negotiated to
webp. `toOrigName` now moves `format=webp` to `jpg` along with the name, and only that one
pair — a format that can serve `orig` is left alone.

**`extension/src/extractors/base.js:105` has the same latent bug**, and would hit it
wherever a browser extractor reads a rendered `<img>` rather than a right-click. Not
changed here, because the browser path has not been observed failing and the two files are
a deliberate mirror that should move together, deliberately.

## Still owed by a device

The simulator proves the mechanism; it cannot prove the case tier 2 exists for. An
auth-walled post (x.com, instagram, pinterest) is where a cookie-less fetch from the Mac
sees a login wall and Safari is already signed in. That share, on hardware, is the
remaining check — along with the gate-2 footprint measurement and the AirDrop transport.
