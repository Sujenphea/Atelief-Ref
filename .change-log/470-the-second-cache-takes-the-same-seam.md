# 470 — the second cache takes the same seam

[469](469-the-cache-that-was-never-promised.md) closed by naming what it had deliberately
left behind:

> **`DetailImageCache` has the identical latent flake and was left alone.** …Neither has
> been seen to fail; both can. They survive today because their insert-then-read windows
> are microseconds of straight-line code where the thumbnail suites' are seconds across
> task hops, which narrows the window rather than closing it.

The user took that as **099 · P2c** (issue 21A) on the grounds that the seam which fixes
it was already built and paid for in P2b. This entry is that phase, and it is a smaller
one than 469 because none of the diagnosis had to be redone: the failure mode is known,
the fix is known, and what was actually needed was an **audit** — which assertions in
these suites are cache reads, including the ones that do not look like cache reads.

## The audit

469 predicted two sites. There are **ten assertions across eight tests**, and two of them
are in a file 469 did not name.

**Residency-dependent — every one of these can fail on an `NSCache` for a reason that has
nothing to do with what the test is about:**

| Test | Assertion | Why it is a cache read |
|---|---|---|
| `DetailImageLoaderCoreTests/concurrentRequestsCoalesce` | `oks.allSatisfy { $0 }` | each `ok` is `displayImage(…) != nil`, and `displayImage` **re-reads the cache** after awaiting the decode |
| `…/promotedPreloadNotReDecoded` | `await image != nil` | same — the return value is a cache read |
| `…/retainOnlyCancelsOutsideWindow` | `loader.cached("keep") != nil` | direct |
| `…/retainOnlyKeepsPromoted` | `await image != nil` | same as above |
| `…/cacheHitDoesNotReDecode` | `probe.callCount("a") == 1` | the second `displayImage` must **hit**; an eviction in between is a second decode |
| `…/cacheHitDoesNotReDecode` | `loader.cached("a") != nil` | direct |
| `DetailImageCacheTests/costEviction` | `resident(8, in: roomy) == 8` | direct — word-for-word `costBasedEviction`'s sentence |
| `DetailImageCacheTests/countEviction` | `resident(8, in: roomy) == 8` | direct |
| `DetailSessionSizingTests/zoomUpgradesCurrentToNative` | `probe.buckets("prev") == [3072]` | see below |
| `…/zoomUpgradesCurrentToNative` | `probe.buckets("next") == [3072]` | see below |

The last two are the ones worth writing down, because they are a **cache read wearing a
probe's clothes**. That test calls `updateDisplayTarget` twice; the second call re-runs
`DetailSession.preloadAndRetain`, and `DetailImageLoader.preload` starts a decode only
when `cache.image(for: key) == nil`. So `probe.buckets("prev") == [3072]` is not "the
neighbour was warmed at the FIT bucket" — it is "the neighbour warmed in the first cycle
is **still resident** in the second". An eviction in between makes it `[3072, 3072]` and
the test fails on the sizing rule it is not about. Nothing in the assertion's text says
"cache", which is exactly why the audit had to read the production path rather than grep
for `cached(`.

**Judged safe, with the reason** — every other assertion in the four suites of
`DetailImageLoaderTests` and the two of `DetailSessionTests` was read, not skipped:

- **The three pure suites** — `DetailNeighborsTests` (5 tests), `DetailBucketTests` (4),
  `DetailDisplayDecodeTests` (5) — touch no cache at all. They are the `detailNeighbors`,
  `detailPixelBucket` and `detailDisplayDecode` functions, which are pure.
- **`DetailSession` B1 (4 tests)** builds its sessions with the default
  `displaySource = { _ in nil }`, so every asset is media-less, nothing decodes and
  nothing is cached.
- **`callCount == 1` in `concurrentRequestsCoalesce`, `promotedPreloadNotReDecoded` and
  `retainOnlyKeepsPromoted`.** These count decodes across requests that all attach to a
  task **still in flight** (the recorder gates the unblock on 24 attachments; the other
  two join a blocked preload). No cache read gates any of them. Contrast
  `cacheHitDoesNotReDecode`, where the second request arrives *after* the first finished
  — which is why that one is in the table above and these three are not.
- **`oks.count == 24`** — structural, counts task-group members.
- **`resident(8, in: tight) < 8` in both eviction tests, and `loader.cached("drop") == nil`.**
  These assert *absence*, and auto-eviction can only make an absence more true, so the
  flake cannot fail them. They are listed here anyway because the flake **weakens** them:
  a cache that had silently dropped everything would pass all three for the wrong reason.
  That is what the roomy control arm exists to catch, and moving to a store that keeps
  what it is given is what makes the pair say what it means again.
