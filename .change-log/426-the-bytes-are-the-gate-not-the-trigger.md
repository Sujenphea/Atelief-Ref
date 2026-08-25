# 426 — the bytes are the gate, not the trigger

094 was written the day open question 1 came back yes, and its headline finding was that
**the trigger** — iOS Safari has no context menu, so `info.srcUrl` has no replacement — is
the seam 091's "+4–6 weeks" did not account for. A verification pass over its claims
against the code says that finding stands, and that a second one sits in front of it.

## What was checked

Every file citation and both LOC figures, against the tree on `feat/ios-companion`.

| claim | reading |
|---|---|
| `contexts: ["page","image","link"]`, handler reads `info.srcUrl` | `sw.js:381–402`; the "far more reliable" comment is at `:399` |
| `DEFAULT_BASE = "http://127.0.0.1:47321"`, dev probes 47322 | `endpoint.js:13`, `base-url.js:23,25` |
| the Mac binds loopback only | `CaptureServer.swift:92` — `.inet(ip4: "127.0.0.1")`, deliberately not IPv6 |
| the hook wraps `fetch` AND `XMLHttpRequest` | `hook-core.js:41` |
| MAIN world at `document_start`; `action.default_popup` already declared | `manifest.json` |
| `bulk-*.js` is 2,407 lines | **exact** |
| downstream of the inbox is finished work | `InboxWriter` / `InboxDrain` / `InboxArchive` present and tested; drain wired (407), archive imports on the Mac (418), transport device-proven (424) |
| the extension's footprint | 6.4 MB for a 16.3 MB payload against a 120.0 MB ceiling, read on every share at `ShareViewController.swift:434` |

One figure was wrong. §5's "roughly 1,136 lines" that port unchanged is **1,455** —
`hook-core` 297, `twitter-hook` 109, `harvest` 164, `host-table` 263, `media-hosts` 56,
`extractors/` 566. Low by 28%, in the direction that favours the port.

## The three findings

**1. Open question 2 had no answer that could come back yes.** It proposed verifying that
a content script's `browser.storage.local` write is readable by `SafariWebExtensionHandler`
— "needs verifying that both sides see the same store." There is no store to share:
`storage.local` is the extension's own, the handler is an app extension and sees only what
`sendNativeMessage` / `connectNative` hands it, and the share extension is a third process
again. The reachable design is content script → native message → App Group file → share
extension, and that is what the spike should test.

**2. A content script cannot write into the App Group.** Only the native handler can. This
is the limit 094 §4 did not state, and it closes the bytes fork to exactly two shapes, both
bad for the login-walled media tier 3 exists for: base64 through the message (payload
resident in a jetsam-capped process, and Safari's native-message size limit on iOS is
unmeasured), or a native fetch from a URL (free — the measured `download(from:)` → `adopt`
path — but cookie-less). The session-authenticated fetch the page side would use is already
built (`hook-core.js`'s `headerAllowlist`, `hook-proxy.js`, `sw.js:60`); what is missing is
a cheap way for its result to reach a process that can write a file.

**3. The hook already buffers.** `RESPONSE_HOOK_REPLAY_LIMIT = 25` with replay on a
`message` (`hook-core.js:38`) is the accumulator's in-page half, written and tested. It is
not persistence — it dies with the tab, which is the gap the native hop closes.

## Why this reorders the doc

If neither bytes shape carries auth-walled media affordably, tier 3's advantage over tier 2
collapses to provenance-only — better metadata on the same picture tier 2 already fetches —
and the trigger question never needs answering. So §9's spike now runs **bytes first**,
persistence second, fidelity ceiling third, and says plainly that a bad first reading is a
stop rather than a resize. §2's third candidate (share sheet as trigger, extension as
accumulator) keeps its appeal and loses its price: it cannot be a lazy read at share time,
so the accumulator has to push to native continuously while the user browses.

## The probe for reading 1 is built

Written straight after the amendment, so §9's spike is a device session rather than a
project. Disposable and uncommitted, in the session scratchpad the way 425 kept its own:
`tier3-probe/` (the web extension), `tier3-native/` (the handler), `tier3-xcode/` (the
converted project, **building clean for the simulator**), and `tier3-probe/RUNBOOK.md`.

It copies `extension/src/hook-core.js` **verbatim**, so reading 3's counters come from the
shipping hook rather than a stand-in, and it borrows `ShareViewController.footprint()`
unchanged so its numbers sit on the same scale as 423's 6.4 MB / 16.3 MB. The handler
reports `phys_footprint` at three points — arrival, after decode, after write — because the
shape of that curve is the finding and one number is not. It links no packages and uses no
App Group: both are already discharged (401, 423) and requiring either means new
provisioning for a throwaway.

Reading 2 is deliberately not covered — it needs a third process and an App Group, and it
is moot if reading 1 comes back badly.

**The converter was wrong twice, not once.** `world` is "not supported" (stale, as 094 §1
said it would be), and it also wrote an app id title-cased from `--app-name`
(`sujenphea.Tier3Probe`) against an extension id lower-cased from `--bundle-identifier`
(`sujenphea.tier3probe.Extension`), so `ValidateEmbeddedBinary` fails the build for a
prefix mismatch the flags did not ask for. Recorded in 094 §1 — the message points at the
embedding and the cause is the tool.

## Files

Documentation only, in the repo.

- `.docs/094-safari-extension-research.md` — amendment header; §1 gains the
  probe-not-in-repo note and the device-proof citations; §2's "nearly free" retracted; §4
  gains the App-Group limit and the two-shape table; §5's LOC corrected and the
  `drift-check` gate named; §7.2 rewritten; §8's bytes row promoted from sizing risk to
  gate; §9 reordered.

## Migration notes

None. No code changed and no interface moved. 094's recommendation is unchanged in kind —
still a spike, still not a plan doc — and changed in order.
