# 096 — tier 3: the Safari Web Extension port (plan)

> The build order for the port [094](094-safari-extension-research.md) researched and
> [095](095-tier3-spike-results.md) measured. Planned against the tree on
> `feat/ios-companion` (2026-08-25), with every seam either measured on a device or
> already shipping on the Mac.
>
> **091 priced this at "+4–6 weeks, gated". It is no longer gated, and the estimate comes
> down** — the row that was priced as the gate turned out to reuse code that already
> exists and is already measured. What is left is one design decision and a port.
>
> **Revised 2026-08-25**, after a review pass over the plan against the code
> ([430](../.change-log/430-the-hook-nobody-would-listen-to.md)). Sixteen findings, all
> accepted. One of them changes the shape of the port rather than its size — **the hook
> has no consumer in tier 3** (§ D5) — and the rest are seams the first draft named in
> prose and left unowned. The sizing table at the foot carries the result: ~3.5–4 weeks,
> still inside 091's range, with most of the increase in T2, where sentences that read
> "what needs the device is the message boundary" became things `swift test` runs.
>
> **Revised again 2026-08-29**, after a review pass over the branch
> ([447](../.change-log/447-what-tier-3-replaces.md)). One addition, and it is a decision
> the first two drafts never made: **§ D4b — tier 3 supersedes tier 2 on the three sites it
> covers**, with T5 as the deletion that follows T4. Total moves to ~4–5 weeks, which is
> back inside 091's original "+4–6 weeks" band; the extra half-week is a removal, not a
> build, and it is what stops the Swift extractor mirror becoming permanent.

## What 095 settled, so this plan does not re-argue it

- **The hook ports unmodified.** `hook-core.js` copied verbatim, MAIN world at
  `document_start`, `readyState: loading` on every clean load. **It ports, and this plan
  does not port it** — see § D5.
- **No fidelity ceiling.** `fetch=2, xhr=44–61` — the mobile site prefers XHR, nothing
  hides in a worker, and the hook wraps both. **This measured a capability tier 3 does not
  consume** (§ D5); it stands as a reading about the desktop sweep path, not about this
  port.
- **Bytes are not a problem.** All three live CDNs serve identical bytes to a session-less
  `URLSession`. The native side fetches to a file at a **flat 2.9–3.1 MB**, and the ~120
  lines that do it are already written (`ShareViewController.fetchMedia`).
- **The chain is one hop longer than 094 drew it** — native messaging lives in the
  background worker, not the content script.
- **The handler's ceiling is 80 MB**, not the share extension's 120. § D6 is what makes
  that number load-bearing in the code rather than only in this paragraph.

## The one decision this plan has to make

**The trigger.** 094 § 2 called it the seam that would shape the plan, and it is the only
part of tier 3 that is design rather than porting. Three candidates were on the table.

### D1 — The popup, with viewport-centre focal-post selection

**Because the phone's viewport does most of the disambiguation the right-click was doing.**

`sw.js:399` says `info.srcUrl` is "far more reliable than guessing from the page (esp.
capturing a pin from the feed)", and it is right *about a desktop*: a desktop feed shows
forty candidate images at once, so a click is the only way to say which. **A phone shows
one post, sometimes two.** The candidate set the guess has to resolve is smaller by an
order of magnitude, and it is ordered by something the extension can read — how much of the
viewport centre each post occupies.

094 treated "the content script must guess the focal post" as the popup's disqualifying
cost. On this form factor it is a much cheaper guess, and D2 below gates it with a
measurement rather than an assumption.

**Candidate 3 (share sheet as trigger) is not just costlier — it is worse.** Safari's share
sheet sends `public.url`, which on a feed is the *feed's* URL: `x.com/home` identifies no
post at all. So candidate 3 works only once the user has opened an individual post — and at
that point candidate 1 has no ambiguity to resolve either. It cannot beat the popup where
the popup is weak, and it costs an always-on accumulator pushing intercepted payloads to
native while the user browses (094 § 2, amended). Dropped.

**Candidate 2 (in-page affordance) is dropped for the reason 094 gave, now observed.** The
spike's own panel is a working instance of it: it draws over the feed, it is styled against
nothing, and it would break on a redesign. Three sites' redesigns, maintained twice. The
desktop extension has deliberately never done this and this is not the moment to start.

