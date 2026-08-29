# 402 — a share becomes a record

Share a page from Safari on the phone, tap Atelier, and a `<uuid>.json` appears in the
App Group inbox with `platform: "pinterest"` and `capturedVia: "ios_share"` in it. Share
a photo and the record arrives with a `.bin` sidecar whose bytes are md5-identical to
the original. That is the whole of **S4b-ii**
([092](../.docs/092-ios-companion-plan.md) · S4b): the extension's actual capture
behaviour, drawn to [093](../.docs/093-ios-visual-design.md) § 1.

Everything under it was already built and proven —
[395](395-the-record-is-the-commit-marker.md) wrote the inbox contract,
[396](396-the-drain-owns-nothing.md) drains it,
[401](401-one-variable-eight-places.md) made `defaultRoot()` resolve a real shared
container on iOS. This is the top: the twenty lines that turn an `NSExtensionItem` into
the thing all of that was waiting for.

## Three decisions, and one of them is a refusal

**Tier 1 only.** A URL or image bytes out of the item provider, and nothing else. No
`NSExtensionJavaScriptPreprocessingFile`, no ported extractors, no DOM. A shared link
becomes a media-less `link` capture and the Mac fills its og-tags at drain time through
the existing `PageResolver`, which is exactly what 092 · S4b's tier-1 bullet describes.
Tier 2 is a later slice, and the shape it will want — richer provenance out of a
preprocessed dictionary — is a third `SharedItem` case, not a rewrite.

**URLs and images; the activation rule is the gate.** `NSExtensionActivationRule` was
`TRUEPREDICATE`, under which Atelier offered itself for every share on the phone —
plain text, a contact, a PDF — and would then have had nothing to do with them. It is
now a dictionary with `SupportsWebURLWithMaxCount` and `SupportsImageWithMaxCount`,
both 1, and every other key absent (omitted means zero/false). What the rule refuses,
the code does not have to fail politely at later: `harvest` has one "nothing
capturable" path and no per-type branching. Deliberately **not**
`SupportsWebPageWithMaxCount` — that key is the tier-2 trigger, the thing that makes
Safari run a JavaScript preprocessing file, and turning it on now would enable half a
feature.

An image's bytes go to the `.bin` sidecar and `CaptureRequest.image` is left nil.
That is 092 · S2's rule: the base64 field is the HTTP producer's path, bounded by the
server's body cap, and this producer has a file to write to.

**A principal class, not a storyboard.** `Base.lproj/MainInterface.storyboard` and the
`SLComposeServiceViewController` it instantiated are deleted;
`NSExtensionMainStoryboard` is replaced by `NSExtensionPrincipalClass` =
`$(PRODUCT_MODULE_NAME).ShareViewController`, a thin `UIViewController` hosting a
SwiftUI card. The compose sheet is a form with a text field and a Post button, and
093 § 1 decides post-and-dismiss with no form at all — so the template's whole premise
was wrong for this extension. It was also the only storyboard in a repo that is
SwiftUI throughout. The plist value is module-qualified because the class carries no
`@objc` name; the alternative was an ObjC-visibility attribute that exists only to
satisfy a plist.

## The mapping that must not become a `Platform` case

The URL's host picks a `Platform`, falling back to `.web`, and the *act* of sharing
from a phone is recorded as `rawMetadata.capturedVia = "ios_share"`. There is no
`iosShare` case and there must not be one: `platform` records which SITE content came
from, it persists as a string in SQLite, and a new case touches the migrator, every
filter and the archive contract. `clipboard` / `localPaste` / `localDrag` are the
existing exceptions and they are not a precedent worth extending.

The host table mirrors `extension/src/extractors/` domain for domain, because the
browser extension and the phone are two producers of one contract and a host that
means `twitter` in one of them cannot mean `web` in the other. Matching is `hostIs` —
equal to the domain or a subdomain of it — the same predicate
`extension/src/extractors/base.js:25` uses, which is why `evilx.com` is `.web` and
`mobile.twitter.com` is `.twitter`. The CDN domains (`twimg.com`, `pinimg.com`,
`cdninstagram.com`, `fbcdn.net`, `rednotecdn.com`) are in the table beside the page
domains on purpose: an image shared out of a browser carries the media URL, not the
page URL. An unrecognised host is `.web` and never a guess — the URL itself survives
verbatim in `originalURL`, so declining to classify loses nothing.

