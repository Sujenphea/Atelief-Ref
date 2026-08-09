# 353 — run-local.command survives its second run

## Summary

`scripts/run-local.command` worked exactly once per build directory. Every run
after that died in Step 2b:

```
==> Disabling library validation (ad-hoc build)
Add: ":com.apple.security.cs.disable-library-validation" Entry Already Exists

*** FAILED (exit 1) ***
```

PlistBuddy exits 1 on a duplicate `Add`, and under `set -euo pipefail` that ends
the script — after the build, before the install, so the bundle in
`/Applications` stayed whatever it was.

Two independent causes, both introduced with `relax_library_validation` [350],
both of which need the *second* run to show up.

### Cause 1 — `codesign -d --entitlements` appends

`codesign -d --entitlements FILE` does **not** truncate an existing FILE; it
appends. `build/local-release/adhoc.entitlements` lives in the derived-data path
and survives between runs, and run 1 leaves it on disk with the key already
added. So run 2 produced a file holding two concatenated `<plist>` documents:

```
before:  868 bytes     # run 1's leftover, key present
after:  1622 bytes     # run 2's read-back appended onto it
```

PlistBuddy parses only the first document — last run's — finds the key, and
fails. Worse than the error: had the key not been there, the script would have
re-signed with a *stale* entitlement set, defeating the whole reason Step 2b
reads off the built bundle rather than the `.entitlements` source.

### Cause 2 — `Add` is not idempotent, and the bundle is not always fresh

Fixing cause 1 alone still failed on the run after. Step 2b re-signs the app
*with* the key, and an incremental build that re-links nothing also re-signs
nothing — so xcodebuild hands back the previous run's bundle, key and all.
Reading its entitlements back correctly finds the key, and `Add` fails again.

Cause 1 fires when xcodebuild *did* re-sign, cause 2 when it did not. Between
them they cover every re-run, which is why the script had a 100% failure rate
after its first success and looked like a single bug.

## The fix

Both in `relax_library_validation`, `scripts/run-local.command`:

- `rm -f "${ents}"` before the `codesign -d`, so the read-back always writes one
  plist describing the bundle actually on disk.
- `Delete` before `Add`, with the `Delete` tolerated when the key is absent
  (`|| true`). The step now ends with the key set to true whether or not the
  input carried it.

Step 2b is now idempotent: running it against its own output is a no-op that
re-signs the same bytes.

## Verification

```
run A (stale adhoc.entitlements present, key in it)  → re-signed, exit 0
run B (immediately again, bundle now carries the key) → re-signed, exit 0
```

Both previously-failing states now pass. On the resulting bundle:

- `codesign --verify --deep --strict` → `valid on disk`, `satisfies its
  Designated Requirement`; Sparkle and both XPC services validate.
- `flags=0x10002(adhoc,runtime)` — hardened runtime still on.
- Entitlements: `app-sandbox` and the rest intact, both `…-spks` / `…-spki`
  mach-lookup names correctly substituted, `disable-library-validation` present
  exactly once.
- `Sparkle.framework` signature untouched.

## Files changed

- `scripts/run-local.command` — `relax_library_validation`: `rm -f` the
  entitlements scratch file before reading it back; `Delete`-then-`Add` instead
  of a bare `Add`. Comments explain both, since neither `codesign -d`'s append
  nor the skipped re-sign is guessable from the code.

## Migration notes

- Nothing to do. A `build/local-release/adhoc.entitlements` left over from a
  failed run is now removed by the next run rather than poisoning it — deleting
  `build/local-release` by hand is no longer the workaround.
- Behaviour on a clean build directory is unchanged.
