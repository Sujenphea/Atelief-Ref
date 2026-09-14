# 510 — a repo that explained itself only in docs

## Summary

`README.md` held two lines: a shell snippet for wiping the local library. Everything
else a newcomer — or the author, six months on — would need was true but scattered.
`.docs/001` says what the app is. `scripts/verify.sh` says how to check a change.
`extension/README.md` says how the capture path works. `CLAUDE.md` says how a commit
is worded. Nothing at the root said any of it, or said where to look.

The README now does the one job a root README has: what this is, where the code
lives, how to build it, how to verify it, how to ship it, and which file to read
next for each of those. It is an index over documentation that already exists, not
a second copy of it — the package table names what each package *owns* (the
boundaries the Package.swift headers argue for), and every section ends by pointing
at the file that holds the detail.

The `clear library` snippet is kept, under **Dev notes**, rewritten to use `$HOME`
rather than a hardcoded user path and labelled with what it destroys.

## Files changed

- `README.md` — rewritten. Sections: what it is and the two principles, the package /
  target layout, building (Xcode 26 · macOS 26, and `run-local.command`), verifying
  (the three `verify.sh` modes), the Chrome extension (session-authenticated capture,
  port discovery on 47321/47322, the Web Store zip), releasing (the Developer ID lane
  and `SECRETS.md`), conventions (commit format, `.change-log/`, `.docs/`, never-reused
  indices), and the dev-notes snippet.

## Migration notes

None. Documentation only — no code, no schema, no wire change.