**A trap found on the way.** `LinkPayload.canonicalURL` decides a string is scheme-less
by looking for `://`, so `mailto:a@x.com` becomes `https://mailto:a@x.com`, which
parses cleanly with `mailto:a` as userinfo and **`x.com` as the host** — an email
address that would have been filed as twitter provenance. `ShareCapture.platform`
rejects a foreign scheme before it canonicalises anything. The activation rule means
such a string should never arrive, which is precisely why the guard is worth keeping:
the case that cannot happen is the one nobody notices going wrong. The same trap is
live in `AddLinkForm` on the Mac, where a user types the string; that is not this
slice's to fix, but it is now written down.

## The extension has no test host, so it has no decisions

The extension target has no test host and this slice did not invent one — that is a
bigger decision than a share sheet. That is only defensible if the extension contains
nothing worth testing, so the bargain is explicit and the file's header states it:
everything decidable from values lives in `AtelierCapture/ShareCapture.swift` and is
tested under `swift test` on macOS with no device and no simulator.

What went into the package: the `SharedItem` seam (what the share held, with every
Cocoa type gone), the host → `Platform` table, the `capturedVia` stamp, and the whole
`SharedItem` → `ShareCaptureDraft` construction including the request/payload pairing.
Sixteen new tests, over a matrix of fifteen mapped hosts, six lookalikes, seven
malformed strings, both draft shapes, and a round trip through both `CaptureDecoder`
funnels and `InboxWriter` itself.

What stayed in `ShareViewController`: pulling values out of `NSItemProvider`, which is
asynchronous and Cocoa; resolving the App Group root, which needs this bundle's own
Info.plist; hosting a view and completing the `NSExtensionContext`. Nothing there
branches on a host, a scheme or a kind. If a future change wants to, it belongs one
file over.

Two of the tests are negative and are the ones that matter. `evilx.com` must not be
twitter — a `contains` match would have made every lookalike domain a false positive
that lands in the library as real provenance. And an image capture must leave
`CaptureRequest.image` nil: the moment that field gets filled on this path, the sidecar
is carrying the bytes twice and the extension is holding a base64 string of a 4000px
photo, which is the failure 092 · S2 was designed around.

## The card, and the tokens it had to copy

`Theme.swift` is a macOS app-target file — it `import AppKit`, mirrors every colour
into an `NSColor` twin and extends `CALayer` — so it cannot compile for iOS at all, and
an app extension cannot import its host app's target either way. What crosses is
therefore the VALUES, hand-copied into `ShareTheme` with the `Theme.swift` line each
came from, so the copy is checkable against its source rather than merely plausible.
The rule `Theme.NS` states for its own AppKit mirrors governs this copy too — *a mirror
with no reader is a second copy waiting to drift* — so nothing is restated
speculatively: six colours, three geometry constants, two animations, two font roles,
exactly what one card draws.

Success is `ToastCard`'s recipe (`ToastHost.swift:105`–`:151`) with the buttons
removed: `surface` on a `hairline` border at `Radius.card`, lifted by
`Elevation.hover`, the message in `Typography.body`, in on `Motion.toast` and out on
`Motion.gentle`. It says **"Saved to Unsorted"**, naming the destination the way the
Mac's capture toast does, because the collection is the one fact the user cannot
otherwise discover.

Failure is the same geometry with the message in `warning`, and it does not
auto-dismiss — 093 collapses `InboxWriteError`'s four cases into one card because every
one is a lost capture and none leaves anything partial. It carries the toast's ✕, which
is dismissal and not retry: there is no retry button, because every failure this
collapses is a container- or filesystem-level condition a second attempt would hit
again, and re-sharing is the retry the user already knows. `completeRequest` fires when
the user dismisses; `cancelRequest(withError:)` is never used, on either path, because
a system-presented extension failure reads as a crash rather than as "that one didn't
save".

## Where 093 turned out to be optimistic, and what it did not say

Three things, none of them silent divergences.

