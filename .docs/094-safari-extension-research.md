# 094 — Safari Web Extension on iOS: what ports, what doesn't

091 names this doc as the follow-on to open question 1, "only after open question 1 is
answered". It is answered — iOS 26 honours `world: "MAIN"` at `document_start`
([425](../.change-log/425-the-main-world-is-open-on-ios.md)) — so the mechanism the whole
tier-3 case rested on is available.

This doc is about everything else, because the mechanism turned out not to be the hard
part. **Three seams do not port, and the interaction seam is the one 091's "+4–6 weeks"
estimate does not account for.**

> **Amended 2026-08-25**, after a verification pass over the claims below against the
> code. Every file citation and both LOC figures were checked; §6's 2,407 is exact and
> §5's was not (corrected in place). Three findings changed the argument rather than the
> prose, and each is marked **[amended]** where it lands:
>
> 1. **Open question 2 was framed on a premise that cannot come back yes** — a native
>    handler has no API for reading `browser.storage.local` (§7.2). The accumulator
>    design survives, but it is not nearly free, which was the whole reason §2 liked it.
> 2. **A content script cannot write into the App Group** — only the native handler can.
>    That closes §4's fork tighter than §4 stated, and moves it ahead of the trigger as
>    the question the spike must answer first (§9).
> 3. **The hook already buffers responses for replay** (`hook-core.js:38`), which helps
>    an accumulator and does nothing for persistence across a share.

---

## 1. What is settled

- **The hook works.** MAIN world at `document_start`, worlds genuinely separate, 36 of the
  page's own XHRs intercepted on a logged-in x.com including a GraphQL call (425).
- **`xcrun safari-web-extension-converter` warns `world` is unsupported and is wrong.**
  That warning will reappear on the real port. Ignore it. **[amended]** It did reappear,
  on the first conversion after this doc was written — and it is not the converter's only
  fault. Given `--bundle-identifier sujenphea.tier3probe` it wrote the app as
  `sujenphea.Tier3Probe` (title-cased from `--app-name`) and the extension as
  `sujenphea.tier3probe.Extension`, so the two no longer share a prefix and
  `ValidateEmbeddedBinary` fails the build with *"Embedded binary's bundle identifier is
  not prefixed with the parent app's bundle identifier."* One `sed` over the pbxproj. It is
  named here because the message points at the embedding and the cause is the converter.
- **Everything downstream of the inbox already exists.** 092 built `InboxWriter`,
  `InboxDrain`, `InboxArchive` and the Mac import, all tested, all measured. A tier-3
  capture that reaches the inbox is finished work from that point on. The drain runs at
  launch and on activation ([407](../.change-log/407-the-drain-nobody-called.md)), the
  archive imports on the Mac dates and all
  ([418](../.change-log/418-thirty-one-years-in-the-future.md)), and the transport was
  taken by a device ([424](../.change-log/424-airdrop-takes-a-folder.md)).
- **[amended] The probe is not in the repo, on purpose.** 425 kept it in a session
  scratchpad (`tier3-probe/`, `tier3-xcode/`) because it was built to answer one question
  once. Nothing under `extension/` or `AtelierRefs.xcodeproj` is a Safari-web-extension
  target today. That was the right call for a feasibility probe and it is a cost for §9's
  spike, which needs a probe that fetches, messages, and writes — so budget rebuilding it
  rather than assuming 425's is on hand.

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

The third deserves a hard look because it reframes the project: the extension's job
becomes *accumulating* intercepted payloads, and the share sheet stays the "save this"
gesture. Whether a content script can hand what it captured to a share extension that
launches later is an open question (see §7.2).

