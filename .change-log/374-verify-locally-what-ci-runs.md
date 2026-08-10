# 374 — Run Locally What CI Runs

`scripts/verify.sh`, and the compile break that made it necessary.

Index 374 rather than 373: `feat/color-filter` already holds 373, and indices are
never reused.

## What went wrong

The archive shelf's A1 made `collectionItems(in:sort:includeArchived:)`
non-defaulted — deliberately source-breaking, so every call site has to decide.
[367](367-the-archive-predicate.md) says "every call site was updated". Five were
not: `IngestPipelineTests`, `IngestCoordinatorTests` and `VideoIngestTests` in
**AtelierIngestion**, whose test target then stopped compiling.

It merged into `main` that way and sat there for six commits.

**The gate that would have caught it already existed.** `.github/workflows/ci.yml`
runs `swift test` across all five packages on every push. It never ran, because
nothing had been pushed in 32 commits. Verification was local, by hand, against
whichever packages came to mind — and the package I did not think of is exactly
the one with the missed call site.

The failure was a *compile* error, which is the cheap kind: a plain `swift build`
misses it (test targets are not built), but `swift build --build-tests` catches
it in seconds.

## The script

Two modes, answering different questions:

| | What it does | Cost |
|---|---|---|
| `./scripts/verify.sh fast` | `swift build --build-tests` × 5 packages, `xcodebuild build` | ~30s |
| `./scripts/verify.sh` | the full CI matrix: 5 × `swift test`, `node --test`, drift check, `xcodebuild test` | minutes |

**The package list is parsed out of `ci.yml`.** Not copied — a second list is
precisely how the original bug happened: two places to update, one of them
updated. The parse fails loudly if the matrix line's format changes, rather than
silently testing nothing.

Every stage runs even after one fails (CI's `fail-fast: false`), so one break
does not hide the others.

## Two bugs in the script itself, both found by running it

- **`${arr[@]}` on an empty array is an unbound-variable error** under `set -u`
  in bash 3.2, which is what macOS ships. The empty case is the all-passed case,
  so the naive form failed *only on success*.
- **Piping `xcodebuild` through `grep | head` reported a green app target as a
  failure.** `head` closes the pipe early, and recovering the real status through
  `PIPESTATUS` past that is fragile. It now logs to a file and greps the file.

## What the backfill run found

Full matrix against `main` after the compile fix:

```
✓ AtelierCore   ✓ AtelierIngestion   ✓ AtelierServer
✓ CanvasRenderer ✓ AtelierExport     ✓ App target
✗ Extension
```

The Extension failure is **not code and not new**. `node --test` passes all 417
tests and the drift check reports *"No drift — every check satisfied its
invariants."* It exits 1 because two capture fixtures are past their staleness
windows (38 days, and 26 days against a 14-day window) — `drift-check.js:100`
treats `stale` exactly like `failed`.

So the first push will turn CI red for a reason no code change can fix: the
fixtures can only be re-captured from a logged-in session, out of band. That is
the same blocker [020](../.docs/feature-todo/020-capture-rednote.md) already
records as its next action.

**Not changed here**, because it is a policy decision rather than a bug: whether
a time-based condition should fail a build gate at all. Drift is a real failure —
an invariant the live site broke. Staleness is a reminder with no in-CI remedy,
and a gate that goes red on a schedule and cannot be fixed from CI is the kind
people learn to ignore.

## Files changed

- New: `scripts/verify.sh`
- `AtelierIngestion/Tests/`: `IngestPipelineTests.swift` (×3),
  `IngestCoordinatorTests.swift`, `VideoIngestTests.swift` — all browsing reads,
  so `includeArchived: false`

## Migration notes

None. `verify.sh` is additive tooling; nothing depends on it. Run
`./scripts/verify.sh fast` before committing and the full form before pushing.
