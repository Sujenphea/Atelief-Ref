# 461 — the wall around a page-chosen URL

[098](../.docs/098-ios-companion-completion-plan.md) · **P5**: findings 2 (the fetch half),
7, and the preprocessor caps. The phase that touches nothing but the share extension, the
package it links, and the JavaScript Safari runs inside somebody else's page.

Two things happened in it, and they are the same thing at two altitudes.

**Tier 2 downloads a URL that a web page chose.** That is not a side effect of the feature,
it is the feature: the pages tier 2 exists for are the ones the user is signed in to and a
cookie-less Mac cannot see, so "attacker-influenceable" is the definition of its input
rather than a hypothetical about it. The Mac has walled the identical fetch since
[001 · C2b](../.docs/001-foundation-overview.md) — `SSRFGuard`, injectable DNS, per-hop validation,
a tested matrix. The phone had a scheme filter, `URLSession`'s automatic redirect following,
and a size check that ran after the entire body had already landed on disk. Underneath a
comment that said it ran before.

**And `PagePreprocessor.js` had one cap out of five.** `images` was bounded at 80. `videos`
and `metas` were not bounded at all, no string had a length, and a `data:` src — which is
not a reference to bytes but the bytes themselves — was filtered only in Swift, on the far
side of the XPC boundary the cap exists to protect. A page with eighty inline base64 images
shipped megabytes into a ~120 MB process so that Swift could discard them on arrival.

Both are the same sentence: a value a page controls was reaching a place where its size and
its destination were nobody's decision. The other half of this phase is the file that
stopped doing five jobs.

## The file that stopped doing five jobs

`ShareViewController.swift` was 848 lines: lifecycle and hosting, capture orchestration,
provider harvesting, tier-2 page loading with two routes and their diagnostics, footprint
instrumentation, and a media fetch with a budget. 098 · finding 7's own recommendation was
that the split is mechanical, because everything past the first two was already `static`.
It was, and it is one commit on its own so the six fixes after it are readable:

| | |
| --- | --- |
| `PageSnapshotLoader` | the plist attachment, both load routes, `diagnose` |
| `ProviderPayloads` | the item-provider reads, and `adopt` / `discardAdoptedFile` |
| `MediaFetcher` | the one socket the extension opens, and its budget |
| `ShareLog` | the logger the four of them share |
| `ShareViewController` | 388 lines: `viewDidLoad`, `capture`, `harvest`, the receipt |

(388 at the split; 465 once the six fixes below arrived with their reasons written down.)

`ShareLog` is the part that was not in the plan and had to be. The logger was a `private
static let` on the controller, and a split that left it there would have produced either a
second `Logger` in a process whose entire diagnostic story is the unified log, or three
files reaching into a fourth's private state. It is `MobileLog` at the size an extension
needs it.

The one behaviour the split changed, and it is worth naming because nothing asked for it: a
`static` member of a `@MainActor` class inherits that isolation, so the media fetch and
every provider read had been hopping to the main actor to `await`. The three namespaces are
`nonisolated`, so they no longer do.

`adopt` stayed with `ProviderPayloads` rather than becoming a fourth type. `MediaFetcher`
borrows it, which reads oddly for one line and is right: the downloaded file and the
provider's temporary file are the same problem — a file this process must own before the
system reclaims it — and the existing doc comment already said so.

## Six gaps, and the one that changes what a share means

098 · finding 7 listed seven. Six are here; the seventh is the false comment, which is
fixed by making it true and belongs to the section below.

**`loadData` dropped its error.** `{ data, _ in }`, on the LAST route to an image's bytes,
in a file whose stated rule is that the vocabulary lands in the log or nowhere. What the
user saw when it fired was `harvest` resolving to something else, with no line anywhere
saying the photo had been asked for and refused.

**A photo share that saves a link says "Saved to Unsorted".** Both byte routes fail, a web
URL is beside them, `ShareCapture.resolution` correctly falls back to `.link` — and nothing
on the phone distinguishes the photo that saved from the photo that became its URL.