> **[amended]** This paragraph said "nearly free", and that was the reason to prefer it.
> It is not. The only route from a content script into the App Group is
> `sendNativeMessage` → the native handler → a file (§4's amendment), so the accumulator
> cannot be a lazy read at share time — it has to **push to native continuously while the
> user browses**. That is a different posture on a phone: always-on writing, storage that
> grows, battery, and a much larger set of intercepted payloads at rest than a
> capture-on-demand design ever holds. It may still be the right answer. It is no longer
> the cheap one, and the join at share time is a match on URL between what the share sheet
> sends (`public.url`) and what the accumulator stored.

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

> **[amended] The chain is one hop longer than that, measured on a device 2026-08-25.**
> A content script calling `browser.runtime.sendNativeMessage` gets
> `TypeError: sendNativeMessage is not a function`. Native messaging is not exposed to
> content scripts — it lives in the background context and in extension pages. Same rule
> as Chrome; not an iOS quirk. What actually runs is:
>
> ```
> MAIN world (hook)  →postMessage→  ISOLATED content script
>                    →runtime.sendMessage→  background service worker
>                    →sendNativeMessage→  SafariWebExtensionHandler  →  InboxWriter
> ```
>
> Two consequences, and neither is cosmetic. **The bytes cross two structured-clone
> boundaries, not one**, so §4's shape 1 is paying for the payload twice and the ladder has
> to say *which* hop refused it. And the extra hop lands squarely in §7.5 — MV3 background
> on iOS — which this doc had filed as "moot if §6 is accepted". It is not moot: dropping
> the sweep removes the *long-lived* background assumption, but single-item capture now
> needs the worker alive for one round trip on every capture. That is the easy case for a
> non-persistent worker, and it is no longer zero.

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
have the response body in hand from the interception it did.

> **[SUPERSEDED 2026-08-25 by [095](095-tier3-spike-results.md) § 4 — the premise was
> wrong.]** The table below asserts that shape 2 "**fails** — cookie-less". That was never
> measured, and it is false for X: a session-less `URLSession` (ephemeral, cookies refused,
> stricter than `ShareViewController.fetchMedia`'s) fetched the same `name=orig` image,
> **byte-identical to the credentialed fetch**, at a 2.9 MB footprint. The auth wall is on
> *reaching the post*, not on *fetching the media*. Shape 2 is the design; the ladder below
> measured a road not taken. **Everything from here to the end of §4 is kept for the
> record, not as guidance** — including the memory argument, which was right about shape 1
> (measured 2.36–2.38×, predicted 2.33×) and is now moot. Read 095 first.
>
> **[amended] The two shapes above are the whole set, and for login-walled media neither
> is good.** The reason is a limit this section did not state: **a content script cannot
> write into the App Group.** Only the native handler can — it is the app extension, the
> content script is a web page. So there is no third shape where the page fetches with
> cookies and hands over a *file*; anything the page fetches has to cross
> `sendNativeMessage`.
>
> | | auth-walled media | memory |
> |---|---|---|
> | **1 — page fetches, base64 through the message** | works; the page has the cookies | the payload is resident in a jetsam-capped process, which is exactly what S2's design and the 6.4 MB reading exist to prevent. Safari's native-message size limit on iOS is **unmeasured** and may cap this well below `InboxWriter.maximumPayloadBytes` (64 MiB) |
> | **2 — URL through the message, native fetches** | **fails** — cookie-less | free: `fetchMedia` → `download(from:)` → `adopt`, measured at 0.2 MB for 16.3 MB (`ShareViewController.swift:543`, [423](../.change-log/423-the-extension-measures-itself.md)) |
>
> The session-authenticated fetch the page side would use is not hypothetical — it is
> built. `hook-core.js`'s `headerAllowlist` remembers the `authorization`/csrf pair the
> page just sent, in the closure and never across a message boundary, and `hook-proxy.js`
> spends it on follow-up requests in the user's own session (090 · 3A); `sw.js:60` already
> fetches media bytes that way on the desktop. What is missing is not the fetch. It is a
> cheap way for its result to reach a process that can write a file.
>
> **This, not the trigger, is the question that decides whether tier 3 is worth building.**
> If neither shape carries auth-walled bytes affordably, tier 3's advantage over tier 2
> collapses to provenance-only — better metadata on the same picture tier 2 already gets —
> and the trigger question never needs answering. §9 is reordered accordingly.

## 5. What ports unchanged

**1,455 lines** — counted 2026-08-25: `hook-core.js` 297, `twitter-hook.js` 109,
`harvest.js` 164, `host-table.js` 263, `media-hosts.js` 56, `extractors/` 566 — and they
are the valuable ones. *(**[amended]** this said "roughly 1,136"; the figure was low by
28%, in the direction that favours the port.)*

| file(s) | why it ports |
|---|---|
| `hook-core.js`, `twitter-hook.js` | wraps both `fetch` AND `XMLHttpRequest` (`hook-core.js:41`) — and XHR is the path iOS traffic actually took (425) |
| `extractors/*` | pure DOM/JSON → provenance; already proven portable — `PageExtractor.swift` is a Swift transcription of them |
| `harvest.js`, `host-table.js`, `media-hosts.js` | pure rules over plain values |

The extractors have effectively been port-tested already: 092 · S4b reimplemented them in
Swift for tier 2, which is how yesterday's `name=orig`/webp bug was found in **both**
copies at once. And the claim that the two copies agree is a CI gate rather than a comment
— `npm run drift-check` runs in `ci.yml:109`
([404](../.change-log/404-the-mirror-nobody-checked.md)), so a ported extractor that
diverges from `PageExtractor.swift` fails the build.

## 6. What probably should not port

`bulk-*.js` is **2,407 lines** — more than twice the core — and it drives scroll-based mass
capture of timelines, boards and saved collections. On a phone this is questionable on
three counts: the interaction (a sweep is a desk activity), the memory ceiling, and
background execution (iOS suspends; a sweep that runs for minutes will not survive).

**Recommendation: explicitly scope the port to single-item capture and state that in the
plan.** Not "later" — *out*, until someone argues for it. Half the codebase not ported is
half the codebase not maintained twice.

## 7. Open questions

1. ~~**The worker question.**~~ **ANSWERED — no ceiling** ([095](095-tier3-spike-results.md) § 2).
   Counting the transports apart gives `fetch: 2, xhr: 44–61`: the mobile site prefers XHR,
   there is no hidden population in a worker, and `hook-core.js` wraps both. GraphQL lands
   at roughly one in four parsed responses against 425's one in thirty-six. Original text
   below.

   **The worker question.** 425 measured `fetch: 0, XHR: 36`. Either the mobile site uses
   XHR where desktop uses `fetch`, or the `fetch` calls happen inside a **worker**, which a
   MAIN-world page hook does not reach. The second would mean some payloads are invisible
   on iOS in a way they are not on desktop — a fidelity ceiling, not a blocker. Resolvable
   with a timeline scroll and a counter.
2. ~~**Can an intercepted payload survive to a later share?** … Storage would be
   `browser.storage.local` written by the content script and read by the native handler —
   needs verifying that both sides see the same store.~~
   **[amended] Rewritten — the original had no answer that could come back yes.** There is
   no API by which `SafariWebExtensionHandler` reads `browser.storage.local`; the handler
   is an app extension and sees only what a `sendNativeMessage` / `connectNative` call
   hands it. `storage.local` is the *extension's* store, not a shared one, and the share
   extension is a third process again. So the spike cannot verify "both sides see the same
   store" — there is no store to share.

   The reachable design, and the thing to verify instead: **content script →
   `sendNativeMessage` → native handler → a file in the App Group → share extension reads
   it at share time.** Every hop there exists; what is unproven is the cadence (§2's
   amendment: continuous push, not lazy read) and the join at the far end, which is a
   match on URL.

   Note also that the hook **already buffers** — `RESPONSE_HOOK_REPLAY_LIMIT = 25`, with
   responses re-emitted on a `message` whose `data.source === replaySource`
   (`hook-core.js:38`). That is the accumulator's in-page half, already written and
   already tested. It is *not* persistence: the buffer lives in the page's MAIN world and
   dies with the tab, which is precisely the gap the native hop closes.
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
| **bytes for auth-walled media** | **[amended] the gating question** — §4's two shapes are the whole set and neither is free; a bad answer here ends the project rather than resizing it |
| **the trigger** | **unestimated in 091** — this is design, not porting |
| bulk sweep | excluded per §6 |

The estimate is plausible **only if the trigger question is answered cheaply** (§2's third
candidate) and the sweep is out of scope. If the answer is an in-page affordance, the
project is materially larger and takes on maintenance against three sites' redesigns.

**[amended]** And it is plausible only if the bytes answer is shape 1 within Safari's
native-message limit. Two rows above moved: the bytes row was "medium — §4 has a real
question in it", which read as a sizing risk. It is not a sizing risk. It is the row that
decides whether the other rows get built, and §2's third candidate is no longer the cheap
trigger answer the paragraph above leans on.

## 9. Recommended next step

> **[RAN 2026-08-25 — see [095](095-tier3-spike-results.md).]** Readings 1 and 3 are in and
> both pass; reading 1 passed by overturning §4's premise rather than by confirming it, so
> the stop condition below was never reached. Reading 2 is unrun and is only needed if the
> share sheet stays the trigger. **The next doc is a plan, not more research** — after one
> tap per host to check whether §4's finding generalises beyond X (095 § 8.1).

Not a plan doc yet. **One spike, three readings, in this order** — the order matters
because the first reading can end the project and the third is wasted effort until it
doesn't. All three run on one rebuilt probe extension (§1: 425's is not in the repo), on a
device, against a logged-in x.com.

> **[amended] Reordered.** This section originally ran open questions 1 and 2 and did not
> mention bytes at all — §4 said the bytes question was "worth a spike" and the spike did
> not include it. Since a bad bytes answer collapses tier 3 to provenance-over-tier-2,
> it goes first.

1. **Bytes, auth-walled (§4).** Fetch one login-walled image from the content script in
   the page's own session, and push it through `sendNativeMessage` to a native handler
   that writes it via `InboxWriter`. Read two numbers: **the largest payload the message
   accepts**, and **the handler's `phys_footprint` while it holds one** — the extension
   already knows how to report the second (`ShareViewController.swift:434`), so the probe
   should borrow that code rather than invent it. A cap far below 64 MiB, or a footprint
   that scales with payload, means shape 1 is out; shape 2 is already known not to carry
   auth. **If both shapes are out, stop and write that down** — tier 3 is then a
   provenance improvement on tier 2, priced accordingly, and readings 2 and 3 below are
   moot along with the whole of §2.
2. **Persistence (§7.2, as rewritten).** Push a payload from a content script to the
   native handler, write it into the App Group, quit Safari, and read it from the *share*
   extension at share time — joining on URL. This decides whether the share sheet can stay
   the trigger, and note it is now a three-process test, not the two-process
   `storage.local` check this doc first described.
3. **Fidelity ceiling (§7.1).** Scroll a logged-in timeline with the probe installed and
   read whether GraphQL traffic appears in quantity, and whether `fetch` stays at 0. Worth
   knowing, and it changes a number rather than a decision.

If 1 and 2 come back well, tier 3 is a small project with a known shape and the trigger
(§2) is the only design left. If 1 comes back badly, the design changes before anything is
committed to — and the honest outcome may be that it is not built.
