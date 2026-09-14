# 502 — the relay knew why and said nothing

## Summary

`runBulkSweep`'s relay logged a failed item as a bare status — `relay <id> -> fetch-error`
— and dropped the explanation the service worker had already produced beside it
(`message` on a fetch failure, `reason` on a skip or an empty plan). One process
away, the sweep explained itself perfectly; in the console it was mute.

This is the same defect `terminalMessage` carried for halts until 392dc8d: a
component that computes the reason correctly, hands it over, and has it discarded
by the last line before a human reads it.

Found while diagnosing a video ingest failure that produced `fetch-error` on a
`<note_id>:v` item — a status that should be unreachable for an item whose
`mediaUrl` is null by construction. Every hypothesis had to be tested by reading
source, because the one line that would have named the cause printed a label and
nothing else. (The actual cause was a stale content script in an already-open tab,
which the reason text would have shown immediately.)

## Files changed

- `extension/src/bulk-controller.js` — the relay log appends `result.message ||
  result.reason`, truncated to 200 characters because a message carries a url and
  this prints once per failed item.

## Migration notes

None. A healthy sweep is as quiet as it was — the line still fires only for a
non-`saved` result.

## The gap this leaves

The service worker's own `deps.log` / `deps.logError` lines were never reaching the
extension's service-worker console during a live sweep, which is why the video
path looked like it had not run when it had not been reached at all. Nothing here
addresses that; it is worth its own look, because SW-side logging that silently
goes nowhere is a debugging tool that cannot be trusted the next time.
