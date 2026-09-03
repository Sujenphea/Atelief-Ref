# 474 — the gate stops claiming a window

[468](468-the-mac-gets-a-window-a-keystroke-and-an-order.md) added `App target (UI)`,
the first UI test ever to run on macOS in this repo, and made it a gate stage. It is out
of the gate again. The suite is untouched and still works; what does not work is running
it **unattended**, and three phases in a row paid for finding that out one face at a time.

## One cause, three faces

A UI-test bundle ships a runner whose executable is `lipo`-extracted from Xcode's
`XCTRunner.app`. Unsigned, the kernel SIGKILLs it before it connects, so the stage
**must** sign — and it signs **ad-hoc**, because a real signature needs a provisioning
profile the runner does not have (098 recorded that the runner bundle needs an App ID
with App Groups, and it still does not have one).

An ad-hoc signature has no team. Its designated requirement therefore collapses to the
**exact cdhash**, and every rebuild is a stranger to macOS. Everything that grants
permission to *an app* — TCC automation, keychain ACLs — is granted to a binary that the
next build replaces. So:

- **468**: `Test crashed with signal kill before establishing connection` — the unsigned
  runner. Fixed by signing ad-hoc, which bought the problem below.
- **470 / 471**: all three flows dying on `process main thread busy for 30.0s`, which
  `sample` traced to a synchronous `SecItemCopyMatching` on the main actor behind a
  `SecurityAgent` prompt no unattended `xcodebuild` can answer. 471 moved the keychain
  read off the main actor — a real launch-hang fix that stands on its own merits — and
  gave the UI suite `-skip-capture-endpoint` so it stops asking at all.
- **473, and this entry**: the stage passing, then failing on an unchanged tree and
  staying failed. Verified independently: the automation session **sets up**, and then
  `app.windows.firstMatch` never resolves. The app is not the problem — launched outside
  XCUITest it runs, and `sample` shows its main thread idle in `NSApplication run`'s
  normal event loop with the FlyingFox queue up. A healthy app that XCUITest cannot see.

## Why it is removed rather than warned

[464](464-the-gate-tells-its-two-arms-apart.md) faced the same shape and answered it with
a warning: the drift canary's staleness arm became exit 2, reported and non-fatal. That
was right **because a stale fixture is a calendar fact** — it can only ever be
environmental, so a warning loses nothing.

A UI failure is not like that. It might mean a window stopped opening. Warning on it
would make a real regression indistinguishable from macOS refusing to automate a binary
it has never seen, and the reader would learn to skip both. Out of the gate is the honest
position: the gate now claims exactly what it verifies, and every red in it means code.

**Decision: the user's, issue 23D**, against three alternatives — watching a run at the
keyboard, warning instead of failing, and fixing the signing first (23C, which stays open
and is the way back).

## What replaces it

`./scripts/verify.sh ui` runs the suite alone. Deleting the stage outright would have
left the incantation — the ad-hoc flags, the manual signing style, the empty provisioning
specifier — as folklore in a changelog. The reasoning lives in `verify.sh`'s header, next
to the code it explains, rather than only here.

`full` is thirteen stages again; `fast` is unchanged at eleven. `.github/workflows/ci.yml`
is untouched (decision 9C).

```
── summary ──
  ✓ AtelierCore        ✓ AtelierCapture   ✓ AtelierLibraryPaths  ✓ AtelierBrowse
  ✓ AtelierArchive     ✓ AtelierTokens    ✓ AtelierIngestion     ✓ AtelierServer
  ✓ CanvasRenderer     ✓ AtelierExport    ✓ App target           ✓ App target (Release)
  ⚠ Extension

All 13 stages passed, 1 with a warning above.
```

Exit 0. `⚠ Extension` is the stale Instagram fixture, non-fatal by design since 464.

## What is still NOT covered

**Nothing runs the macOS UI suite for you now.** Three flows — launch, ⌘,, sidebar order
— exist, pass by hand, and are unwatched. A window that stops opening is again something
only a person notices, which is the state 468 was written to end. That is the cost of
this decision and it should not be discovered later as a surprise.

The suite has never run in CI and still cannot: CI has not executed a step since
2026-08-06, and its runners are `macos-15` against packages that floor at macOS 26.

**The signing fix is not done, only deferred.** 23C — a stable identity for the runner —
would retire this, 471's keychain prompt, and the flakes attributed to both. It needs an
App ID with App Groups, and the project's `DEVELOPMENT_TEAM` (`L25247V6JG`) does not match
the only valid identity in the login keychain (team `GM69PK28NF`), so it is not a one-line
build-setting change.

099 · P5 and P6 planned to add ⌘K and palette flows to this suite. They can still be
written; they simply will not be gated, and those phases should say so rather than quietly
skip them.