- **`probe.buckets(…)` in `fitDecodeAndNeighborPreload` and `previewViewportSkipsAllDecode`** —
  one sizing cycle each, so no request is ever gated on a prior insert.
- **`antiStormDeDup`'s `probe.buckets("cur") == [2048, native]`.** This one looks like the
  `zoomUpgradesCurrentToNative` case and is not: the de-dup it tests is
  `DetailSession.lastDisplayKey`, a session field, which returns before the loader is
  called at all. The cache is never consulted.
- **`DetailImageCacheTests`' `cost > 1_000_000`** — arithmetic on a fresh bitmap.

One `NSCache` in the module was checked and left: `BakeoffThumbnailStore` in
`Debug/AppKitBakeoffGrid.swift`. `AppKitBakeoffGridTests` only ever calls its static
`bucket(forLongSide:scale:)`, a pure function; no test asserts anything about what it
holds, so there is nothing there to fix.

## The seam fitted, and was widened by one rule

`DetailImageCache` keys `"hash#bucket"` strings to `CGImage`s under a byte budget. So does
`ThumbnailStore`. The key type, the value type and rule 2 are identical, and the
`DetailImageKey` → `String` mapping was **already** how the old `NSCache` was addressed
(`key.cacheKey as NSString`). There was no case for a second protocol.

The one real difference is that the detail cache is count-AND-cost bounded where the
pipeline is cost-only — five full-res bitmaps, because {prev, current, next} is three
plus a step of back-step hysteresis (036 §3 B2). That is one property, not one protocol,
so `ThumbnailStore` gained **rule 1b**: `countLimit` is an entry-count budget, `0` is
unbounded. `NSCacheThumbnailStore` already exposed `countLimit` for P2b's configuration
test; it now takes one, defaulting to `0`, so the pipeline gets no count limit **by not
asking** — which is the 036 §1.4 decision the P2b test `noCountLimit` exists to defend,
and that test still passes unchanged.

`DetailImageCache` is now the `DetailImageKey`-shaped face of a `ThumbnailStore`:

```swift
init(store: ThumbnailStore)
convenience init(totalCostLimit: Int = detailImageCacheCostLimit,   // 384 MB
                 countLimit: Int = detailImageCacheCountLimit)      // 5
```

`DetailImageLoader` is untouched — it still takes a `DetailImageCache`, still defaults to
`DetailImageCache()`, and every production call site reads exactly as before. The two
budgets became named constants only so a test can assert them without repeating the
arithmetic.

`PinnedThumbnailStore` grew the count budget and evicts on it oldest-first, from the same
order the byte budget uses, so whichever bites first governs — which is how the two
`NSCache` limits compose. The test target gets one factory,
`DetailImageCache.pinned(totalCostLimit:countLimit:)`, unbounded on both axes by default
for the reason `pinnedPipeline` is: the scheduling tests are about coalescing, promotion
and cancellation, and a budget none of them set is one more reason a lookup could miss.

### What was NOT done, deliberately

**The protocol was not renamed.** `ThumbnailStore` now has two consumers and only one of
them is thumbnails, which is a wart, and the alternative was worse: `Debug/` already
contains an unrelated class called `BakeoffThumbnailStore`, so a search-and-rename is not
mechanical; 469 and 099's status row name these types in prose; and the rename would be
churn against a vocabulary one commit old. The protocol's doc comment now says out loud
that it serves both caches and that the name is the pipeline's only because the pipeline
got here first.

**The app was not given a deterministic cache.** 469 rejected that trade explicitly —
it would make the app hold hundreds of megabytes of decoded bitmaps through a memory
warning and never hand any of it back — and the same answer holds here, more strongly:
384 MB of full-res images is the *larger* of the two caches to pin in memory.

## Production behaviour

**Nothing changed.** Before, `DetailImageCache` owned an `NSCache<NSString, Box>` with
`totalCostLimit = 384 MB`, `countLimit = 5`, inserting at `max(0, cost)` under the key
`key.cacheKey`. After, it owns an `NSCacheThumbnailStore`, which is an
`NSCache<NSString, Box>` with `totalCostLimit = 384 MB`, `countLimit = 5`, inserted at
`max(0, cost)` under the key `key.cacheKey`. Same class, same budgets, same eviction, same
`Box`, one more pointer hop. The app still hands this memory back to the system under
pressure, which is what it should do.

**Not one assertion was weakened or deleted.** The three files' `@Test` counts went
**21 → 23**, **8 → 8** and **41 → 43**: four new tests, none removed.

