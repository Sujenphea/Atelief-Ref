# 501 — the address that was never a fixture

## Summary

Three test fixtures — `pinterest-boardfeed.json`, `pinterest-boards.json` and
`x-bookmarks.json` — were hand-composed in July/August, **before**
`sanitize-capture.js` existed. Everything built since went through the sanitizer;
these three never did, and nobody checked them afterwards because the tooling
that would have caught it was written for the files that came later.

They carried real personal data: an email address, a display name, user agent and
OS, IP region, gender, and Pinterest's `epik` / `unauth_id` /
`push_package_user_id` session identifiers. `x-bookmarks.json` carried real tweet
ids, X media keys and a handle.

The repository is **public**, and the introducing commit (`476dc87`) was on
`origin/main`. The email was additionally used as a **live example in a code
comment** in `sanitize-capture.js` and quoted in two changelogs — so it was never
only a fixture problem.

## What was done

`git filter-repo --replace-text` over all 765 commits, scrubbing 59 literals;
the email maps to `redacted@example.com`, everything else to `REDACTED`. Verified
absent from every reachable commit afterwards.

The pre-rewrite state is preserved in `/tmp/claude-501/atelier-pre-rewrite.bundle`
and in `refs/heads/restored/*` (delete those once the push is settled).

## The false positive, and why it is worth recording

The literal list was derived by diffing fixture leaves before and after redaction.
That is a sound way to find changed values and an unsound way to decide which are
*secrets*: it also caught `nz.pinterest.com`, a geography-derived hostname that is
documentation, not identity. A collision check flagged it and was overridden on the
reasoning that long values are real identifiers. It is not.

Scrubbing it broke 9 tests and emptied the hostname out of source comments, two
docs and three changelogs. Repaired forward in this commit — 28 occurrences
restored — rather than by a second rewrite.

One genuine catch came out of the same pass: a real board id survived 498 inside a
URL-encoded `full_path` string, where a leaf-level diff could not see it. It now
carries the same synthetic id the rest of that fixture uses.

## Files changed

- `extension/src/bulk-pinterest.js`, `extension/src/extractors/base.js` — comment text restored
- `extension/test/bulk-context.test.js`, `bulk-pinterest.test.js`, `extractors.test.js` — literals restored
- `extension/test/fixtures/drift-baseline.json` — note text restored
- `extension/test/fixtures/pinterest-boardfeed.json` — embedded board id → synthetic
- `.change-log/393`, `434`, `435`, `.docs/017`, `.docs/019` — hostname restored

## Migration notes

**Every SHA in this repository changed.** Any existing clone must re-clone; do not
merge an old clone back in, or the scrubbed values return.

**The rewrite is not a recall.** The data was public for roughly two months. Forks,
GitHub's cached views and anything already scraped keep their copies. Treat the
email as public and the session identifiers as compromised regardless — rotating
them (log out of all Pinterest sessions) is the only step that reduces real risk.

**The gap this leaves open:** nothing tests the fixtures that predate the
sanitizer. 498 made the sanitizer refuse to write a leaking file, but that gate
only runs when a fixture is *produced*. A fixture that was never produced by it is
still unchecked by anything.