**Tier 2 stays as the general case.** The share sheet is shipped, tested and device-proven;
it remains the capture path for native apps, and for every site tier 3 does not name.

~~Nothing is removed.~~ **Amended 2026-08-29 — see § D4b.** On the three sites tier 3 covers,
it supersedes tier 2 rather than sitting beside it, and the per-platform branches of the
Swift extractor are deleted once T4 passes (T5). Leaving both in place would mean two paths
producing different captures for the same post, which is untriageable. The share sheet keeps
working on those sites; it just answers as `web` provenance plus og-tags, which is what a
path that cannot see the DOM honestly knows.

### D2 — The focal-post guess is gated by measurement, before anything is ported

If the guess is wrong often enough to be annoying, D1 is wrong and the plan changes shape.
That is a one-day answer and it comes first — see T0.

### D3 — One JS source tree, two manifests

`extension/src/` stays the single copy. The Safari target references those files; it does
**not** get a fork.

The reason is the gate that already exists: `npm run drift-check` (`ci.yml:109`) compares
`extractors/` and `media-hosts.js` against `ShareCapture.swift`, because a domain added on
one side and not the other ships as forked provenance
([404](../.change-log/404-the-mirror-nobody-checked.md)). A second JS copy would need a
third arm on that check, and the whole point of 404 was that unchecked mirrors drift.

**Where "one source tree" is not literally true, and where it lives.** Two files cannot be
shared, because the desktop's equivalents are sweep code: the background worker and the
popup. They go under **`extension/src/safari/`** — additive, visibly named, importing only
the shared modules. And they *must* be new files rather than reuse, because of the module
graph: `sw.js:35-37` imports `bulk-messages.js`, `bulk-sw.js` and `bulk-endpoint.js`, so a
Safari worker importing `sw.js` drags in most of the 2,407 lines § D4 excludes. The
exclusion in § D4 is a manifest decision; the module graph is what actually decides, and it
decides the other way. Hence § D7.

What differs is the manifest, and only the manifest:

| | Chrome | Safari/iOS |
|---|---|---|
| `host_permissions` | includes `http://127.0.0.1/*` | **dropped** — nothing listens (094 § 3) |
| `hook-core.js` + `twitter-hook.js` content script | present | **dropped** — nothing consumes it (§ D5) |
| `bulk-loader.js` content script | present | **dropped** — sweeps are out (094 § 6) |
| `web_accessible_resources` | `src/*.js` for the hook + loader | **dropped** — no MAIN-world script to serve |
| `background` | `sw.js` (module) | `src/safari/worker.js` — forwards to native |
| `action.default_popup` | the sweep controls | `src/safari/popup.html` — the capture trigger |

**The drift check over the pair is behavioural, not set equality.** T1 adds it, and the
form matters: `host-table.js:19` argues at length that stating the invariant as "what would
the other side do with this host" beats diffing two lists, and that argument applies here
unchanged. It also closes a gap that predates tier 3 — `manifest.json:7`'s
`host_permissions` is a **fourth** copy of the domain list that `host-table.js` has never
checked, so a domain added to an extractor and forgotten in the manifest ships an extension
that classifies a page it has no permission to read, and CI passes today. See T1.

### D4 — What is out, stated so it is not "later"

**Bulk sweeps.** 2,407 lines of `bulk-*.js`, excluded per 094 § 6: a sweep is a desk
activity, it runs for minutes against a non-persistent worker, and half the codebase not
ported is half the codebase not maintained twice.

**RedNote.** Known walled ([324](../.change-log/324-rednote-is-walled.md)) and not covered
by 095 § 7's design. It can be added when someone measures it.

**The desktop's own `isAllowedMediaHost` gap.** § D6 puts the allowlist in front of the
tier-3 fetch. The *desktop* single-item path doesn't use it either (`media-hosts.js:30` is
imported only by `bulk-sw.js:12`) — a real, small improvement, and not tier 3's to make.
Named here so it is a follow-up rather than a discovery.

### D4b — Tier 3 SUPERSEDES tier 2 on the three sites it covers

**Added 2026-08-29**, from a review pass over the branch. The first draft of this plan never
said what happens to tier 2, and § D4 above lists what tier 3 *excludes* rather than what it
*replaces*. That omission has a cost that compounds: without an answer, T1–T4 get built
without knowing whether their output retires anything, and the Swift extractor mirror is
either temporary scaffolding or permanent infrastructure — which changes how much is worth
spending to keep it honest.