The four are the contract and the configuration, in the shape 469 established:
`PinnedThumbnailStoreTests/countBudgetEvictsOldestFirst` (rule 1b: evicts oldest-first,
only when it must, `0` is unbounded); `NSCacheThumbnailStoreTests/countLimitWhenAsked`
(the parameter actually reaches the `NSCache`, so the detail cache cannot silently ship
unbounded by count); and a `DetailImageCacheConfigurationTests` suite whose two tests pin
the shipped budgets (384 MB / 5) and check that the default initialiser still reaches a
real `NSCache` and a real decode. That last one asserts `probe.callCount("a") == 1` and
**not** the image it got back — the return value of `displayImage` is a cache read, and
asserting it against an `NSCache` is the thing this phase is about not doing.

## Verification

**The tally is not the argument, and this entry does not pretend it is.** These tests have
never been observed to fail; "they pass now" was true before the change and is consistent
with the bug still being there. The argument is structural:

> **After this change, no assertion in `DetailImageLoaderTests` or `DetailSessionTests`
> reads residency from an `NSCache`.** Every cache those suites touch is a
> `DetailImageCache.pinned(…)` over a `PinnedThumbnailStore`. The only two
> `NSCache`-backed caches left in either file are in
> `DetailImageCacheConfigurationTests`, which asserts the two budgets and one decode
> count, and never what the cache holds.

The ten assertions in the table above are the ones that changed meaning: each was a hope
and is now a property of the store it reads, checked separately in
`PinnedThumbnailStoreTests`.

The budget tests were checked for **discrimination**, since they now exercise the pinned
store's rules rather than `NSCache`'s: deleting the count clause from
`PinnedThumbnailStore.overBudget` fails `DetailImageCacheTests/countEviction` and
`PinnedThumbnailStoreTests/countBudgetEvictsOldestFirst`, and nothing else. They still
test something.

**The tally, for what it is worth: 12 consecutive runs, 0 failures**, of the nine affected
suites — 36 tests per run — with `test-without-building`. A green tally at this length is
exactly what the pre-change code would also have produced; it rules out having broken
something, not the bug.

### The gate is RED, and not on this phase — so this phase does not commit

`./scripts/verify.sh full`:

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ CanvasRenderer
  ✓ AtelierExport
  ✓ App target
  ✓ App target (Release)
  ⚠ Extension
  ✗ App target (UI)

1 stage(s) failed.
```

`⚠ Extension` is the stale Instagram drift fixture, non-fatal since
[464](464-the-gate-tells-its-two-arms-apart.md) and not this phase's. `✗ App target (UI)`
is new, and it is not this phase's either.

All three smoke flows failed the same way:

```
Failed to get matching snapshots: Unable to perform work on main run loop,
process main thread busy for 30.0s
```

`/usr/bin/sample` on the app under test says exactly where the main thread is:

```
com.apple.main-thread
  closure #1 in IngestionModel.init()          IngestionModel.swift:694
    IngestionModel.bootstrap()                 IngestionModel.swift:858
      IngestionModel.startCaptureEndpoint      IngestionModel.swift:937
        IngestionModel.loadOrCreateCaptureToken IngestionModel.swift:1050
          CaptureTokenStore.load               CaptureTokenStore.swift:40
            CaptureTokenStore.readKeychain     CaptureTokenStore.swift:90
              SecItemCopyMatching  (in Security)
                … SSGroupImpl::decodeDataBlob … CSSM_DecryptDataFinal …
                  ClientSession::decrypt → mach_msg_trap