It logs at `.error` now, naming the type identifiers that were offered and the refusal if
there was one. **It does not show the failure card, and that is the decision.** The capture
is real and durable and carries the media URL as its `originalURL`, so the Mac resolves the
picture at import; a failure card would claim a loss that did not happen and would leave the
user re-sharing a photo already sitting in the inbox. What the card cannot yet say — *saved
as a link* — is a third card, and a third card is 093's decision to take, not this file's.

**A refused download leaked its temp file.** The two size/status refusals removed it and the
`adopt` path did not, so the one case where the file is *big* was the case left behind. One
`defer`, which is the only spelling a future early return cannot forget.

**Page text, titles and chosen media URLs were logged `privacy: .public`.** `describe(items)`
carried `attributedContentText` and every `attributedTitle` — a page's title, a message's
compose text, and on some hosts the shared URL complete with whatever is in its userinfo —
and `pageCapture` logged the two media URLs the extractor picked, which on the sites tier 2
is for are signed CDN URLs with a post id in them. `.public` in os_log means legible to
anyone who opens the unified log on that phone or takes a sysdiagnose off it.

The split is at the line the annotation is for. Counts, kinds, article indices and type
identifiers stay `.public` — they are the entire diagnostic value, and the three
investigations that made these lines exist all ended at *which items did Safari send*.
Content is `.private`, which redacts without removing the field: the person debugging their
own device can still read it, a log dump cannot.

**`footprint()` ran in Release.** Two mach syscalls on every successful share, for gate 2,
which [092:1025-1050](../.docs/092-ios-companion-plan.md) discharged — a 16.3 MB payload
cost 0.2 MB of footprint. It stays under `#if DEBUG`, because the regression check is still
why it was written: pull decoding back into this process and a debug share says so at once.

**Two hand-spelled bundle ids.** `"sujenphea.AtelierRefsMobile.Share"` in the extension and
`"sujenphea.AtelierRefsMobile"` as `MobileLog.subsystem` in the phone app: two literals, in
two targets, describing one `PRODUCT_BUNDLE_IDENTIFIER`. The failure is the quiet one —
rename the setting and nothing breaks, nothing warns, and both processes start logging under
subsystems that no longer exist, so a `log stream` filter returns nothing and reads as *the
extension never ran*.

`CompanionBundle` in `AtelierCapture` is the one spelling, and it is **checked against the
build**: `CompanionBundleTests` reads `PRODUCT_BUNDLE_IDENTIFIER` back out of
`project.pbxproj` and compares. A constant claiming to mirror a build setting with no way to
notice when it stops is the thing the constant was introduced to remove. The extension reads
it; `MobileLog` is in a target this phase may not edit and is P6's.

## The wall

Three decisions, and all three are pure functions in `AtelierCapture` because the share
extension has no test host. That is a settled constraint of this project, and the bargain it
buys is only defensible if the extension holds no decisions — so the decisions left it.

```swift
ShareCapture.fetchableURL(for:through:)      // may this candidate be requested
ShareCapture.redirectTarget(from:to:through:) // may this hop be followed
ShareCapture.acceptsFetched(length:status:)   // may this body transfer
```

One refusal vocabulary, `MediaFetchRefusal`, because all three answer one question and a
caller that logs three enums writes three sentences for one condition.

**The redirect is the half that matters most and reads as the least.** A wall that validates
only the first URL is not a wall: `https://cdn.example/a.jpg` resolving to a public address
says nothing about where its `302` points, and the classic shape of the attack is exactly
that — the initial host is the attacker's own and entirely public, and the interesting
address is the one it hands back. So `URLSession`'s automatic following is intercepted and
each `Location` goes back through the guard.

**The https→http downgrade is refused separately, and on different grounds.** A public http
host passes the SSRF guard cleanly; nothing about it is private. The objection is that the
media URL the page named was https, the user is on a phone on somebody's Wi-Fi, and a hop to
http is a picture fetched in the clear that anything on the path can replace. The other three
scheme transitions are allowed, and there is a case pinning that so "refuse the downgrade"
does not quietly become "refuse http".

**The size gate now runs on the headers**, which is what the comment above it always claimed.
`session.download(for:)` returns once the ENTIRE body has landed, so a page naming a 4 GB
file got a 4 GB file written into the container of a process with a ~120 MB budget and then
a tidy log line about the cap.