**The decision: once T4 passes, tier 3 owns x.com, instagram.com and pinterest.com. Tier 2
stays, and stays supported, for every other site.**

*Why not keep both everywhere.* Tier 3 exists precisely because tier 2 cannot reach current
fidelity — that is the premise of 094 and of this whole document. Two paths that produce
DIFFERENT captures for the same post is the shape of bug nobody can triage: a user shares a
tweet twice, once through the share sheet and once through the popup, and gets two different
answers with no way to tell which was supposed to happen. It is also the thing
`InboxDrain`'s own header rejects one layer down — "a second runner would mean two things
deciding independently" — applied to extraction instead of to ingest.

*Why tier 2 is not deleted.* It is the only path that works on a site no extractor knows,
and that is most sites. `PageExtractor.web` — og-tags, the largest rendered image, the
canonical URL — is not superseded by anything in tier 3, because tier 3's popup only offers
itself on hosts the manifest names. Tier 2 is the general case; tier 3 is three special
cases that happen to be the three that matter most.

*What this retires, concretely.* After T4: `PageExtractor.twitter`, `.pinterest` and
`.instagram`, and the per-platform half of `PageExtractorTests`. `PageExtractor.web`,
`PageHarvest`, `PagePreprocessor.js`, `ShareCapture` and the whole inbox path stay exactly as
they are. The share extension keeps its `SupportsWebPage` activation rule — a share of a
twitter.com page from the share sheet still captures, it just captures as `web` provenance
plus whatever og-tags the page carries, which is the honest answer for a path that cannot see
the DOM the way the extension can.

*What it does NOT retire.* The cross-language contracts, either of them. `host-table.js`
gates host → platform for `ShareCapture`, which is tier 1 and tier 2 and survives entirely.
`media-rewrite-contract.json` gates the URL-rewrite rules, and those live in
`PageExtractor`'s per-platform branches — so that gate retires with them, and the fixture
should be deleted in the same commit rather than left to pass vacuously against a mirror that
no longer exists.

**Sequencing: this is intent, not a task.** Nothing is removed until T4 has passed on all
three platforms on a device. If T0's gate fails and tier 3 narrows to post pages only (§ T0's
stated fallback), this decision narrows with it — tier 3 would then supersede tier 2 only on
post pages, and feeds stay tier 2's. Revisit here rather than discovering it in T4.

### D5 — The hook is not ported, because nothing in tier 3 would listen to it

**This is the review's finding that changes shape rather than size.**

095 opens on the hook and the first draft of this plan followed it. But trace who consumes
what `hook-core.js` emits, in the shipping tree:

- `hook-core.js` / `twitter-hook.js` (MAIN) `postMessage` → `intercept-source.js:3` →
  `twitter-source.js:11` → `bulk-twitter.js` → `bulk-engine.js` / `bulk-controller.js`
- `hook-proxy.js:1`, the ISOLATED request-proxy client, is imported by exactly one file:
  `bulk-controller.js:26`
- `twitter-detail-client.js:398` — "in production it is the MAIN-world hook's proxy" —
  is thread expansion, also sweep-only

**Single-item capture never touches it.** `sw.js:326 capture()` injects `harvestSignals`
(DOM), shapes it with `buildHarvest`, and runs the pure extractors. Video resolution goes
through `twitter-video.js`, which hits the *unauthenticated* syndication endpoint
(`twitter-video.js:16`) and needs no session at all.

§ D4 drops sweeps. So the manifest the first draft wrote would have injected a hook into
three sites at `document_start` whose messages nothing listens to — `bulk-loader.js`, the
ISOLATED listener, is the very file § D4 removes.

Four things follow, and none of them are tidying:

1. **Risk 4 disappears.** "The hook on Instagram is still unverified" is not a risk in a
   port with no hook.
2. **Risk 2 narrows** from "the extension does nothing until you reload" to "per-site
   permission must be granted" — see § D8.
3. **Risk 3 shrinks.** "We inject at `document_start` and wrap `fetch`/`XHR` on three named
   sites" and "we read the DOM on a user gesture" are materially different App Store
   submissions.
4. **T0 gains a gate.** The DOM harvest is now the *only* provenance source, so T0 must
   confirm it is sufficient on all three mobile feeds — which is the same session T0 was
   already spending.

