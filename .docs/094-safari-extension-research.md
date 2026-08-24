# 094 — Safari Web Extension on iOS: what ports, what doesn't

091 names this doc as the follow-on to open question 1, "only after open question 1 is
answered". It is answered — iOS 26 honours `world: "MAIN"` at `document_start`
([425](../.change-log/425-the-main-world-is-open-on-ios.md)) — so the mechanism the whole
tier-3 case rested on is available.

This doc is about everything else, because the mechanism turned out not to be the hard
part. **Three seams do not port, and the interaction seam is the one 091's "+4–6 weeks"
estimate does not account for.**

---

## 1. What is settled

- **The hook works.** MAIN world at `document_start`, worlds genuinely separate, 36 of the
  page's own XHRs intercepted on a logged-in x.com including a GraphQL call (425).
- **`xcrun safari-web-extension-converter` warns `world` is unsupported and is wrong.**
  That warning will reappear on the real port. Ignore it.
- **Everything downstream of the inbox already exists.** 092 built `InboxWriter`,
  `InboxDrain`, `InboxArchive` and the Mac import, all tested, all measured. A tier-3
  capture that reaches the inbox is finished work from that point on.

## 2. Seam one — the trigger does not exist on iOS

**This is the finding that should shape the plan.**

Single-item capture on the desktop is a right-click:

```js
browser.contextMenus.create({
  id: "atelier-save", title: "Save to Atelier",
  contexts: ["page", "image", "link"],
});
```

and the handler reads `info.srcUrl` — *the exact image the user pointed at*. `sw.js:400`
calls this "far more reliable than guessing from the page (esp. capturing a pin from the
feed)", which is precisely right: in a feed of forty images, the right-click is the user
telling the extension which one they mean.

**iOS Safari has no context menu for extensions.** There is no `contexts: ["image"]`, no
`info.srcUrl`, and no equivalent. The extension's primary interaction disappears, and with
it the disambiguation it was doing.

Worse, the obvious OS-level substitute does not supply it either. Long-pressing an image
in Safari and choosing Share sends **`public.url` only** — no bytes, no element identity —
measured on a device on 2026-08-24 (`share arrived — items=1 [public.url …]`).

So a replacement has to be designed, not ported. The candidates:

