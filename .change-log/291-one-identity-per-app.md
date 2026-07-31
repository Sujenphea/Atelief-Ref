# 291 — one identity per app

## Summary

Three audit findings that are the same shape: a value the app already knows, restated
by hand somewhere else, and then drifted.

## 1. `/health` reported a version the app didn't have

`CaptureServer.appVersion` was the literal `"0.1.0"`, under a comment calling itself
"source of truth". The app's `MARKETING_VERSION` is `1.0`. So the extension's
compatibility handshake was told one version, and the diagnostics report — which
reads `CFBundleShortVersionString` — showed another.

It now reads the bundle, with a `"0.0.0"` fallback for a host-less `swift test` run
where the value isn't under test.

`minExtensionVersion` / `maxExtensionVersion` stay hand-maintained, and the comment
now says why: they are a PROTOCOL range, not the app's version. They move when the
wire contract changes, which is a different event from shipping a build.

## 2. Four logging subsystems for one app

| Subsystem | Used by |
| --- | --- |
| `com.atelierrefs.app` | `AppLog` (2 of 6 sites) |
| `so.atelier.refs` | 3 hand-rolled `Logger`s — search, analysis, ingest timing |
| `so.atelier.capture` | the server |
| `sujenphea.AtelierRefs` | the actual bundle id — used by nothing |

`AppLog`'s own doc comment said new logging "should route through `AppLog.<area>`
rather than ad-hoc `Logger` instances, so diagnostics + Console filtering stay
consistent". Only a third of the app did, and no single Console filter showed all of
it.

One subsystem now, and it is the **bundle id** — the one Console offers to filter by,
and the only one of the four that named anything real. `AppLog` gained `search`,
`analysis` and `ingestTiming`; the three ad-hoc `Logger`s are gone. `AtelierServer`
cannot see `AppLog` (separate package), so it restates the subsystem the way
`Theme.NS` restates the palette, with a comment saying so; its category is
`capture-endpoint`.

`import os` vs `import OSLog` was split 3/3 across the app; it is `OSLog` everywhere
now.

## 3. `/ref/` was one `git add .` from being committed

10 MB of a vendored reference app (Nook), untracked and NOT ignored — so it appeared
in every `git status` alongside real work, unlike `/resources/` and `/dist/`, which
are both explicitly ignored. Now ignored.

## Files changed

- `AtelierServer/.../CaptureServer.swift` — bundle-derived `appVersion`; subsystem +
  category.
- `Diagnostics.swift` — subsystem → bundle id; three new categories.
- `LibrarySearch.swift`, `AnalysisCoordinator.swift`, `IngestionModel.swift` — through
  `AppLog`; `import OSLog`.
- `.gitignore` — `/ref/`.
- `CLAUDE.md` — see below.

## The doc-numbering finding, and why it is only a doc change

`.docs/` has two duplicated indices (`039`, `059`), kinds outside the declared set
(`verification`, `protocol`, `results`) and a subdirectory inside what CLAUDE.md
calls "a flat set".

I renumbered the `059` collision and reverted it. Docs cross-reference each other by
number in prose *and* in relative markdown links — `060`/`061` alone have ~15
inbound references plus their own H1 titles — so renumbering trades a cosmetic
collision for broken links. Not worth it.

CLAUDE.md is updated to describe the directory that exists instead: the extra kinds
are legitimate, a doc may own a `xxx-results/` sibling for bulky artifacts, and
indices are allocation-order, never reused. The two collisions are noted there so the
next writer takes the next free number rather than "fixing" them.

`.change-log/` has 8 duplicated indices and 4 gaps. Left alone for the same reason,
and because these are an append-only historical record.

## Verified

App `-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`. `swift build` in
AtelierServer → `Build complete!`.