The hook stays in `extension/src/`, unchanged, serving the desktop sweeps it was built for.
If T0 finds the mobile DOM genuinely thin somewhere, porting it plus an ISOLATED relay is
3–5 days and is then a decision with a reading behind it.

### D6 — Guards travel with the fetch, and caps are re-derived for this process

T2 reuses `ShareViewController.fetchMedia`. That function checks HTTP status and a byte cap
and stops there, which was right for the process it was written in and is not right here.
Three guards the desktop has and it does not:

1. **A `Content-Type` gate.** `sw.js:84` refuses anything not `image/*`, and its comment
   states the reason exactly: an error/login/HTML page "can't be 'successfully' ingested as
   garbage bytes." A 200-with-HTML from an expired signed Instagram URL passes `fetchMedia`
   today. **The check is post-hoc here and that is fine** — `session.download(from:)`
   returns only after the body is on disk, and the thing being rejected is a few KB, while
   `expectedContentLength` already blocks the large-and-wrong case *before* the body. It is
   deliberately not a `URLSessionDataDelegate` early-cancel; do not "fix" it into one.
2. **The candidate ladder.** `fetchImage` (`sw.js:71`) walks `[mediaUrl,
   mediaUrlFallback]` so a full-res URL that 404s degrades to the rendered one.
3. **The host allowlist.** `isAllowedMediaHost` (`media-hosts.js:30`) is the SSRF guard for
   page-supplied URLs, and its header says so. On tier 3 the URL is page-derived and the
   fetcher is a native process with no CORS and no origin. It runs **JS-side, inside
   `planCapture`**, before anything is messaged.

And the cap. `InboxWriter.maximumPayloadBytes` is 64 MB (`InboxWriter.swift:173`), sized
against the share extension's observed ~120 MB ceiling (`ShareViewController.swift:441`).
This process's ceiling is 80 MB. **The handler takes its own constant, ~24 MB, applied as
the `min()` of the two** — still 8× the flat 2.9–3.1 MB 095 measured, so nothing real is
refused, and the 80 MB figure now lives in the code instead of only in prose.

### D7 — `planCapture()`: the decision, separated from the transport

`captureCore` (`sw.js:174`) and `ingestOne` (`sw.js:216`) hold decisions tier 3 needs
identically — text-only tweet → media-less content capture (`sw.js:180`, `244`), candidate
ordering (`sw.js:250`), video-first with fail-open fallback (`sw.js:227-236`), the
`buildContentCaptureRequest` / `buildCaptureRequest` branch (`sw.js:264`) — fused to
decisions it must **not** inherit: base64-encode the bytes (`sw.js:99`, forbidden by
095 § 5), POST to `127.0.0.1` (`sw.js:160`), the shared-secret token (`sw.js:182`, `320`).

Ported as-is, that fork produces a second authority on "which URL wins, is this a text
card, is there a video" — the class of duplication [404](../.change-log/404-the-mirror-nobody-checked.md)
is the changelog of.

So T2.5 extracts **`extension/src/capture-plan.js`**:

```
planCapture(provenance, { mp4Url, content }) → { kind, urlCandidates, request }
```

Pure, no browser API, no transport, unit-tested with plain objects — the split `harvest.js`
already makes and `sw.js:15` already describes. `sw.js` imports it and keeps its glue; the
Safari worker imports it and nothing else from `sw.js`. It is a new module rather than an
injected `deliver` dependency on `ingestOne` because the iOS difference is not *where to
send* but *whether to fetch at all*, and a boolean that changes a function's meaning is the
kind of implicitness this codebase spends its comments arguing against.

### D8 — What the popup can say, and when it can say it

Tier 3 has **no badge**. `sw.js:350 flash()` and the `presentation()` map at `sw.js:290`
have no iOS equivalent, so the popup is the entire feedback surface — and 094 § 7.4's
permission problem was to be reported there.

**The vocabulary.** `extension/src/safari/capture-view.js`, a pure status →
`{ text, detail, retryable }` map, mirroring `popup-view.js`'s split (71 lines, its own
test file) and tested the same way. The status set:

`saved` · `deduplicated` · `no-focal-post` · `unsupported-site` · `permission-not-granted` ·
`media-fetch-failed` · `native-unreachable` · `inbox-write-failed` · `over-cap`