**The backdrop is not clear, and cannot be from here.** 093 § 1 asks for the card to
sit "over a clear backdrop so the host app stays visible behind it — the card is a
receipt, not a screen." The view and its hosting controller are both `.clear`, and the
host app still does not show through: the system presents a share extension inside its
own opaque container, which slides up over the host as a dark sheet (visible mid-animation
in the capture below). The card still reads as a receipt — it is one line at the bottom
of an otherwise empty surface, and it is gone in about a second — but the specific
visual 093 describes is not reachable without going after the extension host's
presentation, which is not a share-sheet decision worth making blind.

**A share with nothing in it needed a card 093 does not enumerate.** If neither a web
URL nor image bytes come out of the item providers there is nothing to write. The
activation rule should make it unreachable; it is folded into the same failure card on
093's own grounds — it is a lost capture and it leaves nothing partial.

**`LibraryLocationError` renders here too.** 093 § 7 flags a missing App Group container
as "the one hole worth closing early in S4b" — 092 · S1 · decision 3 made it a typed
fatal error precisely so a provisioning bug fails where it is fixable, and nothing
rendered it. The failure card now covers `LibraryLocationError`'s two cases alongside
`InboxWriteError`'s four. Six typed errors, one card, and the typed payloads (`path:`,
`id:`) stay in the log where that vocabulary belongs.

One thing 093 leaves open is left open: **how long the confirmation card stays.** 093's
open question 2 rules out the Mac's 6 s toast TTL as far too long for a process whose
job is to get out of the way, and says something under a second is the right order.
`ShareViewController.successDismissDelay` is **0.8 s**, plus a 0.15 s removal animation
— roughly 0.95 s on screen. It is a defensible point in the stated range and nothing
more; it is a single named constant, and it is the user's to settle on a device.

## What ran on a simulator, and what did not

The deliverable is not the build. Both cases were driven through the **real share
sheet** on a booted iPhone 17 Pro (iOS 26.5) with the Debug build installed, which
resolves `group.sujenphea.AtelierRefs.dev`:

**A link.** Safari on `https://www.pinterest.com/` → ⋯ → Share → AtelierRefsMobile. The
"Saved to Unsorted" card appeared, the sheet dismissed itself, and the container held:

    {
      "attempts": 0,
      "capturedAt": 1786697876.388114,
      "id": "DC9E5E38-F1F6-4D2E-B9C8-65CCC3895AFA",
      "request": {
        "kind": "link",
        "payload": { "link": { "url": "https://www.pinterest.com/" } },
        "provenance": {
          "originalURL": "https://www.pinterest.com/",
          "platform": "pinterest",
          "rawMetadata": { "capturedVia": "ios_share" }
        }
      }
    }

No `payloadFile`, no `image`, `.staging/` empty. The host mapping ran in the extension's
own process, on a host Safari supplied.

**An image.** A 600×400 PNG added with `simctl addmedia`, opened in Photos, shared to
the extension. The record names its sidecar and the sidecar is the original file:

    479A29C6-EF1C-4913-876A-CFC7A2F6EE00.json   { "payloadFile": "479A29C6-….bin",
                                                  "provenance": { "platform": "web",
                                                    "rawMetadata": { "capturedVia": "ios_share" } } }
    479A29C6-EF1C-4913-876A-CFC7A2F6EE00.bin    202438 bytes, PNG 600×400 RGBA,
                                                md5 identical to the source file

`platform: "web"` is correct: Photos supplies no source URL, so there is no host to
map. The byte-for-byte match is the load-bearing part — it proves
`loadDataRepresentation` handed over the original file and nothing in this process
decoded or re-encoded a bitmap.

**What was not exercised.** A failure card: producing one needs the App Group container
to be broken, which is not a state a simulator offers on demand, so all six error cases
are covered only by the writer's own test matrix (395) and by the type system. The
`title` pass-through: neither Safari nor Photos supplied an `attributedTitle`, so that
field arrived nil both times and only the unit test covers it. And **the ~120 MB
footprint measurement is still not done** — it is a 092 gate in its own right and it
wants Instruments and a large share, not a 200 KB PNG.