| candidate | what it gives | what it costs |
|---|---|---|
| **Toolbar popup** (`action.default_popup`, reachable from Safari's extensions menu) | a deliberate "capture this" gesture | no element identity — the content script must guess the focal post, the exact thing `srcUrl` existed to avoid |
| **In-page affordance** injected by the content script (a small button per post) | precision equal to a right-click | the extension modifies the page's appearance; fragile against site redesigns; the desktop extension has deliberately never done this |
| **Keep the share sheet** (tier 2) as the trigger, extension for fidelity only | no new interaction at all | the share sheet cannot see the hook's intercepted payloads — different process, different lifetime |

The third deserves a hard look, because it is nearly free and it reframes the project: the
extension's job becomes *accumulating* intercepted payloads, and the share sheet stays the
"save this" gesture. Whether a content script can hand what it captured to a share
extension that launches later is an open question (see §6).

**None of these is a port. This is new design, and 091's estimate reads like it assumed
the interaction came across with the code.**

## 3. Seam two — the transport does not port

Desktop captures POST to the Mac:

```js
export const DEFAULT_BASE = "http://127.0.0.1:47321";   // endpoint.js
```

`base-url.js` probes 47321 (stable) then 47322 (dev) and caches the winner. On iOS there
is no Mac on loopback and the app's `CaptureServer` binds 127.0.0.1 only, so **nothing is
listening**.

The replacement is already built. A Safari Web Extension ships inside a host app and gets
a native handler — `SafariWebExtensionHandler` — which is an app extension with App Group
access. So:

```
content script → browser.runtime.sendNativeMessage
              → SafariWebExtensionHandler (Swift)
              → InboxWriter (092 · S2)
              → inbox/  →  InboxArchive  →  AirDrop  →  Mac
```

Everything from `InboxWriter` rightwards is done, tested, and measured. `endpoint.js` and
`base-url.js` are replaced by one native-message call; the *shape* being sent is already
the shared `CaptureRequest` contract (`capture-contract.json`), which both languages
already agree on and both suites already gate.

This seam is genuinely small, and it is the one 091's estimate would have been thinking of.

## 4. Seam three — bytes

The desktop extension sends image bytes as base64 in an HTTP body. Native messaging is not
an HTTP body, and a Safari extension's native handler is an app extension under a jetsam
ceiling — the same constraint 092 · gate 2 measured for the share extension (footprint
6.4 MB while writing a 16.3 MB payload, against a 120.0 MB ceiling; see
[423](../.change-log/423-the-extension-measures-itself.md)).

Two shapes, and the second is almost certainly right:

1. **Bytes through the message.** Base64 through native messaging, then `InboxWriter`.
   Simple, and puts a whole image in memory in a process with a ceiling — the exact thing
   091 · D2 and S2's design spent their effort avoiding.
2. **URL through the message, native fetches.** The message carries provenance and a media
   URL; the native side downloads to a file and writes it. This is *already what the share
   extension does* (`fetchMedia` → `download(from:)` → `adopt`), already measured, and
   already known to cost 0.2 MB for a 16 MB payload.

Shape 2 also inherits the auth problem tier 2 has: a cookie-less native fetch cannot pull
a login-walled image. But unlike tier 2, **the extension has the page's cookies** — so the
content script can fetch the bytes itself and hand over a blob, or the hook may already
have the response body in hand from the interception it did. That is the interesting
design question in this seam and it is worth a spike before committing.

## 5. What ports unchanged

Roughly 1,136 lines, and they are the valuable ones:

| file(s) | why it ports |
|---|---|
| `hook-core.js`, `twitter-hook.js` | wraps both `fetch` AND `XMLHttpRequest` (`hook-core.js:41`) — and XHR is the path iOS traffic actually took (425) |
| `extractors/*` | pure DOM/JSON → provenance; already proven portable — `PageExtractor.swift` is a Swift transcription of them |
| `harvest.js`, `host-table.js`, `media-hosts.js` | pure rules over plain values |

The extractors have effectively been port-tested already: 092 · S4b reimplemented them in
Swift for tier 2, which is how yesterday's `name=orig`/webp bug was found in **both**
copies at once.

## 6. What probably should not port

`bulk-*.js` is **2,407 lines** — more than twice the core — and it drives scroll-based mass
capture of timelines, boards and saved collections. On a phone this is questionable on
three counts: the interaction (a sweep is a desk activity), the memory ceiling, and
background execution (iOS suspends; a sweep that runs for minutes will not survive).

**Recommendation: explicitly scope the port to single-item capture and state that in the
plan.** Not "later" — *out*, until someone argues for it. Half the codebase not ported is
half the codebase not maintained twice.

## 7. Open questions

1. **The worker question.** 425 measured `fetch: 0, XHR: 36`. Either the mobile site uses
   XHR where desktop uses `fetch`, or the `fetch` calls happen inside a **worker**, which a
   MAIN-world page hook does not reach. The second would mean some payloads are invisible
   on iOS in a way they are not on desktop — a fidelity ceiling, not a blocker. Resolvable
   with a timeline scroll and a counter.
2. **Can an intercepted payload survive to a later share?** If yes, §2's third candidate
   (share sheet as trigger, extension as accumulator) becomes the cheapest good answer.
   Storage would be `browser.storage.local` written by the content script and read by the
   native handler — needs verifying that both sides see the same store.
3. **Does the popup exist on iOS as a usable surface?** `action.default_popup` is declared
   today and Safari on iOS reaches extensions through the address-bar menu. Whether that is
   a *good* capture gesture is a design question, not a technical one.
4. **Permission UX.** Per-site allow, and the site must be allowed BEFORE the page loads to
   catch `document_start`. This bit during the probe itself: `twitter.com` was allowed and
   `x.com` was not, and the result read as a total failure until that was spotted. A user
   who allows one host and not its alias gets silence.
5. **MV3 background on iOS.** `sw.js` is a module service worker. Safari supports
   non-persistent background, but the sweep controller's assumptions about staying alive
   are desktop assumptions — moot if §6 is accepted.

## 8. Sizing

091 says "+4–6 weeks, gated". Against these findings:

| | |
|---|---|
| hooks + extractors port | small — the code moves as-is, the tests come with it |
| native-message → `InboxWriter` seam | small — the contract exists and is gated |
| bytes design + spike | medium — §4 has a real question in it |
| **the trigger** | **unestimated in 091** — this is design, not porting |
| bulk sweep | excluded per §6 |

The estimate is plausible **only if the trigger question is answered cheaply** (§2's third
candidate) and the sweep is out of scope. If the answer is an in-page affordance, the
project is materially larger and takes on maintenance against three sites' redesigns.

## 9. Recommended next step

Not a plan doc yet. **Answer open questions 1 and 2 (§7) with one afternoon's spike**,
because between them they decide the shape of the whole thing:

- scroll a logged-in timeline with the probe still installed, and read whether GraphQL
  traffic appears in quantity (fidelity ceiling), and
- write from a content script to `browser.storage.local` and read it from the native
  handler (decides whether the share sheet can stay the trigger).

If both come back well, tier 3 is a small project with a known shape. If either comes back
badly, the design changes before anything is committed to.