Two are new to this codebase — `native-unreachable` (the handler never answered) and
`inbox-write-failed` (an `InboxWriteError` came back). The status *names* come from
`planCapture`'s result vocabulary wherever they coincide, so `fetch-error` does not become
`media-failed` on one side of the boundary. Rendering stays separate: `presentation()`
returns badge colours and four-second-flash semantics, which mean nothing in a popup.

**And when.** An iOS Safari popup dismisses the moment the user taps the page, while the
chain — worker → native → fetch 2.9–3.1 MB → `InboxWriter` → back — is plausibly several
seconds on cellular. The common case is that the answer arrives at a popup that no longer
exists. So:

- the native side **writes to the inbox regardless of whether anyone is listening** (which
  is how the drain already thinks about the world);
- the popup reports `queued` on *message acknowledgement*, not on completion;
- the worker stores the last outcome, and the popup surfaces it **on next open**.

The inbox is the authoritative record; the popup is a view of it. A local notification
would report sooner and costs a permission prompt on first capture plus a wider review
surface — available later, if T4 says failures are common enough to need it.

---

## T0 — the focal-post gate (before any port)

**Why first:** D1 is the only unproven thing in the plan, and it is unproven in a way that
changes the shape rather than the size. Answer it on the throwaway probe, which already
runs on all three platforms and already has a popup.

**Do:** add focal-post selection to the probe, split the way it will ship (§ T3):
`readPostCandidates()` reads the DOM and returns
`{ viewport, candidates: [{ postId, top, bottom, area }] }`; `chooseFocalPost(reading)` is
pure. Have the popup report the chosen post id and its media URL. Scroll a feed, open the
popup at **~30 unplanned positions per platform**, and record whether the chosen post is the
one visibly centred.

**Serialize every observation.** `{ platform, viewport, candidates, chosen, humanVerdict }`
into `extension/test/fixtures/`. This is the point of the exercise as much as the hit rate
is: T3 needs a fixture corpus, these ninety observations are the only realistic mobile feed
geometry anyone will cheaply have, and hand-authored geometry encodes what we *think* a
feed looks like — the defect `drift-check.js`'s header describes at length about Instagram's
composed fixture (11–13 keys per media where the live API sends 108–128). Re-capturable
wholesale, on the `-live.json` discipline that file already uses.

**Four more things ride this session, because the phone is already in hand:**

- **The DOM-sufficiency gate for § D5.** With no hook, `harvestSignals` + the extractors are
  the only provenance source. Record, per platform, whether they yield a correct `mediaUrl`
  and provenance for the chosen post. This is what makes dropping the hook a reading rather
  than an optimism.
- **The permission behaviour for § D8.** Confirm `browser.scripting.executeScript` injects
  into an already-open tab on iOS. If it does, risk 2 is the narrow one; if it does not, the
  reload warning is real and stays.
- **Instagram at all**, which 095 § 9.1 left unverified and which no longer needs to be a
  hook question.
- **The permalink shape, per platform.**
  [432](../.change-log/432-the-tweet-with-only-an-analytics-link.md) found X handing back
  `…/status/{id}/analytics` as a post's only link and normalized it, because 18A dedup keys
  on `originalURL`. Instagram (`/p/{code}/liked_by/`) and Pinterest (`/pin/{id}/feedback/`)
  have the same shape available and were left alone deliberately — reasoned about, never
  observed. The probe's provenance panel shows `originalURL` for the chosen post, so this
  is read off the screen rather than inferred, and then fixed for whatever is real.

**The probe.** `extension/src/probe.html` + `src/probe.js`, with
`extension/manifest.probe.json` beside the shipping manifest. It imports the REAL modules
(`safari/focal-post.js`, `harvest.js`, `extractors/registry.js`), so what it measures is
what will ship, and it answers all four riders plus the hit rate on one screen. The page
lives inside `src/` rather than a sibling `probe/` root because an extension resolves module
imports against its root — a `probe/` root could only reach the modules by copying them, and
an unchecked mirror is the failure 404 exists to prevent. It is deleted when T0 is answered;
the modules stay.

**Verify:** two bars, doing two different jobs.

- **The design gate, live: ≥27/30 on each platform**, with misses adjacent-only (an
  adjacent post), never something off-screen.
- **The regression gate, forever: 100% of the captured corpus**, in CI, from T3 onward.