The glue is a session delegate. `willPerformHTTPRedirection` carries the hop decision;
`didWriteData` carries the size one, because `didReceive response` is a `URLSessionDataDelegate`
method and does not fire for a download task. So *before a byte is transferred* is honestly
*after the first chunk and before the rest* — which is the difference between refusing at
~16 KB and refusing at 4 GB, and the difference that matters here. **The real size is still
checked afterwards**, by `acceptsFetched` and again by `adopt`, because a server can lie or
send no length at all; that is also what makes the delegate safe to depend on. If the
callback ever stopped arriving the fetch would degrade to exactly what it did before this
change. The wall would get later, not thinner.

One wrinkle, recorded because it will be met again: Swift 6.3.3 crashes in SILGen emitting
the ObjC thunk for the **`async`** overload of `willPerformHTTPRedirection` under this
target's settings (`emitNativeToForeignThunk`). The completion-handler spelling is the same
callback and compiles. `PageResolver` uses the async one on macOS and is unaffected.

## The card that could not be acted on

`ShareCard` had two cases and one failure sentence — *"Couldn't save. Try sharing again."* —
for every typed failure `InboxWriter` and `LibraryLocation` throw. For a momentarily full
disk that is the right sentence. For a share over `InboxWriter.maximumPayloadBytes` it is
advice that cannot work: the same file meets the same cap and gets the same card.
[093 § 1](../.docs/093-ios-visual-design.md) recorded an 82 MiB share on a simulator, so it
is a line the user has already been shown.

`.failed(.generic)` / `.failed(.tooLarge)`, routed by `ShareCard.failed(for:)` so the two
catch sites cannot classify one error two ways. Neither line quotes the limit — a byte count
on a receipt is for the log, and the log has it twice already.

It is two cases and not six, and the split is on **what the user can do**, which is exactly
two things: try again, or send something smaller. That is also what reconciles the dismiss
button's doc comment, which argued there is no retry button because "a second attempt three
hundred milliseconds later hits again". That argument is true and it is precisely why
`.tooLarge` must not be told to share again. The doc and the copy now agree instead of one
contradicting the other.

## Five caps in the page

`PagePreprocessor.js` gains `MAX_VIDEOS` (20), `MAX_METAS` (100), `MAX_TEXT` (2048) on every
harvested string, a `data:` refusal in the page rather than only in Swift, and `MAX_SCAN`
(2000) so a DOM claiming a million `<img>` cannot make a share sheet spin on elements it will
never keep.

Two details that are decisions rather than numbers:

**The length is checked before the trim.** `trim()` on a five-megabyte base64 string copies
five megabytes to decide it is too long. The cost is that a value padded past the limit with
whitespace is dropped rather than trimmed into range, which is not a page anyone has.

**`document.location.href` is the one uncapped field.** Every other over-long value is
dropped, and dropping this one loses the whole capture rather than shortening it —
`PageHarvest.harvest(fromResults:)` returns nil without a URL, and `SupportsWebPage` means
Safari sends the page item *instead of* a URL item, so there is nothing to fall back to. It
is also one string rather than a repeated one, and the browser bounds its own address bar.

`data:` is dropped in **both** languages and both are wanted. Swift's is the tested rule for
the shape it decodes; the JS one is what keeps the bytes from crossing XPC at all, which is
the cost this file exists to avoid. It is not a general "this file dislikes a scheme" rule:
the case pinning `blob:` still surviving is right beside it, because a `blob:` URL is a short
string *naming* bytes and deciding whether it is fetchable is Swift's job, while a `data:`
URL *is* the bytes.

**The hostile-page risk is not closed, and the changelog says which half.** Safari runs this
file in the page's own JavaScript world: `document`, `Element.prototype.closest` and
`getAttribute` are the page's, and a page can replace all three. Nothing in the file can
prevent that — there is no isolated world to retreat to, and capturing references early only
captures whatever the page installed first. What the caps DO close is the consequence that
costs something: a lying DOM can still make the snapshot **wrong** (a borrowed article index,
a fake `naturalWidth`), which loses one capture, but it can no longer make it **unbounded**,
which loses the process. The veracity half stays open, deliberately and in writing.