```

The app blocks its **main actor** at launch on a synchronous `SecItemCopyMatching`
against `so.atelier.refs.capture-token`, a **login-keychain** item (`security
find-generic-password` says `login.keychain-db`, created 2026-08-09 — the user's real
token, not a fixture). `CaptureTokenStore` does not pass `kSecUseDataProtectionKeychain`,
so this is the file-based keychain, whose ACLs are bound to the reading binary's code
signature. The UI stage is the one stage that signs **ad-hoc** (`CODE_SIGN_IDENTITY=-`,
and it must — see 468), so every rebuild of the app presents a *different* signature to
that ACL, macOS raises a `SecurityAgent` confirmation, and an unattended `xcodebuild`
never answers it. `SecurityAgent` was running from 08:23:42, the minute of the first
failing re-run.

**The decisive experiment: HEAD fails identically.** With every change of this phase
stashed — a tree byte-identical to `f91f29d`, which
[469](469-the-cache-that-was-never-promised.md) recorded as exit 0 first run — the UI
stage passed when it re-used the already-authorised binary and **failed on all three
flows** the moment a fresh `-derivedDataPath` forced a rebuild. Re-running the failed
binary a second time fails again, so it is not a one-off prompt that gets remembered. Any
commit touching an app-target file trips this.

So the diff is exonerated and the phase stops at 099's rule: *"A phase that cannot get the
gate green does not commit; it reports."* **Nothing here is committed.** The work is left
in the worktree. The gate goes green again when the ACL prompt is answered at the machine
(click *Always Allow* on the keychain dialog and re-run the stage), and stops recurring
only if `CaptureTokenStore` moves off the main-actor-blocking file-keychain read — which
is a production change, out of this phase's scope, and precisely the "change what ships to
make a test pass" trade 469 refused.

The thirteen stages that CAN speak about this diff all pass, including `App target` — the
~1,700-case unit stage that contains every test discussed above — and
`App target (Release)`.

## What is still NOT covered

**The trigger, still.** 469 did not establish which signal empties an `NSCache` under
load, and neither does this. Nothing here makes that question easier to answer; it makes
it matter less, in one more place.

**Whether `DetailImageCache` ever actually flaked.** It never failed in front of anyone,
before or after, so this phase has **no before/after failure-rate measurement at all** —
where 469 at least had 1-in-35 to point at. What is established is that the assertions
were of a kind that `NSCache` does not support, which is a statement about the contract
and not about any run. If the detail suites were silently failing at some low rate on
someone's machine, nothing in this repo would show it.

**`NSCache`'s own budget behaviour is now untested in a second place.**
`costEviction` and `countEviction` exercise `PinnedThumbnailStore`'s implementation of the
budgets. `.change-log/284` holds the measurement that says `NSCache` agrees about rule 2,
and `NSCacheThumbnailStoreTests` says the two limits are *configured* — but nothing in the
suite would catch `NSCache` changing its mind about how it enforces them, and nothing
could, because the test that would is the flaky one. This is 469's trade, taken a second
time knowingly.

**The three load-induced timeout flakes are untouched**, as the user directed (21A):
`PollTests/settlesEarly()`, `LibrarySearchModelTests` and `CollectionActivationTests` all
failed under 469's deliberately-heavy load set and remain a recorded risk, not a fix. They
are timeout-shaped, not cache-shaped; 099 · 11A's bounded waits carry fixed timeouts and a
fixed timeout is a fixed bet. Nothing here changes that, and nothing here says what the
right bound is.

**The `ThumbnailStore` name.** Two consumers, one thumbnail-shaped name, documented rather
than fixed. If a third cache ever takes this seam, rename it then and do it in one commit
that touches nothing else.

**The UI stage's keychain blocker is diagnosed, not fixed.** This entry establishes what
blocks it and that it is independent of this diff. It does **not** fix it, and the fix is
a judgement the user has to make: answer the prompt each time the app is rebuilt; or move
`CaptureTokenStore` to the data-protection keychain (`kSecUseDataProtectionKeychain`),
whose access is entitlement-based rather than cdhash-based; or take the blocking
`SecItemCopyMatching` off the launch path so a stalled keychain cannot stall the window.
The last of those is worth doing on its own merits — a keychain round trip on the main
actor at launch is a hang the app can suffer in the wild, not only under a UI test — but
it is a production change and nothing in 099 authorises it. **`PollTests/settlesEarly()`
also failed once here**, on a machine loaded by this phase's own builds, and passed on a
re-run: that is the flake 469 recorded and 21A left alone, seen again, still untouched.

## Files

- `AtelierRefs/AtelierRefs/ThumbnailPipeline.swift` — `ThumbnailStore` gains
  `countLimit` (contract rule 1b) and a doc comment that admits to two consumers;
  `NSCacheThumbnailStore.init` takes a `countLimit`, defaulting to `0`. No behaviour
  change for the pipeline.
- `AtelierRefs/AtelierRefs/DetailImageLoader.swift` — `DetailImageCache` becomes a
  `ThumbnailStore` adapter with the production shape kept as a `convenience init`;
  `detailImageCacheCostLimit` / `detailImageCacheCountLimit` named. No behaviour change.
- `AtelierRefs/AtelierRefsTests/TestSupport/PinnedThumbnailStore.swift` — the count
  budget, and `DetailImageCache.pinned(totalCostLimit:countLimit:)`.
- `AtelierRefs/AtelierRefsTests/DetailImageLoaderTests.swift` — every cache is pinned;
  new `DetailImageCacheConfigurationTests` (2 tests), 21 → 23.
- `AtelierRefs/AtelierRefsTests/DetailSessionTests.swift` — the four sizing loaders are
  pinned, and the suite doc says which two of its probe assertions are cache reads.
- `AtelierRefs/AtelierRefsTests/ThumbnailPipelineTests.swift` — two new contract tests
  for rule 1b, 41 → 43.
- `.docs/099-mac-backlog-plan.md` — P2c section and status row.

No `project.pbxproj` change: no file was added or removed.