The first says whether D1 survives; the second says whether it stays true. Naming both in
advance is the point — ≥18/20, the first draft's bar, is a point estimate whose interval
runs from about 68% to 97%, and a true rate of 70% would invalidate D1 while passing.

**If it fails:** D1 is wrong. Revisit candidate 2 with the maintenance cost accepted, or
narrow tier 3 to post pages only — where there is no ambiguity — and let feeds stay tier 2.

**~1.5 days.** No target, no provisioning.

## T1 — the Safari Web Extension target

**Do:** a fifth target in `AtelierRefs.xcodeproj`, hand-written rather than converter-
generated — [400](../.change-log/400-the-pen-changed-hands.md) established that Xcode's
target sheets fight this project, and 094 § 1 records the converter emitting a bundle
identifier that cannot build. The converter's output is a reference, not the source of
truth.

The target's Resources reference `extension/src/` per D3, plus a Safari `manifest.json`
that lives beside them (`extension/manifest.safari.json`) so the two manifests are diffable
against each other. Per § D5 it declares **no content scripts at all** — the whole
`content_scripts` array and `web_accessible_resources` are gone, which is most of what made
this row paperwork.

**Verify:** it builds; the extension appears in Safari's settings on a simulator; the popup
opens on x.com and `readPostCandidates` returns candidates.

**And extend the drift check, behaviourally.** Parse `host_permissions` from both manifests
and assert **every extractor / media-host domain is covered by a pattern in each** — same
subdomain semantics as `swiftPlatformFor`, with a named exception list for `127.0.0.1` and
the dropped bulk hosts. It goes in `host-table.js` beside the invariant it extends, where
the fixtures already are, and it closes the pre-existing `manifest.json:7` gap in the same
motion. **Not** manifest-vs-manifest set equality, for the reason `host-table.js:19` gives.

**~3–3.5 days** — a day off for the content scripts that are no longer there, half a day on
for the check.

## T2 — the native seam

**Do:** `SafariWebExtensionHandler` receives a `CaptureRequest`-shaped JSON plus a media
URL, runs it through `AtelierCapture.CaptureDecoder` — the same funnel the share extension
and the Mac endpoint both use — fetches the URL with `URLSession.downloadTask` under
§ D6's guards and cap, and writes through `InboxWriter`. Everything downstream already
exists and is measured.

**Don't** put bytes in the message. 095 § 5 is the record of why, including the number
(2.36× payload, 80 MB ceiling, killed at 32 MB).

**Extract the message boundary, and host-test it.** `beginRequest(with:)` reaches into
`context.inputItems`, casts to `NSExtensionItem`, reads `userInfo`, pulls
`SFExtensionMessageKey`, and turns whatever that is into a `CaptureRequest`. Every step has
a failure mode — key absent, value not a dictionary, malformed JSON, media URL missing or
unparseable, payload over cap — and none of them need a device. So:

```
parseNativeMessage(_ userInfo: [AnyHashable: Any]) → Result<NativeCaptureMessage, NativeMessageError>
```

lives in `AtelierCapture`, and the handler does I/O only. The error enum mirrors
`CaptureDecodeError`'s shape, whose own tests already enumerate `.malformedJSON`,
`.invalidBase64`, `.unknownPlatform`, `.unknownKind`, `.missingContentPayload` — this is the
same layer one step up, and it is the layer where an `as?` cast fails silently. It also
makes `native-unreachable` distinguishable from "the handler ran and rejected you", which
§ D8's popup otherwise cannot tell apart.

**Assert the dedup equivalence here, not in T4.** A tier-3 record goes JS provenance →
native → `InboxWriter`; a desktop record goes JS provenance → HTTP → server ingest. That
those two converge is the plan's most important invariant, and T4 proves it by hand on a
phone at the end, which is the worst place for it. One `AtelierCaptureTests` case — a
fixture `CaptureRequest` plus bytes through both paths, asserting identical identity and
provenance — runs in CI on every commit. `CaptureFixtures.swift` already exists for exactly
this. T4's device pass stays, and confirms rather than discovers.

**Cover the return leg.** `InboxWriterTests` exhausts the write side but asserts only that
the filesystem ends correct. Tier 3 adds a path where a failure has to travel *back* —
native → JS → popup — and nothing tests it. Two exhaustive switches over one shared string
enum: a Swift case asserting every `InboxWriteError` maps to a distinct reportable code, and
a JS case asserting `capture-view.js` renders every code. A new error case then fails the
build rather than reaching a user as a blank popup. The forcing function is the point: it
makes someone decide what the user sees when the inbox is unwritable.

