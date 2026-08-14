# 404 — the mirror nobody checked

`ShareCapture.swift`'s header makes a claim about a file in another language: the host
table "mirrors `extension/src/extractors/` and `extension/src/media-hosts.js` domain for
domain, because the browser extension and the phone are the two producers of one contract
and a host that means `twitter` in one of them cannot mean `web` in the other."
[402](402-a-share-becomes-a-record.md) repeated it, and its own migration notes named the
consequence — "a host added on one side and not the other does not fail a build or a
test; it forks provenance." Nothing checked the claim. This is review issue 4, and it is
now checked by `npm run drift-check`, which already runs in CI.

The reason it deserves a check rather than a stricter comment is the shape of the
failure. Add a domain to a JS extractor and the phone goes on filing that site as `.web`;
18A dedup keys on provenance, so the two producers stop colliding on one asset and start
forking two off the same bytes. What a user sees is duplicates, not an error, and
duplicates in a library get blamed on the library.

Codegen was considered and rejected before this slice started — generating fifteen rows of
Swift from JS is a build pipeline standing in for a check, and the check is the part with
value. What is here fails loudly and generates nothing.

## The invariant, stated as behaviour

> For every domain **D** that the JS side classifies as a concrete platform **P**, running
> the Swift `hostPlatforms` lookup on **D** must return **P**.

Not set equality between two lists. Phrasing it as "what would the phone do with this
host" — by re-implementing Swift's own `hostIs` fallback-to-`web` rule in half a dozen
lines of JS — is what makes the check quiet enough to survive. A JS domain that is a *subdomain* of
a Swift row with the same platform is not drift, because Swift already resolves it
correctly: `abs.twimg.com` under a `twimg.com` row is `.twitter` without anyone writing it
down. Set equality would have called that a difference, and a check that reports a
non-problem on day one is a check that gets muted by day thirty.

The two failures it does report are named specifically, with the file that introduced the
domain:

    · pinterest.fr is pinterest in extractors/pinterest.js but MISSING from the Swift
      table — the phone would file it as .web (add it to ShareCapture.hostPlatforms)

    · x.com is twitter in extractors/twitter.js but .pinterest in the Swift table —
      the two producers disagree

## The asymmetry it permits, and the one it refuses

Swift may carry domains no JS extractor names. The Swift table has fifteen rows and the JS
side yields fourteen domains, and the odd one out is **`t.co`**.

This is not slack in the check; the two tables answer different questions. The extension
classifies a page it is *already running inside*. The share sheet classifies a string
another app handed over. A domain can be reachable by the second and unreachable by the
first, and a link shortener is the pure case: `t.co` 302s, so by the time a content script
runs, `location.href` is already the destination and no extractor can ever observe it.
Requiring symmetry would mean making `pinterest.js` or `twitter.js` declare a domain it
cannot see — a check you satisfy by writing something untrue is worse than no check.

The opposite direction is the dangerous one and it is asserted with no exceptions. There
is no exclusion list anywhere in this slice, which was the point: the CDN hosts the Swift
table carries deliberately (`twimg.com`, `pinimg.com`, `cdninstagram.com`, `fbcdn.net`,
`rednotecdn.com`) turned out not to be Swift-only at all — `media-hosts.js` maps every one
of them to a platform for the SSRF guard, so reading that file alongside the extractors
made the whole exclusion problem disappear rather than manage it.

Swift-only rows are **printed** on every run, pass or fail, parenthesised so they never
read as a problem:

    ✔ Producer host tables (extension ↔ iOS share sheet) (repo sources) — swiftRows=15
      jsDomains=14 extractors=5 cdnHosts=5 swiftOnly=1
        (phone-only, no extractor can observe these: t.co)

A second one appearing is not a build failure and should not be, but it should be a thing
a reviewer notices and asks about, which is the most a check can honestly do here.

`ALLOWED_BUNDLE_HOSTS` is deliberately outside all of this. It is a script-fetch allowlist
that declares no platform for its hosts, so any platform this check assigned them would be
invented. Its one entry resolves through the `twimg.com` row anyway.

## A parser that matches nothing agrees with everything

Both sides are read with regexes over source text, which is the part of this that could
rot silently — a table that stops parsing produces an empty list, and an empty list
satisfies every invariant above forever. So liveness is checked before agreement, and is
reported as drift in its own right.