The two-readers allowlist in `ios-preprocessor.test.js` grew a sixth documented divergence
and its equation grew the matching filter, so a seventh still fails there.

## Files changed

**The extension** (`AtelierRefs/AtelierRefsShare/`)

- `ShareViewController.swift` — 848 → 465 lines (388 at the split). Lifecycle, orchestration, `harvest`,
  `pageCapture`, `describe` (now two fields at two privacy levels), `footprint` under
  `#if DEBUG`, the silent-downgrade log, the card routing. Its header describes four files.
- `PageSnapshotLoader.swift` — **new.** The plist attachment, both routes, `diagnose`,
  `resultsDictionary`. Moved unchanged.
- `ProviderPayloads.swift` — **new.** `imageIdentifier`, `loadImage`, `loadFile`, `loadData`
  (now logging its error), `loadURL`, `adopt`, `discardAdoptedFile`.
- `MediaFetcher.swift` — **new.** The budget, the session, the walled fetch, and
  `RedirectWall`, the session delegate carrying the hop and size decisions.
- `ShareLog.swift` — **new.** One subsystem, one category, the fallback from
  `CompanionBundle`.
- `ShareCard.swift` — `.failed(Failure)`, `failed(for:)`, `isFailure`, the second message,
  a third `#Preview`.
- `PagePreprocessor.js` — the four new caps, the `data:` refusal, `src()` beside `text()`.

**The package** (`AtelierCapture/`)

- `MediaFetchPolicy.swift` — **new.** `MediaFetchRefusal` and the three predicates on
  `ShareCapture`.
- `CompanionBundle.swift` — **new.** The two identifiers.
- `ShareCapture.swift` — `mediaCandidates`' doc says what it is and is not (it is not the
  wall).
- `Tests/MediaFetchPolicyTests.swift` — **new**, 14 tests / 30 cases.
- `Tests/CompanionBundleTests.swift` — **new**, 3 tests.
- `Tests/PageExtractorTests.swift` — one test: a snapshot the caps stripped to a URL still
  classifies, and a partial one keeps what survived.

**The browser extension's suite** (`extension/test/`)

- `ios-preprocessor.test.js` — 13 → 26 tests. The count caps, the `data:` rule in both
  directions, the length cap at and past its boundary on `src` / `alt` / `content` / `title`
  / `canonical`, the uncapped URL, the scan bound over a `Proxy` claiming a million images,
  and the null discipline re-asserted over a page that trips every cap at once.

No `project.pbxproj` change: the extension already declared `AtelierCapture`,
`AtelierLibraryPaths` and `AtelierTokens`, the new files are picked up by the target's
`fileSystemSynchronizedGroups`, and nothing new is imported. Phase 4's rule needed nothing
doing here.

## Verification

Every number below was run on this tree.

| suite | before | after |
| --- | --- | --- |
| `AtelierCapture` | 172 | **190** |
| `extension` (`node --test`) | 616 pass / 3 skip / 0 fail | **629 pass / 3 skip / 0 fail** |
| `AtelierCore` | 786 | 786 |
| `AtelierBrowse` | 182 | 182 |
| `AtelierArchive` | 82 | 82 |
| `AtelierIngestion` | 517 | 517 |
| `AtelierLibraryPaths` | 32 | 32 |
| `AtelierTokens` | 9 | 9 |
| `AtelierServer` | 62 | 62 |

- iOS package builds, exactly as CI does, with `--sdk`: `AtelierCore`, `AtelierCapture`,
  `AtelierLibraryPaths`, `AtelierBrowse`, `AtelierArchive`, `AtelierTokens`,
  `AtelierIngestion` — all seven build for `arm64-apple-ios26.0`.
- `xcodebuild build` on `AtelierRefsShare` and on `AtelierRefsMobile`, generic iOS Simulator:
  both succeed, no warnings.
- `xcodebuild build-for-testing` on `AtelierRefsMobile`, `platform=iOS Simulator,name=iPhone 17`:
  succeeds.
