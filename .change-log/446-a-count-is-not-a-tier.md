# 446 — a count is not a tier

`Tier2ShareUITests` asserted that a share from Safari put one more capture in the inbox than
was there before, by reading the number off the app's own export control.

That is true whenever a capture landed. It is **also** true when tier 2 silently degraded to
tier 1 — a preprocessing script that threw, a plist boundary that broke the way
[422](422-the-null-that-could-not-cross.md) describes, a media fetch that failed. All three
produce a capture, increment the count, and mean the feature under test did not work.

422 is not a hypothetical: tier 2 shipped switched OFF for four days on a wrong belief about
why Safari's page item would not load. This test, as written, would have passed throughout.

## What separates the tiers is the record

Four assertions on the record that landed, replacing nothing — the count check stays as the
first of them:

| assertion | what its failure means |
|---|---|
| `originalURL` is the shared page | the record would fork an asset instead of colliding — 18A dedup keys on this |
| `authorName` is the page's `og:site_name` | **the DOM snapshot never reached the extractor** |
| `rawMetadata.capturedVia` is `ios_share` | the phone's stamp is missing |
| `payloadFile` is not nil | the media the page rendered was never fetched |

`authorName` is the load-bearing one, and picking it took a correction. The obvious choice
was the page TITLE — but Safari supplies the document title as the share item's
`attributedTitle`, so a tier-1 degrade of this very page still carries it. An assertion that
passes on the failure it exists to catch is worse than none. `og:site_name` lives only in the
DOM and reaches a record only through the preprocessing script.

`platform` is asserted too but is explicitly NOT the discriminator: the fixture is served
from `127.0.0.1`, so `web` is what both tiers record.

## The entitlement, and why a test target has one

The record is a file in the App Group container, and a test process without the entitlement
cannot see the container at all — `containerURL(forSecurityApplicationGroupIdentifier:)`
returns nil. `AtelierRefsMobileUITests` had its own bundle id and no entitlements file.

The alternative was a debug-only provenance surface in the app, built for one test and
shipped forever in the binary. This test's own header used to argue for the count on exactly
that ground, and the argument was right about the surface and wrong about the conclusion: an
entitlement on a target that never ships is the smaller cost, and it needs nothing added to
the product.

So the target now carries what the app and the extension carry, for the same reason and fed
from the same variable:

- `AtelierRefsMobileUITests.entitlements` — `$(ATELIER_APP_GROUP)`;
- `Info.plist` — `AtelierAppGroupIdentifier`, one key, a real file because
  [401](401-one-variable-eight-places.md)'s trap still holds: `INFOPLIST_KEY_<arbitrary>` is
  accepted by the build and silently dropped from the generated plist;
- `AtelierCapture` on its link line, so the record is decoded with
  `InboxRecord.makeDecoder()` — the decoder any reader of the inbox must use — rather than a
  hand-rolled parse that would let the two sides drift while both stayed green.

Read-only by discipline, not by entitlement: the runner enumerates and decodes and never
writes. The writer is the share extension, the drain is the Mac, and a test that wrote here
would be a third producer of a format two shipped binaries read.

## The pbxproj bit that went wrong first

`IA0000000000000000000006` — the next id in an obvious sequence — was **already taken**, by
the `PBXFileSystemSynchronizedBuildFileExceptionSet` for the AtelierRefsMobile folder. The
result was not a parse error (`plutil -lint` says OK) but `xcodebuild: error: Unable to read
project`, which names nothing. Renumbered to `…0008` / `…0009` after checking they were free.

The UI test folder is a synchronized root group and had no exception set, so the new
`Info.plist` would have been bundled as a resource. It now has the same one-entry exception
`AtelierRefsMobile` and `AtelierRefsShare` have.

## Files changed

- `AtelierRefs/AtelierRefsMobileUITests/AtelierRefsMobileUITests.entitlements` — new.
- `AtelierRefs/AtelierRefsMobileUITests/Info.plist` — new, one key.
- `AtelierRefs/AtelierRefsMobileUITests/Tier2ShareUITests.swift` — the record assertions,
  `inboxRecords()`, `fixtureSiteName` named once and used by both the HTML and the assertion,
  and a header that no longer claims the test cannot tell the tiers apart.
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — `ATELIER_APP_GROUP`,
  `CODE_SIGN_ENTITLEMENTS`, `INFOPLIST_FILE` on both UI-test configurations; `AtelierCapture`
  product dependency and Frameworks entry; the Info.plist exception set.

## Verification, and its limit

`xcodebuild build-for-testing -scheme AtelierRefsMobile` → **TEST BUILD SUCCEEDED**.
`AtelierRefsShare` builds. `AtelierRefsTests` on macOS passes.

**The test itself has not been run**, and cannot be here: it needs Safari on a simulator or
device, and it is excluded from CI for that reason. `CODE_SIGNING_ALLOWED=NO` also means the
build did not exercise the entitlement — it proves the target compiles and links, not that
the container resolves.

**Outstanding, and it is the user's:** `sujenphea.AtelierRefsMobileUITests` must be registered
as an App ID with the App Groups capability, and joined to `group.sujenphea.AtelierRefs.dev`
(Debug) and `group.sujenphea.AtelierRefs` (Release). Until then a signed run of this test
fails to provision. That is portal work, the same shape as
[401](401-one-variable-eight-places.md)'s gate 1 for the app and the extension.

One incidental finding while verifying: `ThumbnailPipelineTests.concurrentRequestsCoalesceWithAFastDecode`
failed once during a full-suite run and passed 4/4 afterwards, including the full suite run
alone. It is a 40 × 32-way concurrency stress test asserting exact decode counts, and the
failure happened while a second `xcodebuild` was running on the same machine. Pre-existing
load sensitivity, unrelated to anything here, recorded rather than left as a mystery.

## Migration notes

The portal registration above is required before this test can run signed. Nothing else
changes; no shipping target gained or lost anything.
