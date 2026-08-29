# 413 — thirteen sites, two that meant something

A clean build of all seven packages (test targets included) and the macOS app, with a
`grep` for `warning:` over the whole log. Thirteen distinct sites, **none of them from a
dependency**. The raw count looks like 116 only because the compiler re-emits each one per
compilation pass.

Eleven were residue. Two were pointing at something.

## The two

**`RestoreController.swift:124` was doing the opposite of what its comment claimed.** The
comment read *"The async bracket even here: reading an iCloud or network volume's directory
can suspend, and the sync one would drop the scope."* The compiler said no `async`
operation occurs in that `await` — which means overload resolution had picked the
**synchronous** `withAccess`, and had been picking it all along.

Both are true at once, and the resolution is that the comment is about the wrong call.
`FolderAccess` has two overloads (`FolderAccess.swift:62` and `:78`), and the async one
exists because a body that *suspends* would have its security scope torn down at the first
`await` — that is the copy loop's hazard, and the copy loop still gets the async bracket.
`performScan`'s body is `BackupCatalog.sources(in:)`, which cannot suspend. So the sync
overload was always correct here, the `await` was always decorative, and the comment
described a danger this call site does not have. The `await` is gone and the comment now
says which overload runs and why.

**`SSRFGuard.swift:145`** is the only warning that was in shipping source rather than a
test or a debug path, and it is in the file that decides whether a URL is safe to fetch.
`String(cString:)` on an ARRAY is deprecated, and the deprecation text names the reason:
you must truncate the NUL yourself, because an array is not a C string. The fix takes the
prefix up to the first NUL and decodes that. `getnameinfo` NUL-terminates on success, so
this is equivalent on every path that can reach it — and on a path where it somehow did
not, taking the prefix is what stops the decode reading padding as text.

Same edit, same reasoning, in `BakeoffAutorun.swift:244` (`sysctlbyname`, debug path).

## The eleven

| what | where | why it was noise |
|---|---|---|
| `await` with nothing async | `ExportController.swift:298,:342` | the `Task` inherits `@MainActor` and `finish` is synchronous; the hop already happened at `.value` |
| `await` with nothing async | `ServicesDeleteTests.swift:278` | GRDB's synchronous `write` |
| `var` never mutated | `MasonryGridHost.swift:1062` | one word |
| `try` with nothing throwing | `AssetFolderWriterTests.swift:99,:203,:219` | the throwing calls are inside `#expect(throws:)`, which swallows them |
| redundant `#require` | `ElementStyleTextTests.swift:104,:132` | the INNER one of a nested pair — `init?(jsonString:)` takes a `String?`, so unwrapping first proved nothing |
| unused value | `ServicesShelfTests.swift:170,171` | seeded neighbours; the assertion that reaches them is `after.left == before.left` |
| unused result | `RestoreRunnerTests.swift:361` | the test is about the progress recorder, not the summary |

The last two were the ones worth reading before deleting, because a discarded value can
mean a test asserts less than it looks like it does. Neither did: the neighbours are
compared by position inside an array equality, and the restore summary has its own tests.
Both are now explicitly `_ =` with the reason at the line.

Two guesses of mine were wrong on the way and are worth recording, because both were the
same mistake — attributing a warning without reading its context. The `#require` warnings
are at lines 104 and 132, not 35/50/93 as the message's `style.jsonString()` suggested;
they name the expression, and the expression appears in five places. And a warning printed
under the `AtelierServer` heading was in `AtelierCore`'s tests: a per-package build
re-emits its dependencies' diagnostics.

## Verification

A second clean build of the same eight things: **zero** `warning:` lines from any source
file. What remains in the log is one line per target from `appintentsmetadataprocessor`
saying an app that does not link AppIntents does not link AppIntents — a build tool's
notice, not a source diagnostic, and not fixable in source.

`AtelierCore`, `AtelierExport` and `AtelierIngestion` suites re-run after the test edits;
`scripts/verify.sh fast` passes all 8 stages.

## Files

    AtelierIngestion/Sources/AtelierIngestion/    NUL-truncating decode replaces
      Input/SSRFGuard.swift                       `String(cString:)`

    AtelierRefs/AtelierRefs/RestoreController.swift    sync `withAccess`; the comment now
                                                       describes the call that happens
    AtelierRefs/AtelierRefs/ExportController.swift     two redundant `await`s
    AtelierRefs/AtelierRefs/MasonryGridHost.swift      `var` → `let`
    AtelierRefs/AtelierRefs/Debug/BakeoffAutorun.swift same decode fix

    AtelierCore/Tests/…/ServicesDeleteTests.swift      redundant `await`
    AtelierCore/Tests/…/ServicesShelfTests.swift       two `_ =` with the reason
    AtelierCore/Tests/…/ElementStyleTextTests.swift    nested `#require` dropped
    AtelierExport/Tests/…/AssetFolderWriterTests.swift three redundant `try`s
    AtelierIngestion/Tests/…/RestoreRunnerTests.swift  `_ =` on the run summary

## Migration notes

None. No behaviour changed anywhere: every edit either deleted a keyword the compiler was
ignoring or replaced a deprecated call with the one its deprecation text names.