**The automation was miserable and it is worth recording why.** There is no XCUITest
host here and this slice must not create one, so the share sheet was driven with
synthetic `CGEvent` clicks mapped through the Simulator window's accessibility
geometry. Two failure modes cost most of the time. The Simulator's AX window
disappears from the tree every few minutes, after which every tap reports "no device
view found" and the only reliable recovery is `killall
com.apple.CoreSimulator.CoreSimulatorService` and a fresh boot. And an inactive
Simulator window swallows the first click as an activating click, so each tap now
clicks the window's toolbar first and the device screen second. Both records above were
captured inside the couple of minutes of working input that follow a service restart.
Anyone repeating this should expect to restart the service, not to debug their
coordinates.

## Files

    AtelierCapture/Sources/AtelierCapture/       new — `SharedItem`, `ShareCaptureDraft`,
      ShareCapture.swift                         the host→Platform table, the capturedVia
                                                 stamp, and the draft construction. Pure,
                                                 Foundation + AtelierCore only
    AtelierCapture/Tests/AtelierCaptureTests/    new — 16 tests: the host matrix, the
      ShareCaptureTests.swift                    lookalikes, malformed/scheme-less/absent
                                                 URLs, both draft shapes, and a round trip
                                                 through both decode funnels and InboxWriter
    AtelierRefs/AtelierRefsShare/                template `SLComposeServiceViewController`
      ShareViewController.swift                  replaced: harvest → draft → InboxWriter →
                                                 card → completeRequest. Only what needs
                                                 UIKit and NSExtensionContext
    AtelierRefs/AtelierRefsShare/                new — the confirmation and failure cards,
      ShareCard.swift                            plus `ShareTheme`, the hand-copied token
                                                 values with their Theme.swift citations
    AtelierRefs/AtelierRefsShare/Info.plist      NSExtensionMainStoryboard → NSExtensionPrincipalClass;
                                                 activation rule TRUEPREDICATE → web URLs +
                                                 images; UIUserInterfaceStyle = Dark (093 § 6)
    AtelierRefs/AtelierRefsShare/                deleted — the only storyboard in the repo
      Base.lproj/MainInterface.storyboard
    .docs/092-ios-companion-plan.md              S4b amended with an "As built" note for
                                                 S4b-ii; "Where this stands" updated

No `project.pbxproj` change: both new Swift files land through the target's existing
`PBXFileSystemSynchronizedRootGroup`, and deleting the storyboard removes it from the
build the same way.

## Verification

| | |
|---|---|
| macOS app | `xcodebuild build`, `platform=macOS` — **BUILD SUCCEEDED** |
| iOS Debug | `xcodebuild build`, `generic/platform=iOS Simulator` — **BUILD SUCCEEDED** |
| iOS Release | same — **BUILD SUCCEEDED** |
| `AtelierCore` | 760 / 105 — unchanged |
| `AtelierCapture` | **73 / 4** — was 57 / 3 |
| `AtelierIngestion` | 447 / 47 — unchanged, no tie-break flake this run |
| `AtelierServer` | 62 / 6 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| Link share, real share sheet | record written, `platform: "pinterest"`, dumped above |
| Image share, real share sheet | record + sidecar, bytes md5-identical to the source |

## Migration notes

None for users; nothing ships on iOS yet, and no macOS file was opened.

For anyone with a branch open: `AtelierRefsShare/Base.lproj/MainInterface.storyboard` is
**deleted**, and a merge that restores it while keeping the new Info.plist leaves a
storyboard nothing loads — harmless, but it is dead weight in a repo that now has none.
The reverse is the dangerous one: keeping the old Info.plist and the new
`ShareViewController` gives a build that succeeds, installs, appears in the share sheet
and then crashes on launch, because `NSExtensionMainStoryboard` names a storyboard whose
`ShareViewController` is no longer an `SLComposeServiceViewController`.

The activation rule is now the single authority on what Atelier is offered for. Adding a
type — text, a file, a video — means adding its key here **and** a `SharedItem` case
**and** a branch in `harvest`; the first one alone produces a share that lands on the
"nothing capturable" failure card, which is a correct outcome and a confusing one.

`ShareCapture.hostPlatforms` is where a new site's domains go, and the browser
extension's `extension/src/extractors/` is the reference it must keep agreeing with.
A host added on one side and not the other does not fail a build or a test; it forks
provenance, and 18A dedup keys on provenance, so what it produces is two assets where
there should be one.