**The footprint, mitigated and not merely logged.** 095 § 5's side effect is that **the
handler process is reused between messages and does not reclaim promptly**. At ~3 MB each
against an 80 MB ceiling that is **about 26 captures** — one evening of saving pins, which
is exactly the behaviour tier 3 exists to make easy. So carry 423's `bytes=` / `footprint=`
logging *and* narrow the accumulation:

- `configuration.urlCache = nil` and `requestCachePolicy = .reloadIgnoringLocalCacheData`
  — `URLSessionConfiguration.ephemeral` carries an in-memory `URLCache` by default, which is
  invisible in a two-second share extension and is a per-capture allocation here;
- one session for the handler's lifetime, not one per message (`ShareViewController.swift:546`
  builds a fresh one per call);
- an `autoreleasepool` around fetch-and-write.

**Then measure it: 30 sequential captures, footprint logged each.** N=30 is chosen to
*cross* the 26-capture estimate, so the run either shows a flat line or shows the wall. The
log line is the instrument; these are the mitigation.

**Verify:** the decode, parse, write and equivalence halves are `AtelierCapture` and run
under `swift test`. What needs the device is one round trip and the burst.

**~5–6 days.**

## T2.5 — `capture-plan.js`, and the Safari tree

**Do:** § D7's extraction. `extension/src/capture-plan.js` takes the decision out of
`captureCore` / `ingestOne`; `sw.js` imports it and keeps its glue, so the desktop path is
unchanged behaviour with `sw.test.js`'s forty cases still covering it. Create
`extension/src/safari/` — `worker.js`, `popup.html`, `popup.js`, `capture-view.js` —
importing `capture-plan.js`, `harvest.js` and `extractors/` and **nothing** from `sw.js`.

**And § D6's JS half:** `isAllowedMediaHost` runs inside `planCapture`, so a URL on a host
no extractor vouches for never reaches the native side.

**Verify:** `node --test`. `planCapture` is plain objects in, plain object out — the video
branch, the text-card branch, the candidate ordering and the allowlist refusal are all
assertable without a browser.

**~1.5–2 days.**

## T3 — the trigger

**Do:** the popup. T0's focal-post selection promoted out of the probe into
`extension/src/safari/`, keeping the split T0 already used — `readPostCandidates()` in the
page, `chooseFocalPost(reading)` pure. The extractors run against the chosen post to build
provenance, `planCapture` decides, the worker messages native.

**The pure half takes numbers, not a DOM.** The first draft said "a DOM fixture in, a post
id out — the way `harvest.js` splits page-reading from deciding", but that is not the split
`harvest.js` makes: `harvestSignals()` returns **plain values** and `harvest.test.js:14`
builds them with a `raw()` helper, no DOM anywhere. A DOM fixture would mean `vm` plus a
hand-rolled stub — the `ios-preprocessor.test.js` route, which exists only because that file
is not importable, and whose own header (`:18`) warns that a drifting stub is the hazard.
`chooseFocalPost` has no such constraint, so it takes `{ viewport, candidates }`, which is
exactly what T0 serialized.

**Verify:** the pure half under `node --test` against T0's corpus at 100%, plus the edge
cases the geometry rule actually has — a post taller than the viewport, two posts split
exactly at centre, a post partially behind a sticky header, zero candidates, a candidate
entirely off-screen. `capture-view.js` under `node --test`, exhaustive over § D8's status
set. The popup by hand on a device.

**~4.5–5 days.**

## T4 — end to end, per platform

**Do:** capture from a feed and from a post page, on x.com, instagram.com and
pinterest.com, and confirm the record reaches `inbox/`, drains on the Mac, and dedups
against the same post captured by the desktop extension — which is the real proof that the
two producers still speak one contract.

**Verify:** the dedup, on the device, against the CI assertion T2 already made. If a tier-3
phone capture and a desktop capture of the same post produce two assets rather than one, the
provenance forked, and that is the failure 092 · S0 exists to prevent. A CI test that passed
while the device forks is itself a finding — it means the equivalence test is testing the
wrong thing.

**~3 days**, device-bound — shorter than the first draft's estimate because the dedup
question arrives here already answered.

