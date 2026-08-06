# 350 — The ad-hoc local build can load its own framework

## Summary

`/Applications/AtelierRefs.app` died at launch, every time, before `main()` ran:

```
Termination Reason: Namespace DYLD, Code 1, Library missing
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
Reason: … code signature … not valid for use in process:
        mapping process and mapped file (non-platform) have different Team IDs
```

Not a missing file, despite "Library missing" — the framework was exactly where
`@rpath` said it would be. **Library Validation** rejected it.

The hardened runtime (`ENABLE_HARDENED_RUNTIME = YES`, mandatory for
notarization, so on in Release) turns Library Validation on. LV lets a process
load a non-platform library only when the library's Team ID **matches the
process's**. An ad-hoc signature has no Team ID at all — `codesign -dvvv` reports
`TeamIdentifier=not set` for both the app and Sparkle — and two absent teams do
not match; they fail the comparison. dyld's message names the symptom ("different
Team IDs") in the one case where neither side has one.

So the failure needs both halves of the ad-hoc fallback to be true at once, which
is why it survived this long unnoticed:

| | Team ID | Hardened runtime | Loads Sparkle |
| --- | --- | --- | --- |
| `release.sh`, Developer ID | `L25247V6JG` on both | yes | yes — teams match |
| `run-local.command`, ad-hoc | none on either | yes | **no — dyld kills it** |
| (any build without hardened runtime) | — | no | yes — LV never runs |

`release.sh` output is fine and has always been fine. This is exclusively the
ad-hoc lane, i.e. every machine with no Developer ID identity in its keychain —
which is every machine except a provisioned release one. [338]

## The fix

A new **Step 2b**, `relax_library_validation`, between the build and the install.
It runs only when `resolve_signing` fell back to ad-hoc (`SIGN_ADHOC=1`) and is a
no-op on the Developer ID path:

- Reads the entitlements back **off the built bundle**, not off
  `AtelierRefs.entitlements`. What xcodebuild signed has
  `$(PRODUCT_BUNDLE_IDENTIFIER)` already substituted into the two Sparkle
  mach-lookup names; the source file still holds the literal `$(…)`, and
  re-signing with those would cut the app off from its own updater XPC services.
- Adds `com.apple.security.cs.disable-library-validation` and re-signs ad-hoc.
- Passes `--options runtime` explicitly. Code-signing options are **not**
  inherited across a re-sign — omitting it would silently drop the hardened
  runtime this script exists to preserve, "fixing" the crash by removing the
  thing that caused it rather than the thing that conflicts with it.
- Re-signs the **`.app` wrapper only**. Sparkle and its two XPC services keep the
  nested signatures xcodebuild wrote, byte for byte.

Scope of the relaxation: one entitlement, one lane. The hardened runtime stays
on, the sandbox and every other entitlement are unchanged, and the only rule
lifted is a team match that an unteamed signature can never satisfy in the first
place. The alternative — `ENABLE_HARDENED_RUNTIME=NO` for ad-hoc — also fixes the
crash but takes JIT policy, `DYLD_*` handling and unsigned-memory rules with it,
and would make the local build differ from the release build in ways that hide
real bugs.

## Verification

Against the crashing bundle itself (UUID `B7B9FFE1…`, the one in the report):

- Before: `open` → gone in under a second, same DYLD termination.
- Re-signed with the entitlement, nothing else changed: launches and stays up.
- After re-signing: `flags=0x10002(adhoc,runtime)` — hardened runtime intact;
  entitlements carry `app-sandbox`, both `…-spks` / `…-spki` mach-lookup names
  correctly substituted, plus the new key.

`scripts/run-local.command`'s `relax_library_validation` was then extracted and
run verbatim against a copy of the same bundle, with the same result.

## Files changed

- `scripts/run-local.command` — new `relax_library_validation` (Step 2b), called
  from `main` between `build_app` and the install; header pipeline comment and
  the "only the signing identity differs" line updated, since one entitlement now
  differs too.

## Migration notes

- Nothing to do. The next `./scripts/run-local.command` produces an installable,
  launchable bundle.
- An `/Applications/AtelierRefs.app` installed by a *previous* ad-hoc run is
  still broken and cannot be repaired by anything but a reinstall — the crash is
  in its signature, not its code.
- `verify-release.sh` is untouched and unaffected: it only ever inspects
  `release.sh` output, where the entitlement is never added. A build carrying
  `disable-library-validation` is by construction one that was never signed with
  a Developer ID, and so is one it would already reject.
- `build/local-release/adhoc.entitlements` is a new build artefact under the
  existing derived-data path. Not committed, removed with the build directory.