- `xcodebuild test -scheme AtelierRefs -destination platform=macOS -only-testing:AtelierRefsTests`,
  run alone: **TEST SUCCEEDED**.
- `xcodebuild -list` after every write (there were no `pbxproj` writes; it was run anyway):
  five targets, unchanged.
- The built product: `AtelierRefsShare.appex`'s `CFBundleIdentifier` is
  `sujenphea.AtelierRefsMobile.Share`, which is what `CompanionBundle.shareExtension` says
  and what `CompanionBundleTests` asserts; `PagePreprocessor.js` ships into the appex
  byte-identical to the source, caps included.

## What is still NOT covered

**No share was driven.** `Tier2ShareUITests` is the only thing in the repository that can
put a real Safari on a real page and press Atelier, and it still cannot run: it fails at its
first line with `appGroupIdentifierMissing(key: "AtelierAppGroupIdentifier")` — the UI-test
bundle's own `Bundle.main` has no such key, and `LibraryLocation.defaultRoot()` reads
`Bundle.main`. That is P6's item, in a target this phase may not edit, and it failed before
Safari was ever launched. So nothing here is a claim about a share sheet. What was checked
instead is the built product, above.

**The `URLSession` glue is untested and says so in its own header.** Which delegate method
`URLSession` calls, and when, cannot be asserted without a test host this target does not
have. The three decisions the glue carries are table-tested; the hanging of them is not.
Two specific things are unverified on a device or a simulator: that `didWriteData` reaches a
session delegate for a task created by the async `download(for:)`, and that
`didFinishDownloadingTo` staying empty is harmless for the same task. Both degrade safely if
wrong — the post-download size check still refuses, and the file still arrives as the async
call's return value — but "degrades safely" is a reading of the API, not an observation.

**The DNS-rebinding hole is inherited, not closed.** `SSRFGuard` validates a host's
currently-resolved addresses and does not pin the socket to the address it validated. That
limitation is recorded in the guard's own header and is now the extension's too.

**The guard's resolution is synchronous and inside the fetch budget.** `getaddrinfo` on a
slow or hostile resolver spends the share's eight seconds. That is the right place for it to
be spent — a resolution that hangs is a share sheet that hangs either way — but it is time
tier 2 did not spend before, and no device number exists for it.

**`ShareCard.failed(for:)` is untested**, like everything in this target. The type it matches
on, `InboxWriteError`, is tested where it is thrown.

**A photo share that saves a link still says "Saved to Unsorted".** The log now names it at
`.error`; the receipt does not. That is the decision recorded above, and the third card is
undesigned.

**A hostile page can still lie to the preprocessor.** The caps bound the snapshot's size,
not its truthfulness. See above; it is not closable from inside the page's own world.

**`MobileLog.subsystem` is still a literal.** It is the other half of the bundle-id finding
and lives in `AtelierRefsMobile/MobileIngest.swift:43`, which P6 owns. `CompanionBundle.app`
is waiting for it.

## Migration notes

- **`ShareCard.failed` is now `ShareCard.failed(.generic)`.** Only the extension constructs
  it; both call sites moved. `card == .saved` became `card.isFailure` at the two places the
  view branched, so a third case cannot silently take the success styling.
- **`ShareCapture.mediaCandidates` is unchanged and is no longer sufficient on its own.** A
  caller that fetches its output without `ShareCapture.fetchableURL` has no wall. The doc
  comment says so at the function.
- **`MediaFetchRefusal` is a new public type in `AtelierCapture`**, and the three predicates
  are typed-throws. Nothing outside the extension calls them yet.
- **`CompanionBundleTests` reads `../AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj`
  relative to `#filePath`.** If the package is ever vendored on its own the file is absent
  and the two tests `#require` their way to a clear message rather than failing.
- **`footprint()` returns the empty string in Release.** A Release capture line therefore
  ends in a trailing space where a Debug one ends in `footprint=…MB headroom=…MB`. No parser
  reads it.
- **Nothing holds bytes.** `adopt` still copies file-to-file, `InboxWriter.stage` is
  untouched, and the walled fetch still streams to a temporary file it never reads.
