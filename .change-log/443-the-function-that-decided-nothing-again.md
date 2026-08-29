# 443 — the function that decided nothing, again

`ShareViewController.harvest()` carried this doc comment:

> **This function no longer decides anything** (406, issue 11). It walks the providers,
> first-non-nil-wins, and hands three optionals to `ShareCapture.sharedItem`.

It was true the day 406 wrote it. Tier 2 then added a block that decides three things, in
the one file in the project with **no test host at all**:

1. a page snapshot beats tier 1 outright — `urlString` and `title` are discarded;
2. bytes that arrived with the share beat the media URL the extractor found;
3. no snapshot means tier 1.

All three are pure over four optionals. None needs `UIKit` or an `NSExtensionContext`. This
is the same relocation 406 performed on the same function, applied to the decisions that
leaked back past it — not a new mechanism.

## `ShareResolution`, because one case cannot be finished

`sharedItem` returns a `SharedItem?`, which can say "here it is" and "there is nothing". It
cannot say **"this is a tier-2 page whose picture still has to be fetched"** — and fetching
needs the network, which needs a process. Collapsing that third case into either of the
others is how the decision ended up in the extension to begin with.

```swift
public enum ShareResolution: Equatable, Sendable {
    case resolved(SharedItem)
    case needsMedia(PageCapture)
    case nothing
}
```

`ShareCapture.resolution(image:urlString:title:page:)` is the router. The no-page branch
calls `sharedItem` rather than restating it, so tier 1's rules keep exactly one
implementation.

What is left in the extension is a walk over item providers, a switch, and the fetch.

## Rule 1 discards, and that is now pinned

Worth naming because it is the half that is easy to miss: a page does not merely win, it
**drops** the shared URL and the sharing app's `attributedTitle`. That is right — the DOM
knows the author and the canonical permalink and an `attributedTitle` knows neither — but it
is a real loss, and it was happening where nothing could assert it. `a page snapshot beats
the shared URL and title outright` is now a test.

## Two more fixes ride along, because they are the same control flow

They were planned as separate commits and are not, for an honest reason: all three
restructure `harvest` and its fetch, in one file, and unpicking them into three commits
would mean three passes over the same forty lines.

### An over-cap image no longer kills the page it arrived with

`loadImage` refuses a file above `InboxWriter.maximumPayloadBytes` before copying it, and
that refusal propagated straight out of `harvest`. So a share whose IMAGE was too big lost
its **page** as well: the snapshot had already loaded, the DOM had the author, the permalink
and a rendered-size media URL that is under the cap by construction, and all of it was
discarded for a card reading "that one didn't save".

That inverts this file's own thesis. *Tier 2 failing is tier 1 succeeding* — the header says
it three times — but tier 1 failing was taking tier 2 down with it, and tier 2 was the path
that would have worked.

The error is now held in `oversized` and rethrown only when the share amounted to
`.nothing`. The refusal stays explicit exactly where it was written to be: a plain oversized
photo, no page and no URL, fails on the card as before, because that is a share with nothing
to degrade to. `.nothing` as a distinct case is what makes that test expressible at all —
it separates "no capture" from "a capture with no picture".

### The fetch budget belongs to the share, not to each attempt

`mediaFetchTimeout = 8` was applied per candidate, and `mediaCandidates` returns up to two —
the second existing precisely because the first is a rewrite KNOWN to fail sometimes
(`/originals/` 404s on Pinterest, `name=orig` gets refused). Two attempts is the expected
path when the rewrite is wrong, not an exotic one. Two slow-or-dead CDN requests left the
user watching the card for **sixteen seconds**, against a stated goal of under one. At that
length a share sheet does not read as fetching; it reads as a hang.

Now one `ContinuousClock` deadline spans the loop and each attempt carries what is left of
it; a candidate reached with nothing remaining is not attempted. One session for the share
too, its `timeoutIntervalForResource` set to the whole budget, so the ceiling holds whether
one candidate hangs or both are merely slow. `ContinuousClock` rather than `Date` because a
share that got longer when the wall clock moved would be an absurd bug to own.

The constant is renamed `mediaFetchBudget`. A "timeout" is a property of a request and this
is a property of the share — the old name is most of why it was applied per candidate for as
long as it was.

## Files changed

- `AtelierCapture/Sources/AtelierCapture/ShareCapture.swift` — `ShareResolution`,
  `resolution(image:urlString:title:page:)`.
- `AtelierRefs/AtelierRefsShare/ShareViewController.swift` — `harvest` reduced to a provider
  walk plus a switch; the page snapshot and its log line split into `pageCapture()`;
  `oversized` held and conditionally rethrown; `pageItem` given a share-wide deadline and a
  shared session; `fetchMedia` takes both; `mediaFetchTimeout` → `mediaFetchBudget`.
- `AtelierCapture/Tests/AtelierCaptureTests/ShareCaptureTests.swift` — four tests over the
  moved rules.

## Not covered by a test, and named rather than left implied

The two riders are asserted only by the iOS build. The over-cap rethrow needs a `>64 MiB`
file arriving through an `NSItemProvider`, and the budget needs a CDN that hangs — both live
on the far side of the seam `AtelierCapture` exists to keep pure, and neither is reachable
from `swift test`. `ShareResolution.nothing` is what a future test would assert against, and
it is tested; the throw itself is one line above it.

## Verification

`swift test` in AtelierCapture → **130 tests in 7 suites**, up from 126. `AtelierServer`
builds, `AtelierArchive` 56 tests pass. Both iOS schemes build for the simulator.

## Migration notes

None. `sharedItem` is unchanged and still public — `resolution` composes over it rather
than replacing it.