## T5 — retire tier 2 on the three sites (§ D4b)

**Only after T4 has passed on all three platforms, on a device.** Until then tier 2 is the
working path and tier 3 is unproven; removing the first before the second is demonstrated
would be trading a capture that works for one that is supposed to.

**Do:** delete `PageExtractor.twitter`, `.pinterest`, `.instagram` and the per-platform half
of `PageExtractorTests`. Delete `extension/test/fixtures/media-rewrite-contract.json` and both
suites' readers of it *in the same commit* — the fixture gates rules that only exist in the
branches being removed, and a contract left behind to pass vacuously is worse than no
contract, because it looks like coverage.

**Don't:** touch `PageExtractor.web`, `PageHarvest`, `PagePreprocessor.js`, `ShareCapture`,
`host-table.js`'s check, or the activation rule. Tier 2 remains the path for every site tier
3 does not name, which is most of them.

**Verify:** a share-sheet capture of an x.com page still lands a record — as `web`
provenance with og-tags, which is the honest tier-2 answer once the special case is gone —
and `Tier2ShareUITests` still passes on its localhost fixture, which never exercised the
per-platform branches anyway.

**~0.5–1 day.** It is a deletion, and the tests that go with it were written knowing this
day was coming.

---

## Sizing

| | first draft | revised | |
|---|---:|---:|---|
| T0 — focal-post gate | 1 day | **1.5 days** | fixture corpus, n=30, three riders |
| T1 — the target | 3–4 | **3–3.5** | −1 for the dropped content scripts, +0.5 for the manifest check |
| T2 — the native seam | 3–4 | **5–6** | `parseNativeMessage`, equivalence + return-leg tests, footprint mitigation + burst |
| T2.5 — `capture-plan.js` + `safari/` | — | **1.5–2** | new |
| T3 — the trigger | 4–5 | **4.5–5** | `capture-view.js` in, DOM stub out |
| T4 — end to end, three platforms | 3–4 | **3** | dedup arrives answered |
| T5 — retire tier 2 on the three sites | — | **0.5–1** | § D4b, new |
| **total** | **~3 weeks** | **~4–5 weeks** | |

Against 091's "+4–6 weeks, gated". The bytes seam was priced as an unknown with a spike in
front of it, and it is a `URLSession.downloadTask` into code that already exists — that is
still the reason this fits. The half-week the review adds is almost entirely T2, and almost
entirely the conversion of "what needs the device is the message boundary itself" into
things `swift test` runs.

## Gates and risks

1. **T0's hit rate.** The only gate that can change the plan's shape. It is first for that
   reason, and it now carries two bars (§ T0): ≥27/30 live to pass the design, 100% of the
   captured corpus to keep it passing.
2. **T0's DOM-sufficiency reading.** § D5 drops the hook on the argument that nothing
   consumes it, which makes `harvestSignals` + the extractors the sole provenance source.
   If they are thin on a mobile feed, the hook comes back at 3–5 days. This is the second
   thing that can change shape, and it is answered in the same session as the first.
3. **Per-site permission.** 094 § 7.4, and it bit the spike twice. **The severe form of
   this was a `document_start` problem** — an extension enabled while sitting on a feed
   injected retroactively and `document_start` never happened — and § D5 removes every
   `document_start` script. What should remain is the narrower case: permission has to be
   granted, and the popup must distinguish "not granted" from "nothing here to capture"
   (§ D8's `permission-not-granted`). T0 confirms which of the two this is; a warning about
   a failure that cannot occur teaches people to dismiss warnings, including real ones.
4. **App Store review.** Still worth knowing before T1 rather than after T4, but § D5
   changes the conversation: an extension that reads the DOM on a user gesture is a
   different submission from one that wraps `fetch`/`XHR` at `document_start` on three
   named sites.
5. **Video is easier here, not harder.** The desktop extension rasterizes a frame because a
   video post has no still on the server; under 095 § 7 the native side downloads the video
   variant to a file at the same flat cost as an image. The constraint that shaped the
   desktop design does not apply. Note the resolution path needs no hook either —
   `twitter-video.js` uses the unauthenticated syndication endpoint.

## Start here

T0. It is a day and a half, it runs on a probe that already exists, and it is the only
thing in this plan that could still say the design is wrong — now in two ways rather than
one, and both answered in the same session with the same phone.