Four floors (12 Swift rows, 7 extractor domains, 4 CDN domains, 4 extractor modules) sit
below today's counts, far enough that retiring one domain legitimately does not trip them
and far enough above zero that a dead regex cannot pass. Stronger than the floors, because
it scales without anyone maintaining a number: every file in `src/extractors/` that is not
`base.js` or `registry.js` **must** parse to exactly one platform string and at least one
`hostIs` domain, and every key in `media-hosts.js`'s `ALLOWED` must yield at least one
host. Naming the two exclusions rather than the five inclusions is what makes a *new*
extractor covered the day it lands instead of the day someone remembers to list it. A
missing file throws rather than skipping: "the Swift package isn't here" and "the tables
agree" must not print the same thing.

Domains are read from inside each extractor's `match(url)` body only, found by bracket
matching rather than by a file-wide sweep. `rednote.js` calls `hostIs` a third time in
`toRednoteOriginal`, and a file-wide sweep would have picked up `rednotecdn.com` there by
luck — arriving at the right answer for no reason, which is the kind of thing that starts
being wrong the moment the file is refactored.

## Where it lives

It is not a new script. `scripts/drift-check.js` already had the shape — pure invariants in
`src/`, file loading and reporting in `scripts/` — so `checkHostTableAgreement` returns the
same `{ ok, problems, signals }` verdict the capture checks return and prints through the
identical `✔`/`✘` path. The established closing line is untouched on success. Its failure
half gained a clause, because "re-capture fixtures" is no help at all against two host
tables that disagree.

One real difference from every check above it: this one needs no capture, so it always
runs. `drift-check` was a canary that CI ran over committed fixtures; for this check it is
a gate. The Swift path resolves relative to the script rather than to the cwd, so CI's
`working-directory: extension` reaches a file above `extension/` without any workflow
change — verified by running the CLI from the repo root and from `$HOME`, not assumed.

## Verification

Both directions were demonstrated by breaking the repo on purpose and putting it back.

| | |
|---|---|
| `node --test` | **535 / 535** — was 524, plus 11 new |
| `npm run drift-check` | no drift, exit 0; five capture checks unchanged |
| Swift row deleted (`pinterest.co.uk`) | `✘ … pinterest.co.uk is pinterest in extractors/pinterest.js but MISSING from the Swift table — the phone would file it as .web` |
| JS domain added (`pinterest.fr`) | `✘ … pinterest.fr is pinterest in extractors/pinterest.js but MISSING…`, **exit 1** |
| after reverting both | no drift, exit 0, `git status` clean |
| cwd independence | identical output from `extension/`, from the repo root, and from `$HOME` |

`ShareCapture.swift` is unmodified by this slice; it is read, never written.

The eleven new tests cover the verdicts over synthetic sources (agreement, a missing
domain, a contradiction, the permitted subdomain, a Swift-only row) and run the real
parsers against the real files, asserting counts and specific rows — so a rewrite that
parses to plausible nonsense fails as loudly as one that parses to nothing. The floors are
injectable for exactly one reason: a two-row synthetic table trips all four, and the
assertion under test is the invariant, not the sanity check. Nothing but a test passes
them; the CLI takes the real ones.

## Files

    extension/src/host-table.js              new — the pure check. Parsers for the Swift
                                             table, the extractor match() bodies and the
                                             ALLOWED map; `swiftPlatformFor`, which
                                             re-implements Swift's hostIs lookup; the
                                             liveness floors; the verdict
    extension/test/host-table.test.js        new — 11 tests: the invariant over synthetic
                                             sources, the parsers over the real files
    extension/scripts/drift-check.js         reads both producers' sources and reports the
                                             new verdict before the capture checks; header
                                             now separates the opt-in checks from the one
                                             that always runs; the failure summary names
                                             host-table reconciliation as a remedy
    .github/workflows/ci.yml                 comments only — the `extension` job's scope
                                             now includes the Swift share extension's host
                                             table, and why reading a path above
                                             `extension/` is safe there

No `package.json` change: the check rides `npm run drift-check`, which CI already runs.

## Migration notes

None for users, and nothing about capture behaviour changed — this slice adds no runtime
code to the extension or the app. `src/host-table.js` is imported by the CLI and its
tests, and by nothing the browser loads.

For anyone adding a site: the order is now enforced rather than remembered. A new
extractor module needs its domains in `ShareCapture.hostPlatforms` with the matching
`Platform` case in the same change, or `npm run drift-check` fails and CI fails with it.
The reverse is deliberately free — a domain only the share sheet can see needs no JS entry
— but it will be listed as phone-only on every run, so be ready to say why.

A new extractor file also has to be *parseable*: one `platform: "…"` string and at least
one `hostIs(host, "…")` call literally inside `match(url)`. An extractor that computes its
domains some other way is not wrong, but it will fail this check, and the fix is to teach
`parseExtractorDomains` the new shape rather than to add the file to `NOT_EXTRACTORS` —
that set is for modules that are not extractors, not for extractors that are inconvenient.
