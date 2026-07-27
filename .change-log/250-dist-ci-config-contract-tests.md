# 250 — Distribution: CI + config-contract tests (phase A4)

Final phase of Track A. Wires the release-lane guard into CI on release tags and
completes the **12A** config-contract tests, per the 052 plan (decisions **9A**
release-lane guard, **12A** config guards, **2A** sandbox posture).

## Summary

- **Config-contract unit test (12A), extended in place (DRY).** The A0 guard
  already lived in `AtelierRefsTests/ConfigContractTests.swift` (one suite,
  `DeploymentTargetContractTests`, asserting `LSMinimumSystemVersion ≤ 26.0` from
  the built app via `Bundle.main`). Added one sibling suite,
  `SparkleFeedKeyContractTests`, in the same file — no parallel test file.
- **Sandbox constraint (design correction).** The AtelierRefsTests host is the
  *sandboxed* AtelierRefs app, so a test process cannot read repo source files off
  disk (`Info.plist` / `.entitlements` → POSIX EPERM). A first pass that read the
  source files via `#filePath` failed exactly there. The suites therefore read the
  built app's own merged `Info.plist` via `Bundle.main` — which is precisely what
  12A specifies ("the *built app's* Info.plist has SUFeedURL/SUPublicEDKey") and
  matches A0's pattern. The entitlements clause can't be host-free in this target
  at all (sandbox blocks the source file; the unsigned CI build embeds no readable
  entitlements), so it lives in `verify-release.sh` against the signed binary — the
  home the A0 author had already chosen for it.
- **Release-tag CI job.** New `.github/workflows/release.yml`, triggered on `v*`
  tags, runs `release.sh` then `verify-release.sh`. The existing `ci.yml`
  PR/push jobs are untouched.
- **Placeholder + appcast release gate.** The "SUFeedURL/SUPublicEDKey are not the
  REPLACE-ME placeholders" and "appcast is well-formed + carries an EdDSA
  signature" checks were added to `verify-release.sh` (release path), NOT to the
  always-on unit suite — those genuinely cannot pass until a human sets real
  values, so baking them into every push would keep CI perpetually red.
- **Manual staging-appcast procedure (12A).** Documented in `SECRETS.md`.

## Files changed

- `AtelierRefs/AtelierRefsTests/ConfigContractTests.swift` — extended with one
  suite, `SparkleFeedKeyContractTests`: asserts the built app's Info.plist
  (`Bundle.main`) declares the `SUFeedURL` and `SUPublicEDKey` keys (PRESENCE
  only). Existing `DeploymentTargetContractTests` (A0) unchanged; header comment
  rewritten to record what each suite covers, the sandbox constraint, and why the
  entitlements / non-placeholder / appcast checks live in the script instead.
- `scripts/verify-release.sh` — added an optional 3rd arg (`appcast.xml`); extended
  check 5 to also assert the Sparkle `temporary-exception.mach-lookup.global-name`
  entitlement in the signed binary (alongside the existing app-sandbox +
  network.server assertions); and added two checks: (7) `SUFeedURL`/`SUPublicEDKey`
  read from the built app's Info.plist are non-placeholder; (8) appcast is
  well-formed XML (`xmllint`) and carries a `sparkle:edSignature` + an
  `<enclosure url=…>`. Existing checks 1–6 otherwise untouched.
- `scripts/release.sh` — final hint now passes `appcast.xml` to `verify-release.sh`.
- `.github/workflows/release.yml` — NEW. See "CI decision" below.
- `AtelierRefs/Info.plist`, `SECRETS.md` — corrected stale comments that claimed
  the *unit test* asserts non-placeholder; the release gate does. (No values
  changed.)
- `SECRETS.md` — added the manual staging-appcast update-test procedure (12A).

## What A0 already covered vs. what A4 adds

- **Already covered (not re-added — DRY):** the deployment-target floor. A0's
  `minimumSystemVersionWithinFloor` reads the built `LSMinimumSystemVersion`, which
  is exactly what `MACOSX_DEPLOYMENT_TARGET` produces, so a pbxproj bump above 26.0
  already fails. No separate pbxproj parse was added.
- **Added by A4:** the Sparkle feed/key presence guard (unit test) and the
  entitlements posture snapshot (app-sandbox + network.server + Sparkle
  mach-lookup, in `verify-release.sh` — see the sandbox note above) — none of which
  A0 touched.

## CI decision — runner + signing guard (resolves the plan's deferred question)

- **Where:** a dedicated `release.yml`, not a new job in `ci.yml`. The PR/push gate
  builds *unsigned* on GitHub-hosted runners (`CODE_SIGNING_ALLOWED=NO`); the
  release job *signs + notarizes* a real artifact. Different trigger, runner, and
  secret requirements — a separate workflow keeps both clean and leaves the
  existing jobs undisturbed.
- **Trigger:** `push: tags: ['v*']`.
- **Runner:** self-hosted — `runs-on: [self-hosted, macOS, arm64]`. GitHub-hosted
  images lack the Xcode 26 / macOS 26 SDK the app targets, and — decisively —
  cannot hold the release secrets (per SECRETS.md the Developer ID identity, the
  `AtelierRefs-notary` profile, and the Sparkle EdDSA key live in the *login
  Keychain of a provisioned release machine*; never committed, never injected into
  hosted runners). So signing/notarization can only run self-hosted.
- **False-green guard:** an explicit preflight step fails loudly (`::error::`) if
  the Developer ID identity or the notary profile is absent, before any build work.
  `release.sh` also self-preflights. If no self-hosted runner is online the job
  simply stays queued — it never reports a false pass.

## Test run (this machine)

`xcodebuild test -project AtelierRefs/AtelierRefs.xcodeproj -scheme AtelierRefs
-destination 'platform=macOS' -only-testing:AtelierRefsTests/DeploymentTargetContractTests
-only-testing:AtelierRefsTests/SparkleFeedKeyContractTests -parallel-testing-enabled NO
-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO`

→ **`** TEST SUCCEEDED **` — 2 tests in 2 suites passed, 0 failed** (deployment-target
floor + built-Info.plist Sparkle key presence).

Note on `-parallel-testing-enabled NO`: with the default (parallel) scheduler,
selecting a few suites made xcodebuild spawn several clones of the app test host
concurrently; the second+ launches early-exited (the app boots `AtelierServer` on
a socket — only one host can bind), which surfaced as spurious runner failures
unrelated to these tests. Running the host serially is the clean, deterministic
invocation. CI's `app` job runs the *whole* `AtelierRefsTests` target in one host,
so it isn't affected.

## Still blocked on a human (unchanged from A3, by design)

- Set a real `SUFeedURL` (decide hosting) and `SUPublicEDKey` (run `generate_keys`)
  in `AtelierRefs/Info.plist`. Until then `verify-release.sh` fails a real release
  on the placeholder gate — the push CI stays green.
- Provision a self-hosted macOS 26 runner with the release keychain for
  `release.yml` to execute; and run the manual staging-appcast test once (SECRETS.md).
